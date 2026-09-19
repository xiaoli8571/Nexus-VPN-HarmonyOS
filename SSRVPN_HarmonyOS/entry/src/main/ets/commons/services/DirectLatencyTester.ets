/**
 * 离线直连探测（**兜底通道**，5.6.0 延迟测试重做后降级为最后手段）
 *
 * ## 现在的定位
 *
 * 延迟测试的唯一入口是 `LatencyEngine`，它优先走**真实内核**：
 *  1. 已连接 → 复用隧道内核的 controller（实测带全部 106 个真实节点）；
 *  2. 未连接 → `ConnectionOrchestrator.ensureLatencyApi()` 拉起 headless 测速内核
 *     （mihomo 的探测走 `p.DialContext`，绕过 TUN，未连接也能测出**真实代理延迟**）。
 * 只有上面两条都不可用时，引擎才退到本文件，结果状态记为 `LatencyState.OFFLINE`，
 * UI 显示为 `≈123ms` —— 明确表示"服务器可达"，**不是代理延迟**。
 *
 * ## 为什么不能当主通道
 *
 * 本文件测的是 server:port 的握手往返，**不经过代理协议协商**：真实代理延迟包含
 * 协议握手 + 加密 + 内核调度，与裸 TCP/TLS RTT 可能差出一个量级；对启用 obfs /
 * reality 的节点更是直接测不出来。旧实现把它和真实延迟混在同一列里显示，用户据此
 * 选节点会踩坑。保留它是因为"未连接时服务器是否活着/是否被墙"仍有参考价值，
 * 且必须由 UI 明确标注。
 *
 * ## 分级策略（回应"IP 通就算正常?"的误报）
 *  - hysteria2 → QUIC Initial 探测（收版本协商包）；obfs 节点返回 -2
 *  - tls: true → TCP 连上后再发真实 TLS ClientHello（带 SNI），必须收到
 *    ServerHello/Alert 等任何 TLS 记录才算存活 —— 只测 TCP 会把
 *    "端口开着但 TLS 层已死"的假活节点误判为正常
 *  - 其余（ss/ssr/明文）→ TCP 握手（无更高层可探，结果仅代表服务器可达）
 *
 * 返回值：毫秒数（>= 0）/ -1 失败 / **-2 无法离线探测**（引擎据此保持"未测"，
 * 绝不写成失败 —— "测不出"不等于"死了"）。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ProxyNode } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'DirectLatencyTester';
const TCP_TIMEOUT_MS = 4000;
const QUIC_TIMEOUT_MS = 2500;
const TLS_TIMEOUT_MS = 3000;

export class DirectLatencyTester {
  /** 直连测试单个节点: 毫秒数; 失败 -1; 无法离线探测 -2。
   *  分级策略(回应"IP通就算正常?"的误报):
   *   - hysteria2 → QUIC Initial 探测(收版本协商包)
   *   - tls: true → TCP 连上后再发真实 TLS ClientHello(带 SNI), 必须收到
   *     ServerHello/Alert 等任何 TLS 记录才算存活 —— 只测 TCP 会把
   *     "端口开着但 TLS 层已死"的假活节点误判为正常
   *   - 其余(ss/ssr/明文) → TCP 握手(无更高层可探, 结果仅代表服务器可达)
   */
  static async testNode(node: ProxyNode, timeoutMs: number = 5000): Promise<number> {
    if (node.server.length === 0 || node.port <= 0 || node.port >= 65536) {
      return -1;
    }
    if (node.proxyType === 'hysteria2') {
      if (node.obfs.length > 0) {
        return -2;
      }
      return DirectLatencyTester.probeQuic(node, timeoutMs);
    }
    if (node.tls && node.realityPublicKey.length === 0) {
      // reality 节点对非 uTLS 指纹的裸 ClientHello 可能静默不回包, 误杀率高, 走 TCP
      return DirectLatencyTester.probeTls(node, timeoutMs);
    }
    return DirectLatencyTester.probeTcp(node, timeoutMs);
  }

  /** 组装带 SNI 的 TLS1.2/1.3 ClientHello（任何合规 TLS 栈都必须回包） */
  private static buildClientHello(sni: string): ArrayBuffer {
    const nameBytes = new util.TextEncoder().encodeInto(sni);
    const suites: number[] = [0x1301, 0x1302, 0x1303, 0xC02C, 0xC02B, 0xC030, 0xC02F,
      0xC024, 0xC023, 0xC028, 0xC027, 0xC00A, 0xC014, 0x009E, 0x009C, 0x003D, 0x003C, 0x002F];
    const ext: number[] = [];
    const pushExt = (type: number, body: number[]): void => {
      ext.push((type >> 8) & 0xFF, type & 0xFF, (body.length >> 8) & 0xFF, body.length & 0xFF);
      for (const b of body) {
        ext.push(b);
      }
    };
    const sniBody: number[] = [0x00, (nameBytes.length >> 8) & 0xFF, nameBytes.length & 0xFF, 0x00,
      (nameBytes.length >> 8) & 0xFF, nameBytes.length & 0xFF];
    for (let i = 0; i < nameBytes.length; i++) {
      sniBody.push(nameBytes[i]);
    }
    const sniListLen = sniBody.length;
    pushExt(0x0000, [(sniListLen >> 8) & 0xFF, sniListLen & 0xFF].concat(sniBody));
    pushExt(0x002B, [0x02, 0x03, 0x04]);                                  // supported_versions TLS1.3
    pushExt(0x000D, [0x00, 0x08, 0x04, 0x03, 0x08, 0x04, 0x04, 0x01, 0x05, 0x03]); // sig algs
    pushExt(0x000A, [0x00, 0x06, 0x00, 0x1D, 0x00, 0x17, 0x00, 0x18]);    // groups x25519/P256/P384
    pushExt(0x000B, [0x01, 0x00]);                                          // ec_point_formats
    pushExt(0x0010, [0x00, 0x0E, 0x00, 0x02, 0x68, 0x32, 0x00, 0x08, 0x68, 0x74, 0x74, 0x70,
      0x2F, 0x31, 0x2E, 0x31]);                                             // ALPN h2/http1.1
    const body: number[] = [];
    body.push(0x03, 0x03);
    for (let i = 0; i < 32; i++) {
      body.push((i * 7 + 3) & 0xFF);
    }
    body.push(0x00);
    const suitesLen = suites.length * 2;
    body.push((suitesLen >> 8) & 0xFF, suitesLen & 0xFF);
    for (const s of suites) {
      body.push((s >> 8) & 0xFF, s & 0xFF);
    }
    body.push(0x01, 0x00);
    const extLen = ext.length;
    body.push((extLen >> 8) & 0xFF, extLen & 0xFF);
    for (const e of ext) {
      body.push(e);
    }
    const hsLen = body.length + 4;
    const record: number[] = [];
    record.push(0x16, 0x03, 0x01);
    const recLen = hsLen + 4 + 3;
    record.push((recLen >> 8) & 0xFF, recLen & 0xFF);
    record.push(0x01, (hsLen >> 16) & 0xFF, (hsLen >> 8) & 0xFF, hsLen & 0xFF);
    for (const b of body) {
      record.push(b);
    }
    return new Uint8Array(record).buffer as ArrayBuffer;
  }

  /** TLS 探测: TCP 连接 + ClientHello, 收到任何回包(ServerHello/Alert)才算存活 */
  private static probeTls(node: ProxyNode, timeoutMs: number): Promise<number> {
    const tcp = socket.constructTCPSocketInstance();
    const sni = node.servername.length > 0 ? node.servername : node.server;
    const ch = DirectLatencyTester.buildClientHello(sni);
    const start = Date.now();
    return new Promise<number>((resolve) => {
      let settled = false;
      let timerId = -1;
      const finish = (value: number): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId >= 0) {
          clearTimeout(timerId);
        }
        try {
          tcp.off('message');
        } catch (e) {
          // ignore
        }
        try {
          tcp.close();
        } catch (e) {
          // ignore
        }
        resolve(value);
      };
      tcp.on('message', () => {
        finish(Date.now() - start);
      });
      tcp.connect({
        address: { address: node.server, port: node.port, family: 1 },
        timeout: Math.min(TCP_TIMEOUT_MS, timeoutMs)
      } as socket.TCPConnectOptions).then(() => {
        tcp.send({ data: ch } as socket.TCPSendOptions).catch(() => {
          finish(-1);
        });
      }).catch(() => {
        finish(-1);
      });
      // A single deadline timer avoids waking the JS thread every 150ms for every
      // concurrent probe. Socket completion cancels it immediately.
      timerId = setTimeout(() => {
        finish(-1);
      }, Math.min(TCP_TIMEOUT_MS + TLS_TIMEOUT_MS, timeoutMs));
    });
  }

  /** TCP 握手探测（原实现） */
  private static async probeTcp(node: ProxyNode, timeoutMs: number): Promise<number> {
    const start = Date.now();
    let tcpSocket: socket.TCPSocket | null = null;
    try {
      tcpSocket = socket.constructTCPSocketInstance();
      await tcpSocket.connect({
        address: { address: node.server, port: node.port, family: 1 },
        timeout: Math.min(TCP_TIMEOUT_MS, timeoutMs)
      });
      const elapsed = Date.now() - start;
      try {
        tcpSocket.close();
      } catch (e) {
        // 关闭失败不影响结果
      }
      return elapsed;
    } catch (e) {
      if (tcpSocket !== null) {
        try {
          tcpSocket.close();
        } catch (e2) {
          // ignore
        }
      }
      return -1;
    }
  }

  /**
   * 构造 1200 字节 QUIC 探测数据报（PC 对真实 hy2 服务器实测有效：GREASE 版本
   * 触发版本协商回包，RTT≈真实链路；短包和 v1 包会被服务端按反放大规则静默丢弃）：
   * 首字节 0xC0(long header+fixed+Initial) + 未知版本 0x0a0a0a0a + DCID(8B)
   * + SCID(0) + token(空) + 长度字段 + 0x00 填充至 1200B。
   */
  private static buildQuicInitial(): ArrayBuffer {
    const p = new Uint8Array(1200);
    p[0] = 0xC0;
    p[1] = 0x0a; p[2] = 0x0a; p[3] = 0x0a; p[4] = 0x0a; // 未知 GREASE 版本 → 服务端必回版本协商包
    p[5] = 0x08; // DCID len
    for (let i = 0; i < 8; i++) {
      p[6 + i] = 0x53;
    }
    p[14] = 0x00; // SCID len 0
    p[15] = 0x00; // token 长度 varint 0
    p[16] = 0x00;
    p[17] = 0x40; // Length varint（服务端先验版本，此字段宽松）
    p[18] = 0xB2;
    // 其余保持 0（Padding 帧）填满 1200B —— RFC 9000 要求 Initial 数据报 ≥1200B，
    // 否则 quic-go/hysteria 直接丢弃不回包（实测短包无响应）。
    return p.buffer;
  }

  /** hy2 QUIC 探测：收到任何 UDP 回包即计 RTT；超时 -1 */
  private static probeQuic(node: ProxyNode, timeoutMs: number): Promise<number> {
    const udp = socket.constructUDPSocketInstance();
    const payload = DirectLatencyTester.buildQuicInitial();
    const start = Date.now();
    return new Promise<number>((resolve) => {
      let settled = false;
      let timerId = -1;
      const finish = (value: number): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId >= 0) {
          clearTimeout(timerId);
        }
        try {
          udp.off('message');
        } catch (e) {
          // ignore
        }
        try {
          udp.close();
        } catch (e) {
          // ignore
        }
        resolve(value);
      };
      udp.on('message', () => {
        finish(Date.now() - start);
      });
      udp.bind({ address: '0.0.0.0', port: 0, family: 1 }).then(() => {
        udp.send({
          data: payload,
          address: { address: node.server, port: node.port, family: 1 }
        } as socket.UDPSendOptions).catch(() => {
          finish(-1);
        });
      }).catch(() => {
        finish(-1);
      });
      // QUIC needs one deadline, not periodic polling. This materially reduces
      // timer callbacks and short-lived closures during batch node tests.
      timerId = setTimeout(() => {
        finish(-1);
      }, Math.min(QUIC_TIMEOUT_MS, timeoutMs));
    });
  }

  /** 批量直连测试: 依次测(避免并发打爆), 每个结果通过回调即时上报 */
  static async testAll(nodes: ProxyNode[],
    onResult: (node: ProxyNode, delayMs: number) => void): Promise<void> {
    for (const node of nodes) {
      const delay = await DirectLatencyTester.testNode(node);
      onResult(node, delay);
    }
  }
}
