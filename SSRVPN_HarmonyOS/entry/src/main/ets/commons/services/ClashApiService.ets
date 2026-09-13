/**
 * Clash RESTful API 客户端
 * 移植自 upstream: packages/ssrvpn_shared/lib/services/clash_service_base.dart
 *                clash_service_latency_support.dart
 *                clash_service_data_plane_support.dart
 * 对应 Android 端 MihomoApiWaiter / MihomoApiHealthProbe / MihomoProxySelection 的职责。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'ClashApiService';

export interface LatencyResult {
  nodeName: string;
  delayMs: number; // -1 = 超时/失败
}

export interface TrafficSnapshot {
  uploadBytes: number;
  downloadBytes: number;
  uploadSpeed: number;
  downloadSpeed: number;
}

/**
 * 延迟/探测失败分类。
 *
 * 审计背景：旧实现把所有非 200 响应与传输异常统一映射成 -1，调用方只能显示
 * 「超时」。真机上「测速内核还在跑但 secret 被别的路径覆盖」造成的 401、
 * 「内核里没有这个节点」造成的 404、以及真正 dial 超时（504）在 UI 上完全
 * 无法区分，只能靠猜。分类必须一路带到日志与快照。
 */
export class LatencyFailKind {
  /** 无失败（成功） */
  static readonly NONE: string = '';
  /** 测速内核/controller 不可用：进程已死、连接被拒，或 endpoint+secret 与内核不一致 */
  static readonly CORE_NOT_READY: string = 'core_not_ready';
  /** 内核代理表里找不到该节点（配置未生效 / 节点未下发）→ 切换节点失败 */
  static readonly SWITCH_FAILED: string = 'switch_failed';
  /** 网络不可达：内核能应答但出站拨号 / DNS 失败（不是超时） */
  static readonly NETWORK_UNREACHABLE: string = 'network_unreachable';
  /** 真正超时：内核按 timeout 判定失败（504），或请求在预算内无响应 */
  static readonly TIMEOUT: string = 'timeout';
  /** 无法离线探测（协议不支持）→ 保持「未测」，不是失败 */
  static readonly UNSUPPORTED: string = 'unsupported';
  /** 端口可达性降级结果：只证明 server:port 可达，绝不冒充代理延迟 */
  static readonly PORT_ONLY: string = 'port_reachable_only';
  /**
   * 未测：本次批次未完成测量（整批硬截止到点、或候选 URL 列表为空）。
   * 它不是节点的测速结论，绝不允许被呈现成「超时」，也不得让排序快照把它记成失败。
   */
  static readonly UNTESTED: string = 'untested';
}

/** 单次延迟探测结果（延迟值 + 失败分类 + 状态码） */
export class LatencyProbeResult {
  /** >=0 延迟毫秒；-1 失败；-2 无法离线探测 */
  delayMs: number = -1;
  /** LatencyFailKind.* */
  failKind: string = LatencyFailKind.NONE;
  /** HTTP 状态码（0 = 无响应 / 传输层失败） */
  httpCode: number = 0;
  /** 脱敏诊断信息（绝不包含 secret / 订阅地址 / 节点口令） */
  detail: string = '';

  ok(): boolean {
    return this.delayMs >= 0;
  }
}

/**
 * controller 真实可用性探测结果。
 *
 * 「内核就绪」必须是四者一致：进程存活 + endpoint 端口正确 + secret 一致 +
 * 一次真实 GET /version 返回 200。仅凭进程内状态机的 ACTIVE 布尔量会把
 * 「内核已死 / 被别的 secret 覆盖」误判为就绪。
 */
export class ControllerProbe {
  /** 被探测的 endpoint 端口 */
  port: number = 0;
  /** 当前 endpoint 是否配置了 secret */
  secretConfigured: boolean = false;
  /** 是否收到 HTTP 响应（进程存活） */
  reachable: boolean = false;
  /** HTTP 状态码（0 = 无响应） */
  httpCode: number = 0;
  /** secret 是否被内核接受（200 才算） */
  secretAccepted: boolean = false;
  /** 脱敏诊断信息 */
  detail: string = '';
}

export class ClashApiService {
  private apiPort: number = 9090;
  private secret: string = '';

  /**
   * 在途延迟测试请求集合。
   * 批量测速会同时挂起 N 路 /proxies/{name}/delay；页面退出或新批次开始时若只靠
   * 逻辑标志位，内核侧这些出站连接仍会跑到各自超时（最长 2.5~5s）继续占用通道，
   * 表现为「旧批次和新批次抢通道、整体变慢」。cancelInflight() 直接 destroy 掉
   * 在途请求，通道立刻释放。
   */
  private inflight: Set<http.HttpRequest> = new Set<http.HttpRequest>();

  /** 中断所有在途延迟测试请求，返回被中断的数量（其余业务请求不受影响）。 */
  cancelInflight(): number {
    const n = this.inflight.size;
    for (const req of this.inflight) {
      try {
        req.destroy();
      } catch (e) {
        // 已结束的请求 destroy 抛错属正常
      }
    }
    this.inflight.clear();
    return n;
  }

  setEndpoint(port: number, secret: string): void {
    this.apiPort = port;
    this.secret = secret;
  }

  /**
   * 当前 endpoint 端口。测速通道判定需要它来验证「端口 + secret 一致」，
   * 不能只看进程内状态机的 ACTIVE。
   */
  currentPort(): number {
    return this.apiPort;
  }

  /** 当前 endpoint secret（仅用于一致性比对，不得写入日志） */
  currentSecret(): string {
    return this.secret;
  }

  /** 当前 endpoint 是否与给定 secret 完全一致（测速内核通道一致性判据） */
  hasSecret(secret: string): boolean {
    return secret.length > 0 && this.secret === secret;
  }

  private baseUrl(): string {
    return `http://127.0.0.1:${this.apiPort}`;
  }

  private authHeader(): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.secret.length > 0) {
      h['Authorization'] = `Bearer ${this.secret}`;
    }
    return h;
  }

  private errText(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return String(e);
  }

  /** 等待 API 就绪（对应 MihomoApiWaiter），超时返回 false */
  async waitReady(timeoutMs: number, intervalMs: number = 300): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await this.healthProbe()) {
        return true;
      }
      await ClashApiService.sleep(intervalMs);
    }
    return false;
  }

  /** 健康探测（对应 MihomoApiHealthProbe）：GET /version */
  async healthProbe(): Promise<boolean> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/version`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 1500,
        readTimeout: 1500,
        usingCache: false
      });
      return resp.responseCode === 200;
    } catch (e) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 切换选中节点。必须同时下发到 PROXY 组和 GLOBAL 组:
   *  mihomo 在 global(全局)模式下忽略具名 PROXY 组, 走隐式 GLOBAL 组; 若不设置
   *  GLOBAL, 它默认选 DIRECT → 全局模式下所有流量直连、被国内 DNS 污染打不开。
   *  (真机实证: 全局模式 GLOBAL now=DIRECT, youtube dial 假 IP 超时。) */
  async selectNode(nodeName: string): Promise<boolean> {
    const okProxy = await this.selectInGroup('PROXY', nodeName);
    const okGlobal = await this.selectInGroup('GLOBAL', nodeName);
    return okProxy || okGlobal;
  }

  /** 在指定代理组选择节点: PUT /proxies/{group} {name} */
  private async selectInGroup(group: string, nodeName: string): Promise<boolean> {
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = this.authHeader();
      headers['Content-Type'] = 'application/json';
      const payload: Record<string, string> = {};
      payload['name'] = nodeName;
      const resp = await req.request(`${this.baseUrl()}/proxies/${encodeURIComponent(group)}`, {
        method: http.RequestMethod.PUT,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 3000,
        readTimeout: 3000,
        usingCache: false
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (e) {
      AppLogger.error(TAG, `selectInGroup(${group}) failed: ${this.errText(e)}`);
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 切换运行时代理模式（全局/规则）：PUT /configs（mihomo 中 PUT 与 PATCH 同为 updateConfigs） */
  async setMode(mode: string): Promise<boolean> {
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = this.authHeader();
      headers['Content-Type'] = 'application/json';
      const payload: Record<string, string> = {};
      payload['mode'] = mode === 'global' ? 'global' : 'rule';
      const resp = await req.request(`${this.baseUrl()}/configs`, {
        method: http.RequestMethod.PUT,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 3000,
        readTimeout: 3000,
        usingCache: false
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (e) {
      AppLogger.error(TAG, `setMode failed: ${e instanceof Error ? e.message : String(e)}`);
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * controller 真实可用性探测：GET /version（带当前 secret）。
   * 返回 reachable（进程存活）+ secretAccepted（HTTP 200 = secret 一致）。
   * 这是「测速内核就绪」的唯一权威判据的一部分（配合端口 + secret 一致性比对）。
   */
  async probeController(timeoutMs: number = 1500): Promise<ControllerProbe> {
    const out = new ControllerProbe();
    out.port = this.apiPort;
    out.secretConfigured = this.secret.length > 0;
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/version`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        usingCache: false
      });
      out.reachable = true;
      out.httpCode = resp.responseCode;
      out.secretAccepted = resp.responseCode === 200;
      out.detail = `http=${resp.responseCode}`;
    } catch (e) {
      out.reachable = false;
      out.httpCode = 0;
      out.secretAccepted = false;
      out.detail = this.errText(e);
    } finally {
      req.destroy();
    }
    return out;
  }

  /** 由内核响应码判定失败分类（区分凭证错配 / 节点缺失 / 超时 / 网络不可达） */
  private static classifyStatusCode(code: number): string {
    if (code === 401 || code === 403) {
      // secret 不一致：内核在跑，但用的不是我们这份凭证
      return LatencyFailKind.CORE_NOT_READY;
    }
    if (code === 404) {
      // 内核代理表里没有该节点 → 切换/下发失败
      return LatencyFailKind.SWITCH_FAILED;
    }
    if (code === 408 || code === 504) {
      // mihomo 按 timeout 参数判定失败
      return LatencyFailKind.TIMEOUT;
    }
    return LatencyFailKind.NETWORK_UNREACHABLE;
  }

  /** 由传输层异常消息判定失败分类（回环端口拒绝 = 内核不在） */
  private static classifyTransportError(message: string): string {
    const m = message.toLowerCase();
    if (m.includes('refused') || m.includes('econnrefused') || m.includes('not connected')
      || m.includes('broken pipe') || m.includes('epipe') || m.includes('failed to connect')) {
      return LatencyFailKind.CORE_NOT_READY;
    }
    if (m.includes('timeout') || m.includes('timed out')) {
      return LatencyFailKind.TIMEOUT;
    }
    return LatencyFailKind.NETWORK_UNREACHABLE;
  }

  /**
   * 延迟测试（详细版，对应 clash_service_latency_support）：
   * GET /proxies/{name}/delay
   *
   * 超时语义：timeoutMs 是**这一次尝试（单个测试 URL）**的预算，原样作为
   * mihomo 的 timeout 参数下发；外层 HTTP 只加少量调度余量。调用方对多个
   * fallback URL 依次调用时，每个 URL 各拿一份独立预算，不再把单节点总预算
   * 按剩余次数切碎（旧实现组测每次只剩 250~500ms → 大面积假超时）。
   *
   * 失败分类随结果返回（LatencyFailKind），调用方不得再统一折叠成「超时」。
   */
  async testLatencyDetailed(nodeName: string, testUrl: string,
    timeoutMs: number = 5000): Promise<LatencyProbeResult> {
    const out = new LatencyProbeResult();
    const req = http.createHttp();
    this.inflight.add(req);
    try {
      // API 位于本机，外层只需给 mihomo 返回结果留少量调度余量。
      // 旧的额外 2 秒会让每个失效节点在内核超时后继续空等，放大批测长尾。
      const outerTimeoutMs = timeoutMs + 350;
      const startedAt = Date.now();
      const resp = await req.request(
        `${this.baseUrl()}/proxies/${encodeURIComponent(nodeName)}/delay?url=${encodeURIComponent(testUrl)}&timeout=${timeoutMs}`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: outerTimeoutMs,
        readTimeout: outerTimeoutMs,
        usingCache: false
      });
      out.httpCode = resp.responseCode;
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode !== 200) {
        out.delayMs = -1;
        out.failKind = ClashApiService.classifyStatusCode(resp.responseCode);
        out.detail = `http=${resp.responseCode} bodyLen=${body.length} kind=${out.failKind}`;
        AppLogger.warn(TAG, `latency non-200: code=${resp.responseCode} kind=${out.failKind} bodyLen=${body.length} `
          + `innerTimeout=${timeoutMs} outerTimeout=${outerTimeoutMs} elapsed=${Date.now() - startedAt}ms`);
        return out;
      }
      if (body.length === 0) {
        out.delayMs = -1;
        out.failKind = LatencyFailKind.NETWORK_UNREACHABLE;
        out.detail = `http=200 empty body innerTimeout=${timeoutMs}`;
        AppLogger.warn(TAG, `latency empty response: kind=${out.failKind} innerTimeout=${timeoutMs} `
          + `outerTimeout=${outerTimeoutMs} elapsed=${Date.now() - startedAt}ms`);
        return out;
      }
      try {
        const json = JSON.parse(body) as Record<string, number>;
        const delay = json['delay'];
        if (delay !== undefined) {
          out.delayMs = delay;
          out.failKind = LatencyFailKind.NONE;
          out.detail = `delay=${delay} kind=ok`;
          return out;
        }
        out.delayMs = -1;
        out.failKind = LatencyFailKind.NETWORK_UNREACHABLE;
        out.detail = `http=200 missing delay bodyLen=${body.length}`;
        AppLogger.warn(TAG, `latency response missing delay: kind=${out.failKind} bodyLen=${body.length} `
          + `elapsed=${Date.now() - startedAt}ms`);
      } catch (jsonError) {
        out.delayMs = -1;
        out.failKind = LatencyFailKind.NETWORK_UNREACHABLE;
        out.detail = `http=200 bad json bodyLen=${body.length}`;
        AppLogger.warn(TAG, `latency JSON error: kind=${out.failKind} bodyLen=${body.length} `
          + `error=${this.errText(jsonError)} elapsed=${Date.now() - startedAt}ms`);
      }
      return out;
    } catch (e) {
      out.delayMs = -1;
      out.failKind = ClashApiService.classifyTransportError(this.errText(e));
      out.detail = `transport kind=${out.failKind}`;
      AppLogger.warn(TAG, `latency request error: kind=${out.failKind} innerTimeout=${timeoutMs} `
        + `outerTimeout=${timeoutMs + 350} error=${this.errText(e)}`);
      return out;
    } finally {
      this.inflight.delete(req);
      req.destroy();
    }
  }

  /** 兼容旧调用点：只取延迟数值（失败一律 -1）。需要失败分类请用 testLatencyDetailed。 */
  async testLatency(nodeName: string, testUrl: string, timeoutMs: number = 5000): Promise<number> {
    const probe = await this.testLatencyDetailed(nodeName, testUrl, timeoutMs);
    return probe.delayMs;
  }

  /** 流量快照：GET /connections。
   *  mihomo 的 Snapshot 只有 uploadTotal/downloadTotal(累计字节), 没有速率字段;
   *  速率由本类按两次轮询的总量差值计算(比另开 /traffic WebSocket 更省资源)。 */
  private lastDownloadTotal: number = -1;
  private lastUploadTotal: number = -1;
  private lastPollAt: number = 0;

  /** 清空差值基线（连接/断开时调用, 避免跨会话算出假速率） */
  resetTrafficBaseline(): void {
    this.lastUploadTotal = -1;
    this.lastDownloadTotal = -1;
    this.lastPollAt = 0;
    this.trafficLogged = 0;
  }

  /** 一次性诊断: 前 3 次轮询把响应概况写入运行日志(排查面板恒 0 问题) */
  private trafficLogged: number = 0;

  private logTrafficOnce(code: number, bodyLen: number, up: number, down: number): void {
    if (this.trafficLogged < 3) {
      this.trafficLogged = this.trafficLogged + 1;
      AppLogger.info(TAG, `traffic diag: code=${code} len=${bodyLen} up=${up} down=${down}`);
    }
  }

  async traffic(): Promise<TrafficSnapshot> {
    const empty: TrafficSnapshot = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/connections`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 2000,
        readTimeout: 2000,
        usingCache: false
      });
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode !== 200 || body.length === 0) {
        return empty;
      }
      const json = JSON.parse(body) as Record<string, number>;
      const uploadBytes = json['uploadTotal'] !== undefined ? json['uploadTotal'] : 0;
      const downloadBytes = json['downloadTotal'] !== undefined ? json['downloadTotal'] : 0;
      this.logTrafficOnce(resp.responseCode, body.length, uploadBytes, downloadBytes);
      const now = Date.now();
      let uploadSpeed = 0;
      let downloadSpeed = 0;
      if (this.lastPollAt > 0 && now > this.lastPollAt && this.lastUploadTotal >= 0) {
        const elapsedSeconds = (now - this.lastPollAt) / 1000;
        const du = uploadBytes - this.lastUploadTotal;
        const dd = downloadBytes - this.lastDownloadTotal;
        if (du >= 0) {
          uploadSpeed = du / elapsedSeconds;
        }
        if (dd >= 0) {
          downloadSpeed = dd / elapsedSeconds;
        }
      }
      this.lastUploadTotal = uploadBytes;
      this.lastDownloadTotal = downloadBytes;
      this.lastPollAt = now;
      const result: TrafficSnapshot = {
        uploadBytes: uploadBytes,
        downloadBytes: downloadBytes,
        uploadSpeed: uploadSpeed,
        downloadSpeed: downloadSpeed
      };
      return result;
    } catch (e) {
      if (this.trafficLogged < 3) {
        this.trafficLogged = this.trafficLogged + 1;
        AppLogger.info(TAG, `traffic diag: request failed ${e instanceof Error ? e.message : String(e)}`);
      }
      return empty;
    } finally {
      req.destroy();
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }
}
