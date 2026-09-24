/**
 * 节点延迟状态模型（延迟测试重做，5.6.0）
 *
 * 旧实现用 `Map<string, number>` + 哨兵（-1 超时 / -2 未测）表达结果，结构上
 * 无法区分「超时 / 失败 / 不可用 / 未测 / 测试中」，也没有时间戳（无法显示结果
 * 新鲜度）。真机上大量"明明只是没测过却显示超时""结果永远是几分钟前的"投诉
 * 都源于此。这里改为显式状态 + 时间戳。
 *
 * 状态语义（必须一路带到 UI / 日志 / 持久化，禁止把 FAILED 折叠成 TIMEOUT）：
 *  - MEASURED  实测延迟，ms >= 1（mihomo 成功响应里 delay 恒 >= 1，0 被内核当失败）
 *  - TIMEOUT   内核侧超时（HTTP 504 {"message":"Timeout"}）
 *  - FAILED    探测失败（HTTP 503：拨号失败 / 状态码不符 / delay==0）
 *  - OFFLINE   离线粗略探测（未连接内核时的 TCP/TLS/QUIC 探活，绝不冒充代理延迟）
 *  - CANCELLED 用户取消 / 网络切换中断，**不是节点结论**
 *  - UNTESTED  从未测过
 *
 * 纯数据 + 纯函数，无副作用，可在 ohosTest 直接驱动验证。
 */

/**
 * 延迟结果状态。
 *
 * 用 class + static readonly 而不是 `enum`：与 `LatencyFailKind` / `LatencyChannel`
 * 保持同一风格，且**可被 Node 的 type-stripping 直接执行**（离线回归套件
 * `verify-latency-cache.mjs` / `test-latency-engine.js` 就是把本文件按 .ts 暂存后
 * import 进来跑的；Node 的 strip-only 模式明确拒绝 `enum`，会报
 * ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX）。
 */
export class LatencyState {
  static readonly UNTESTED: number = 0;
  static readonly TESTING: number = 1;
  static readonly MEASURED: number = 2;
  static readonly TIMEOUT: number = 3;
  static readonly FAILED: number = 4;
  /**
   * 用户取消 / 网络切换中断，**不是节点结论**。
   *
   * 注意：引擎目前**不会**为单个节点落这个状态 —— abort 之后不发布任何记录
   * （否则抢占方新批次的 TESTING 标记会被旧批次盖掉），被打断的节点由
   * `LatencyEngine.clearOwnTestingMarks()` 收回 UNTESTED（UI 显示 `--`，
   * 语义是"我们不知道"）。这个状态保留在词汇表与 UI 里，供 classify()
   * 与未来需要区分"被中断"的入口使用；当前行为已由
   * scripts/verify-latency-engine-runtime.mjs 真跑确认。
   */
  static readonly CANCELLED: number = 5;
  /** 离线直连探测（粗略可达性，UI 必须与真实代理延迟区分展示） */
  static readonly OFFLINE: number = 6;
}

/** 探测通道来源（诊断与展示用） */
export class LatencyChannel {
  /** 真实内核（隧道或已加载内核的 controller）：权威结果 */
  static readonly CORE: string = 'core';
  /** 离线直连探测：仅代表服务器可达，非代理延迟 */
  static readonly OFFLINE: string = 'offline';
}

/**
 * 单个节点的延迟记录。
 *
 * `atMs` 是判定/展示新鲜度的唯一依据；`staleMs` 为结果过期阈值，超过即灰显
 * （主流客户端普遍不持久化结果，我们保留但必须让用户看出"这是旧的"）。
 */
export class LatencyRecord {
  name: string = '';
  state: number = LatencyState.UNTESTED;
  /** 实测延迟；仅 MEASURED/OFFLINE 有意义，其余为 -1 */
  delayMs: number = -1;
  /** 产生该结果的时间戳（Date.now()）；UNTESTED 为 0 */
  atMs: number = 0;
  /** LatencyChannel.* */
  channel: string = LatencyChannel.CORE;

  static measured(name: string, delayMs: number, channel: string, atMs: number): LatencyRecord {
    const r = new LatencyRecord();
    r.name = name;
    r.state = channel === LatencyChannel.OFFLINE ? LatencyState.OFFLINE : LatencyState.MEASURED;
    r.delayMs = delayMs;
    r.channel = channel;
    r.atMs = atMs;
    return r;
  }

  static failed(name: string, state: number, atMs: number, channel: string = LatencyChannel.CORE): LatencyRecord {
    const r = new LatencyRecord();
    r.name = name;
    r.state = state;
    r.delayMs = -1;
    r.channel = channel;
    r.atMs = atMs;
    return r;
  }

  static untested(name: string): LatencyRecord {
    const r = new LatencyRecord();
    r.name = name;
    r.state = LatencyState.UNTESTED;
    r.delayMs = -1;
    r.atMs = 0;
    return r;
  }

  /** 是否有可展示的数值 */
  hasValue(): boolean {
    return (this.state === LatencyState.MEASURED || this.state === LatencyState.OFFLINE) && this.delayMs >= 0;
  }

  /** 是否是一次结论性的失败（可用于排序与持久化） */
  isFailure(): boolean {
    return this.state === LatencyState.TIMEOUT || this.state === LatencyState.FAILED;
  }
}

/**
 * 结果状态机与排序策略（纯函数）。
 *
 * 关键约定：
 *  - `0ms` 不是有效延迟。mihomo 成功时 delay 恒 >= 1；0 表示失败（内核自己就
 *    把 delay==0 当失败返回 503）。若把 0 当"很快"，死节点会排到最前面。
 *  - 失败**永不排在最前**：排序权重 last（CMFA 的朴素升序把死节点顶到最上面，
 *    是公认的体验问题）。
 *  - CANCELLED / UNTESTED 不带结论，权重排在失败之后。
 */
export class LatencyPolicy {
  /** 单节点探测超时：用户要求 3000ms 无返回即判超时（此前 5000ms 等待太长）。 */
  static readonly DEFAULT_TIMEOUT_MS: number = 3000;
  /** mihomo 的 timeout 用 16 位整数解析，> 32767 直接 400。 */
  static readonly MAX_TIMEOUT_MS: number = 30000;
  /** 结果视为"旧"的阈值：超过即灰显，提示用户可能不准 */
  static readonly STALE_MS: number = 10 * 60 * 1000;

  /** 0 / 负数 / 缺失都不是有效延迟 */
  static isValidDelay(delayMs: number): boolean {
    return delayMs >= 1 && delayMs < 32767;
  }

  /**
   * 把一次探测的原始结果归一化为状态。
   * @param httpCode HTTP 状态码（0 = 传输层失败/中止）
   * @param delayMs  响应体里的 delay（无则 -1）
   * @param aborted  是否为客户端主动中止（取消），此时绝不是节点结论
   */
  static classify(httpCode: number, delayMs: number, aborted: boolean): number {
    if (aborted) {
      return LatencyState.CANCELLED;
    }
    if (httpCode === 200 && LatencyPolicy.isValidDelay(delayMs)) {
      return LatencyState.MEASURED;
    }
    if (httpCode === 504) {
      return LatencyState.TIMEOUT;
    }
    if (httpCode === 503) {
      return LatencyState.FAILED;
    }
    if (httpCode === 404) {
      // 节点已不存在（配置变更）：不是"超时"，也不该留在列表里给用户看
      return LatencyState.FAILED;
    }
    // 401/000/其他：内核或凭证层面有问题，不能盖章成节点超时
    return LatencyState.FAILED;
  }

  /** 节点名是否是内建项（不可测） */
  static isBuiltinNode(name: string): boolean {
    return name === 'DIRECT' || name === 'REJECT' || name === 'REJECT-DROP'
      || name === 'COMPATIBLE' || name === 'PASS' || name === 'PASS-RULE'
      || name === 'GLOBAL' || name === 'REMATCH' || name === 'DNS';
  }

  /**
   * 服务器地址是否指向本机/内网。
   *
   * 为什么单列一条：离线粗略通道测的是"服务器可达性"，对环回/内网地址测出来的
   * 是本机自己的握手开销（真机实测会出现 `≈2ms` 这种漂亮但毫无意义的数字，还会
   * 排到列表最前）。真实内核通道不受影响（那种节点本来就该按真实延迟显示），
   * 所以只在离线通道里判定。
   */
  static isLoopbackOrLocal(server: string): boolean {
    const s = server.trim().toLowerCase();
    if (s.length === 0) {
      return true;
    }
    if (s === 'localhost' || s === '::1' || s === '[::1]') {
      return true;
    }
    if (s.startsWith('127.') || s.startsWith('10.') || s.startsWith('192.168.')) {
      return true;
    }
    // 172.16.0.0/12
    if (s.startsWith('172.')) {
      const parts = s.split('.');
      if (parts.length > 1) {
        const second = Number.parseInt(parts[1], 10);
        if (second >= 16 && second <= 31) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 组类型是否可测。
   *
   * 为什么必须过滤组：实测本项目的 `PROXY.all` 里混着 14 个组条目
   * （🔰 选择节点 / 🌏 爱奇艺&哔哩哔哩 / 🎮 Steam… ），若不过滤，
   * 一是会把组当节点测（内核按组当前选择返回，得到的是**别的节点**的延迟，
   * 结果张冠李戴），二是浪费一轮超时预算。所以只测真实出站节点。
   */
  static isTestableType(type: string): boolean {
    const groups: string[] = ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay'];
    if (groups.indexOf(type) >= 0) {
      return false;
    }
    const builtinTypes: string[] = ['Direct', 'Reject', 'RejectDrop', 'Compatible', 'Pass', 'PassRule', 'Dns'];
    return builtinTypes.indexOf(type) < 0;
  }

  /**
   * 排序权重：实测最快 → 实测较慢 → 离线探测 → 未测/取消 → 超时 → 失败。
   * 失败最后（绝不让坏节点因为"-1 最小"而排最前）。
   */
  static sortRank(rec: LatencyRecord): number {
    if (rec.state === LatencyState.MEASURED) {
      return 0;
    }
    if (rec.state === LatencyState.OFFLINE) {
      return 1;
    }
    if (rec.state === LatencyState.UNTESTED || rec.state === LatencyState.CANCELLED) {
      return 2;
    }
    if (rec.state === LatencyState.TIMEOUT) {
      return 3;
    }
    return 4;
  }

  /**
   * 比较两个记录用于升序排序。
   * 同权重内：实测按延迟升序；失败按名称稳定排序（避免顺序抖动）。
   */
  static compare(a: LatencyRecord, b: LatencyRecord): number {
    const ra = LatencyPolicy.sortRank(a);
    const rb = LatencyPolicy.sortRank(b);
    if (ra !== rb) {
      return ra - rb;
    }
    if (ra <= 1 && a.delayMs !== b.delayMs) {
      return a.delayMs - b.delayMs;
    }
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
  }

  /** 结果是否已过期（灰显提示，不删除——用户仍可参考） */
  static isStale(rec: LatencyRecord, nowMs: number): boolean {
    if (rec.atMs <= 0 || !rec.hasValue()) {
      return false;
    }
    return nowMs - rec.atMs > LatencyPolicy.STALE_MS;
  }

  /** 状态文案（UI 唯一来源，禁止各处自己拼字符串） */
  static stateText(state: number): string {
    if (state === LatencyState.MEASURED || state === LatencyState.OFFLINE) {
      return '';
    }
    if (state === LatencyState.TESTING) {
      return '测试中';
    }
    if (state === LatencyState.TIMEOUT) {
      return '超时';
    }
    if (state === LatencyState.FAILED) {
      return '失败';
    }
    if (state === LatencyState.CANCELLED) {
      return '已取消';
    }
    return '--';
  }
}
