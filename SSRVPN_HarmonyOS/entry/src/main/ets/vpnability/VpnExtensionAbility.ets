/**
 * VPN 扩展能力：TUN 建立、fd 注入内核、长时任务
 * 移植自 upstream: android/.../SsrvpnVpnService.kt
 *                VpnRouteInstaller.kt / VpnIpv6Config.kt / CoreLivenessMonitor.kt
 *
 * 真实 API（SDK @ohos.net.vpnExtension，API 11+ / 本机 SDK 26）：
 *   vpnExtension.createVpnConnection(context) → VpnConnection
 *   VpnConnection.create(VpnConfig) → Promise<number>（TUN fd）
 * 链路：UI 侧 ConnectionOrchestrator 写好配置文件并通过
 *   startVpnExtensionAbility(want.parameters.configPath) 拉起本能力 →
 *   本能力 onCreate 里 create() 拿到 fd → coreBridge.attachTun(fd) + startCore(configPath)。
 *
 * ⚠️ 生命周期回调名：VpnExtensionAbility 只有 onCreate(want) / onDestroy()，
 *    不存在 onStart/onStop（见 SDK @ohos.app.ability.VpnExtensionAbility.d.ts）。
 *    之前误用 onStart/onStop，系统回调命中基类空实现，TUN/内核从未启动，
 *    表现为 UI 侧 30s 超时报「9090 端口跨进程不可达」。
 *
 * IPv6 入站已常开（FlClash 常用功能之一，不提供关闭入口）：isIPv6Accepted=true，
 * IPv4+IPv6 双栈地址与默认路由；内核侧 dns.ipv6 + fake-ip fc00::/71 同步开启。
 * 长时任务：本 SDK 无 VPN 模式，使用 TASK_KEEPING（对应 Android 前台服务语义）。
 */
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { fileIo as fs } from '@kit.CoreFileKit';
import { coreBridge } from '../core/CoreBridge';
import { AppLogger } from '../commons/utils/AppLogger';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'VpnExtensionAbility';
const VPN_MTU = 1400;
/** TUN 地址/前缀与 bridge/bridge.go 的 Inet4Address 严格一致（对齐 NekoBox 实测格式） */
const TUN_ADDRESS = '172.19.0.1';
const TUN_PREFIX = 30;
/** IPv6 入站: ULA 地址 + /126, 与 mihomo tun.inet6-address 严格一致（对齐 NekoBox） */
const TUN_ADDRESS_V6 = 'fdfe:dcba:9876::1';
const TUN_PREFIX_V6 = 126;
const TUN_IFNAME = 'vpn-tun';
const DNS_SERVERS = ['223.5.5.5', '119.29.29.29'];
/** 启动错误回传文件名（写入 configPath 同目录，UI 侧读取真实失败原因） */
const START_ERROR_FILE = 'vpn_start_error.txt';
/** 启动成功标记文件名（内核 API 就绪后写入，UI 侧轮询） */
const START_OK_FILE = 'vpn_start_ok.txt';
/** 心跳文件名（内核运行期间每 3s 覆写时间戳，UI 侧据此判断内核存活） */
const HEARTBEAT_FILE = 'vpn_heartbeat.txt';
const HEARTBEAT_INTERVAL_MS = 3000;

export default class SsrvpnVpnExtension extends VpnExtensionAbility {
  /** 当前 VpnConnection（重入时先 destroy 旧的，避免 2200002 VPN already exist） */
  private connection: vpnExtension.VpnConnection | null = null;
  /** 心跳定时器（onDestroy 时清理） */
  private heartbeatTimer: number = -1;
  /** 心跳文件所在目录（cleanup 时删除心跳文件用） */
  private heartbeatDir: string = '';
  /** Protect socket 请求轮询器，由 Go 核心请求逐 socket 绕过 VPN。 */
  private protectTimer: number = -1;
  /** 后台长时任务是否已启动。 */
  private backgroundRunning: boolean = false;
  /** 统一清理的幂等门控。 */
  private cleanupPromise: Promise<void> | null = null;
  /** 本次会话的配置路径（onDestroy 时删除含 API secret 的 YAML） */
  private configPathForCleanup: string = '';
  /** 该配置是否为临时测速配置（由 UI 侧生成为 mihomo_test_config.yaml） */
  private configIsTransient: boolean = false;

  /**
   * 删除含凭据的运行时配置。每个文件独立容错，缺失即跳过。
   * @param force 内核启动失败/无头测速失败时即使不是临时配置也删除
   */
  private removePrivateConfig(force: boolean): void {
    if (this.configPathForCleanup.length === 0) {
      return;
    }
    if (!force && !this.configIsTransient) {
      return;
    }
    try {
      fs.unlinkSync(this.configPathForCleanup);
    } catch (e) {
      // 已被 UI 侧删除属正常
    }
  }

  /** 判断配置是否为测速用临时文件（UI 侧命名约定） */
  private static isTransientConfig(path: string): boolean {
    return path.endsWith('mihomo_test_config.yaml');
  }

  /** 把扩展进程内的启动失败原因写回 UI 可读的目录（跨进程无法直接共享内存） */
  private reportStartError(configPath: string, message: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      const file = fs.openSync(`${dir}/${START_ERROR_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, message);
      } finally {
        // 写入失败也必须释放 fd（此前 writeSync 抛错会泄漏句柄）
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `write start error file failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /** 写入启动成功标记（内容为时间戳，便于排查） */
  private reportStartOk(configPath: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      const file = fs.openSync(`${dir}/${START_OK_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, `${Date.now()}`);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `write start ok file failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private clearStartError(configPath: string): void {
    const dir = configPath.substring(0, configPath.lastIndexOf('/'));
    const targets: string[] = [START_ERROR_FILE, START_OK_FILE, HEARTBEAT_FILE];
    // 逐文件独立容错：一个文件不存在不得阻止其余文件删除
    for (const name of targets) {
      try {
        fs.unlinkSync(`${dir}/${name}`);
      } catch (e) {
        // 文件不存在属正常
      }
    }
  }

  /** 内核运行期间周期覆写心跳时间戳，UI 侧读取以判断内核存活 */
  private startHeartbeat(configPath: string): void {
    this.stopHeartbeat();
    const dir = configPath.substring(0, configPath.lastIndexOf('/'));
    this.heartbeatDir = dir;
    this.heartbeatTimer = setInterval(() => {
      try {
        const file = fs.openSync(`${dir}/${HEARTBEAT_FILE}`,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, `${Date.now()}`);
        } finally {
          fs.closeSync(file);
        }
      } catch (e) {
        AppLogger.warn(TAG, `heartbeat write failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }, HEARTBEAT_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  /**
   * 排空 Go 内核的逐 fd protect 请求队列, 并发 protect 并按 fd 回执。
   *
   * 语义(v3, 真机双实证): protectProcessNet 在本机对 Go socket 不生效, "先
   * protect 后 connect" 的顺序保证全靠这条通道 —— 必须回执(Go 等自己的 fd 回执
   * 才放行 connect, 上限 800ms, 超时 fail-open)。同时按批排空 + 并发 promise,
   * 杜绝旧版"5s 串行等待→排队超时→会话退役→全线 unavailable"的死亡螺旋。
   */
  private startProtectMonitor(): void {
    this.stopProtectMonitor();
    this.protectTimer = setInterval(() => {
      const connection = this.connection;
      if (connection === null) {
        return;
      }
      for (let i = 0; i < 16; i++) {
        const request: number[] = coreBridge.readProtectSocketFd();
        const fd: number = request[0];
        if (fd < 0) {
          break;
        }
        const seq: number = request[1];
        // protect 失败(fd 已关闭/复用等)也要回执: Go 侧收到回执(含 false)立即放行拨号。
        connection.protect(fd).then(() => {
          coreBridge.setProtectResultForFd(fd, seq, true);
        }).catch(() => {
          coreBridge.setProtectResultForFd(fd, seq, false);
        });
      }
    }, 10);
  }

  private stopProtectMonitor(): void {
    if (this.protectTimer >= 0) {
      clearInterval(this.protectTimer);
      this.protectTimer = -1;
    }
  }

  private cleanupResources(): Promise<void> {
    if (this.cleanupPromise !== null) {
      return this.cleanupPromise;
    }
    this.cleanupPromise = this.cleanupResourcesInternal().finally(() => {
      this.cleanupPromise = null;
    });
    return this.cleanupPromise;
  }

  private async cleanupResourcesInternal(): Promise<void> {
    this.stopHeartbeat();
    this.stopProtectMonitor();
    // 心跳定时器停止后删除心跳文件: 防止其他进程在 15s 陈旧窗口内把
    // "已断开"误判为"内核还活着"(与 orchestrator.clearTunnelMarkers 双保险)。
    if (this.heartbeatDir.length > 0) {
      try {
        fs.unlinkSync(`${this.heartbeatDir}/${HEARTBEAT_FILE}`);
      } catch (e) {
        // 已被 UI 侧删除属正常
      }
    }
    // 临时测速配置随扩展退出删除（无头测速无 TUN，配置不会被内核长期需要）
    this.removePrivateConfig(false);
    try {
      await coreBridge.stopCore();
    } catch (e) {
      AppLogger.warn(TAG, 'core cleanup failed');
    }
    const connection = this.connection;
    this.connection = null;
    if (connection !== null) {
      try {
        await connection.destroy();
      } catch (e) {
        AppLogger.warn(TAG, 'VPN connection cleanup failed');
      }
    }
    if (this.backgroundRunning) {
      this.backgroundRunning = false;
      try {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
      } catch (e) {
        AppLogger.warn(TAG, 'background task cleanup failed');
      }
    }
  }

  async onCreate(want: Want): Promise<void> {
    AppLogger.info(TAG, 'vpn onCreate');
    // 长时任务（对应 Android 前台服务），失败不阻塞连接流程
    try {
      const entryWant: Want = {
        bundleName: 'com.ssrvpn.client',
        // moduleName 缺失会让 wantAgent 校验失败（16000151 invalid wantAgent），
        // 导致 TASK_KEEPING 永远起不来、扩展进程可被系统回收。
        moduleName: 'entry',
        abilityName: 'EntryAbility'
      };
      const agentRequest: wantAgent.WantAgentInfo = {
        wants: [entryWant],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(agentRequest);
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
      this.backgroundRunning = true;
      AppLogger.info(TAG, 'background task started (TASK_KEEPING)');
    } catch (e) {
      const err = e as BusinessError;
      // 记录真实错误码：16000151=invalid wantAgent、201=权限被拒、
      // 9800005/其它=系统策略拒绝（例如通知被禁用时长时任务可能被拒）。
      AppLogger.warn(TAG,
        `background task start failed: code=${err.code} msg=${err.message}`);
    }

    const params = want.parameters;
    let configPath = (params !== undefined && params !== null) ? (params['configPath'] as string) : '';
    if (configPath === undefined || configPath.length === 0) {
      configPath = `${this.context.cacheDir}/mihomo_config.yaml`;
      AppLogger.warn(TAG, 'config path missing; using cache configuration');
    }
    this.configPathForCleanup = configPath;
    this.configIsTransient = SsrvpnVpnExtension.isTransientConfig(configPath);
    this.clearStartError(configPath);

    // 重入防护：进程复用导致旧连接仍在时先销毁（避免 create 报 2200002 already exist）
    if (this.connection !== null) {
      try {
        await this.connection.destroy();
      } catch (e) {
        // 旧连接可能已失效，忽略
      }
      this.connection = null;
    }
    // 内核可能因进程复用而残留运行状态，先幂等停止再启动
    try {
      await coreBridge.stopCore();
    } catch (e) {
      // 未启动过时停止属正常
    }

    // headless 测速模式(UI 预启动内核做真实协议测速): 不建 TUN、不请求 VPN
    // 授权、不启 protect/心跳 —— 只拉起内核开 127.0.0.1 的 mixed+API 端口。
    const headless = (params !== undefined && params !== null)
      && ((params['headless'] as number) === 1);
    if (headless) {
      this.runHeadless(configPath);
      return;
    }

    // IPv6 入站(UI 侧连接前探测物理网络后传入): 1=当前环境有 IPv6, 开双栈;
    // 0/缺省=无 IPv6 环境, 自动绕过 —— 只装 IPv4 地址与默认路由, 不把设备
    // 引上没有出口的 ::/0(否则 YouTube 等 IPv6-preferred 应用直接失联)。
    const ipv6Inbound = (params !== undefined && params !== null)
      ? ((params['ipv6Inbound'] as number) === 1) : false;
    const config: vpnExtension.VpnConfig = ipv6Inbound ? {
      addresses: [{
        address: { address: TUN_ADDRESS, family: 1 },
        prefixLength: TUN_PREFIX
      }, {
        address: { address: TUN_ADDRESS_V6, family: 2 },
        prefixLength: TUN_PREFIX_V6
      }],
      // 双栈默认路由（对齐 NekoBox: interface 指定 TUN 名 + isDefaultRoute）
      routes: [{
        interface: TUN_IFNAME,
        destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: true
      }, {
        interface: TUN_IFNAME,
        destination: { address: { address: '::', family: 2 }, prefixLength: 0 },
        gateway: { address: '::', family: 2 },
        hasGateway: false,
        isDefaultRoute: true
      }],
      dnsAddresses: DNS_SERVERS,
      mtu: VPN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: true
    } : {
      addresses: [{
        address: { address: TUN_ADDRESS, family: 1 },
        prefixLength: TUN_PREFIX
      }],
      // 默认路由捕获全部流量（对齐 NekoBox: interface 指定 TUN 名 + isDefaultRoute）
      routes: [{
        interface: TUN_IFNAME,
        destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: true
      }],
      dnsAddresses: DNS_SERVERS,
      mtu: VPN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: false
    };
    AppLogger.info(TAG, `vpn config: ipv6Inbound=${ipv6Inbound ? 1 : 0}`);

    // ── 应用级分流（两类包名均由 UI 侧逗号拼接传入） ──────────────────────────
    // (a) 强制不走代理的应用: VpnConfig.blockedApplications —— 框架层让这些包名的 App
    //     流量直接走物理网络、不进隧道（刷抖音/微信等不需要代理的 App 不受加速影响）。
    //     包名由 UI 侧 excludedApps 填充。
    // (b) 走代理的应用白名单: VpnConfig.trustedApplications —— 平台字段名就是
    //     trustedApplications（官方文档：配置该列表后**仅**列表内的应用数据才按 routes
    //     被 VPN 代理；SDK API 24 的 VpnConfig 里**没有** allowedApplications 字段）。
    //     包名由 UI 侧 includedApps 填充；空 = 不下发 = 黑名单模式（行为与旧版本一致）。
    // 平台约束：trustedApplications 与 blockedApplications **不能同时配置**，因此白名单
    // 生效时不下发 blockedApplications，改用「差集」表达 blocked 优先：两个列表都填了的
    // 包会被从白名单里剔除（= 白名单内仍然直连）。
    // 解析容错：params 为 undefined/null、字段缺失、空串、多余逗号、重复项。
    const bypassRaw = (params !== undefined && params !== null) ? (params['bypassPackages'] as string) : '';
    const blockedPkgs: string[] = [];
    if (bypassRaw !== undefined && bypassRaw !== null && bypassRaw.length > 0) {
      for (const p of bypassRaw.split(',')) {
        const t = p.trim();
        if (t.length > 0 && blockedPkgs.indexOf(t) < 0) {
          blockedPkgs.push(t);
        }
      }
    }
    const proxyRaw = (params !== undefined && params !== null) ? (params['proxyPackages'] as string) : '';
    const allowPkgs: string[] = [];
    if (proxyRaw !== undefined && proxyRaw !== null && proxyRaw.length > 0) {
      for (const p of proxyRaw.split(',')) {
        const t = p.trim();
        if (t.length > 0 && allowPkgs.indexOf(t) < 0) {
          allowPkgs.push(t);
        }
      }
    }
    // blocked 优先：从白名单里剔除同时出现在 blocked 列表里的包
    const effectiveAllow: string[] = [];
    for (const p of allowPkgs) {
      if (blockedPkgs.indexOf(p) < 0) {
        effectiveAllow.push(p);
      }
    }
    if (effectiveAllow.length > 0) {
      // 平台上限（API 23 起 256 个；更低版本 64），超限直接下发可能导致 create 失败
      const capped = effectiveAllow.length > 256 ? effectiveAllow.slice(0, 256) : effectiveAllow;
      config.trustedApplications = capped;
      AppLogger.info(TAG, `trustedApplications configured(whitelist): count=${capped.length}` +
        ` (input=${allowPkgs.length}, blocked-overlap=${allowPkgs.length - effectiveAllow.length}` +
        `${capped.length !== effectiveAllow.length ? ', truncated' : ''})`);
      if (blockedPkgs.length > 0) {
        AppLogger.info(TAG, `blockedApplications skipped in whitelist mode: count=${blockedPkgs.length}` +
          ' (VpnConfig: trusted/blocked 互斥, 已用白名单差集表达 blocked 优先)');
      }
    } else if (blockedPkgs.length > 0) {
      // 黑名单模式（无白名单 / 白名单被 blocked 完全抵消 → 回落旧行为）
      if (allowPkgs.length > 0) {
        AppLogger.info(TAG, `proxyPackages fully cancelled by blockedApplications: count=${allowPkgs.length}, fallback to blocklist mode`);
      }
      config.blockedApplications = blockedPkgs;
      AppLogger.info(TAG, `blockedApplications configured: count=${blockedPkgs.length}`);
    }

    try {
      this.connection = vpnExtension.createVpnConnection(this.context);
      const tunFd = await this.connection.create(config);
      AppLogger.info(TAG, 'TUN created');

      // 同时启用进程级保护与逐 socket Protect 通道，避免出站流量回灌 TUN。
      await this.connection.protectProcessNet();
      AppLogger.info(TAG, 'protectProcessNet enabled');

      const attached = await coreBridge.attachTun(tunFd, VPN_MTU);
      if (!attached) {
        throw new Error('内核桥加载失败（attachTun）');
      }
      const protectReady = await coreBridge.initProtect();
      if (!protectReady) {
        throw new Error('内核 Protect 通道初始化失败');
      }
      this.startProtectMonitor();

      // startCore 在线程池执行，ArkTS 事件循环持续处理 Protect 请求。
      const ok = await coreBridge.startCore(configPath);
      AppLogger.info(TAG, `core start result: ${ok}`);
      if (!ok) {
        const coreErr = await coreBridge.lastError();
        throw new Error(coreErr.length > 0 ? coreErr : '内核启动失败（未知原因）');
      }
      this.reportStartOk(configPath);
      this.startHeartbeat(configPath);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.reportStartError(configPath, `VPN 扩展启动异常: ${msg}`);
      AppLogger.error(TAG, `vpn onCreate failed: ${msg}`);
      // 启动失败即为本次会话终结：删掉含 API secret 的配置，避免凭据滞留磁盘
      this.removePrivateConfig(true);
      await this.cleanupResources();
    }
  }

  /** headless 测速内核: 仅 startCore + 回写启动结果标记, 失败走同一错误通道 */
  private async runHeadless(configPath: string): Promise<void> {
    try {
      AppLogger.info(TAG, 'headless test-core starting (no TUN / no VPN permission)');
      const ok = await coreBridge.startCore(configPath);
      if (!ok) {
        const coreErr = await coreBridge.lastError();
        throw new Error(coreErr.length > 0 ? coreErr : 'headless 内核启动失败');
      }
      this.reportStartOk(configPath);
      AppLogger.info(TAG, 'headless test-core started');
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.reportStartError(configPath, `测速内核启动失败: ${msg}`);
      AppLogger.error(TAG, `headless start failed: ${msg}`);
      // 失败路径不留残余：删除测速配置与启动标记文件
      this.clearStartError(configPath);
      this.removePrivateConfig(true);
      await this.cleanupResources();
    }
  }

  onDestroy(): void {
    AppLogger.info(TAG, 'vpn onDestroy');
    this.cleanupResources().catch((e: Error) => {
      AppLogger.warn(TAG, `vpn onDestroy cleanup failed: ${e instanceof Error ? e.message : String(e)}`);
    });
  }
}
