// tools/true-parser-harness/fixtures/corpus.mjs
// 脱敏 YAML 语料库：每条只放**最小**片段 + 期望节点数/期望字段。
// 全部主机名用 *.example.test / RFC3849 文档地址段，凭据统一 REDACTED 占位，
// 不含任何真实机场、节点名、地址或密钥。由 corpus_runner.mjs 用真实源码执行。
//
// 字段说明：
//   id/tags       用例标识与覆盖面标签
//   yaml          单来源输入（默认 merge([yaml])）
//   yamls         多来源输入（跨订阅去重用例）
//   expectNodes   merge 后的可导入节点数期望
//   fields        [节点下标, MergedProxy 字段名, 期望值]
//   extras        { i, key, has }   extraOpts 中必须存在的键（has 为子串断言，可省略）
//   extrasAbsent  [节点下标, key]   extraOpts 中**不得**出现的键（防止嵌套子键泄漏成顶层键）
//   invalidCount  merge 后 YamlMerger.lastInvalidCount 期望值
//   reasons       lastInvalidReasons 必须包含的子串
//   limitSkippedCount  lastLimitSkippedCount 期望值（单节点/单字段限额被跳过的节点数）
//   dialerMissing / dialerBroken  dialer-proxy 依赖诊断计数期望值
//   expectGlobalError  期望 merge 抛出 YamlMergeError 且文案包含该子串（全局限额用例）
//   notes         该用例想钉住的语义（跑出结果时打印）

const y = (...lines) => lines.join('\n');

export const corpus = [
  // ---------- A. 跨多行 flow map ----------
  {
    id: 'A1_flow_multiline_flat',
    tags: ['flow-map', 'cross-line'],
    yaml: y(
      'proxies:',
      '  - {name: A1 跨行基本, type: vless, server: a1.example.test,',
      '     port: 443, uuid: 00000000-0000-4000-8000-000000000001,',
      '     tls: true, network: ws, ws-opts: {path: /a1, headers: {Host: a1.example.test}}}',
      'proxy-groups: []'
    ),
    expectNodes: 1,
    fields: [[0, 'wsPath', '/a1'], [0, 'wsHost', 'a1.example.test'], [0, 'port', 443]]
  },
  {
    id: 'A2_flow_multiline_nested',
    tags: ['flow-map', 'cross-line', 'nested-map'],
    yaml: y(
      'proxies:',
      '  - {name: A2 嵌套跨行, type: vless, server: a2.example.test, port: 443,',
      '     uuid: 00000000-0000-4000-8000-000000000002,',
      '     ws-opts: {path: /a2,',
      '       headers: {Host: a2.example.test, X-Tag: "a,b:c"}},',
      '     reality-opts: {public-key: REDACTED-PK,',
      '       short-id: 1a2b}}'
    ),
    expectNodes: 1,
    fields: [
      [0, 'wsPath', '/a2'],
      [0, 'wsHost', 'a2.example.test'],
      [0, 'realityPublicKey', 'REDACTED-PK'],
      [0, 'realityShortId', '1a2b']
    ]
  },
  {
    id: 'A3_flow_multiline_sequence',
    tags: ['flow-map', 'cross-line', 'flow-sequence'],
    yaml: y(
      'proxies:',
      '  - {name: A3 序列跨行, type: trojan, server: a3.example.test, port: 443,',
      '     password: REDACTED,',
      '     alpn: [h3,',
      '       h2, http/1.1], sni: a3.example.test}'
    ),
    expectNodes: 1,
    fields: [[0, 'alpnList', 'h3,h2,http/1.1'], [0, 'servername', 'a3.example.test']]
  },

  // ---------- B. 块式嵌套 map ----------
  {
    id: 'B1_block_ws_nested',
    tags: ['block-style', 'nested-map', 'ws-opts'],
    yaml: y(
      'proxies:',
      '  - name: B1 块式 WS',
      '    type: vless',
      '    server: b1.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000011',
      '    network: ws',
      '    ws-opts:',
      '      path: /b1',
      '      headers:',
      '        Host: b1.example.test'
    ),
    expectNodes: 1,
    fields: [[0, 'wsPath', '/b1'], [0, 'wsHost', 'b1.example.test'], [0, 'network', 'ws']],
    // 历史缺陷：块式子键 `path:` 被当成条目顶层键 → 以额外字段身份写进配置
    extrasAbsent: [[0, 'path'], [0, 'headers'], [0, 'Host']]
  },
  {
    id: 'B2_block_reality_grpc',
    tags: ['block-style', 'nested-map', 'reality-opts', 'grpc-opts'],
    yaml: y(
      'proxies:',
      '  - name: B2 块式 Reality+gRPC',
      '    type: vless',
      '    server: b2.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000012',
      '    flow: xtls-rprx-vision',
      '    reality-opts:',
      '      public-key: REDACTED-PK2',
      '      short-id: 3c4d',
      '    grpc-opts:',
      '      grpc-service-name: b2-grpc'
    ),
    expectNodes: 1,
    fields: [
      [0, 'realityPublicKey', 'REDACTED-PK2'],
      [0, 'realityShortId', '3c4d'],
      [0, 'grpcServiceName', 'b2-grpc'],
      [0, 'flow', 'xtls-rprx-vision']
    ],
    extrasAbsent: [[0, 'public-key'], [0, 'short-id'], [0, 'grpc-service-name']]
  },
  {
    id: 'B3_block_smux_map',
    tags: ['block-style', 'nested-map', 'extra-nested-map'],
    yaml: y(
      'proxies:',
      '  - name: B3 块式 smux',
      '    type: vless',
      '    server: b3.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000013',
      '    smux:',
      '      enabled: true',
      '      protocol: h2mux',
      '      max-connections: 8'
    ),
    expectNodes: 1,
    extras: [{ i: 0, key: 'smux', has: 'enabled: true' }],
    extrasAbsent: [[0, 'protocol'], [0, 'enabled']]
  },

  // ---------- C. 序列值：流式与块式 ----------
  {
    id: 'C1_seq_flow_alpn_ports',
    tags: ['flow-sequence', 'alpn', 'ports'],
    yaml: y(
      'proxies:',
      '  - {name: C1 流式序列, type: hysteria2, server: c1.example.test, port: 443,',
      '     password: REDACTED, alpn: [h3], ports: [443,8443]}'
    ),
    expectNodes: 1,
    fields: [[0, 'alpnList', 'h3']],
    extras: [{ i: 0, key: 'ports', has: '8443' }]
  },
  {
    id: 'C2_seq_block_alpn',
    tags: ['block-sequence', 'alpn'],
    yaml: y(
      'proxies:',
      '  - name: C2 块式序列 alpn',
      '    type: vless',
      '    server: c2.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000021',
      '    alpn:',
      '      - h3',
      '      - h2',
      '    tls: true'
    ),
    expectNodes: 1,
    fields: [[0, 'alpnList', 'h3,h2']]
  },
  {
    id: 'C3_seq_block_relay_ports',
    tags: ['block-sequence', 'relay', 'hysteria'],
    yaml: y(
      'proxies:',
      '  - name: C3 hysteria 块式序列',
      '    type: hysteria',
      '    server: c3.example.test',
      '    port: 443',
      '    auth-str: REDACTED',
      '    ports:',
      '      - 443',
      '      - 8443',
      '    alpn:',
      '      - h3'
    ),
    expectNodes: 1,
    extras: [{ i: 0, key: 'ports' }, { i: 0, key: 'alpn' }]
  },
  {
    id: 'C4_seq_block_wireguard_allowed_ips',
    tags: ['block-sequence', 'relay', 'wireguard'],
    yaml: y(
      'proxies:',
      '  - name: C4 wireguard',
      '    type: wireguard',
      '    server: c4.example.test',
      '    port: 51820',
      '    private-key: REDACTED',
      '    public-key: REDACTED',
      '    allowed-ips:',
      '      - 0.0.0.0/0',
      '      - ::/0'
    ),
    expectNodes: 1,
    extras: [{ i: 0, key: 'allowed-ips', has: '0.0.0.0/0' }]
  },

  // ---------- D. 锚点 / 别名 / 合并键 ----------
  {
    id: 'D1_anchor_scalar_alias',
    tags: ['anchor', 'alias', 'in-item-anchor'],
    yaml: y(
      'proxies:',
      '  - name: D1 锚点定义',
      '    type: vless',
      '    server: d1.example.test',
      '    port: 443',
      '    uuid: &uuid1 00000000-0000-4000-8000-000000000031',
      '  - name: D1 别名复用',
      '    type: vless',
      '    server: d1b.example.test',
      '    port: 443',
      '    uuid: *uuid1'
    ),
    expectNodes: 2,
    fields: [
      [0, 'uuid', '00000000-0000-4000-8000-000000000031'],
      [1, 'uuid', '00000000-0000-4000-8000-000000000031']
    ]
  },
  {
    id: 'D2_anchor_top_level_block_merge',
    tags: ['anchor', 'merge-key', 'top-level-anchor', 'block-anchor'],
    yaml: y(
      'defaults: &base',
      '  udp: true',
      '  skip-cert-verify: true',
      'proxies:',
      '  - name: D2 顶层块式锚点合并',
      '    <<: *base',
      '    type: vless',
      '    server: d2.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000032',
      '    ws-path: /d2'
    ),
    expectNodes: 1,
    fields: [[0, 'udp', true], [0, 'skipCertVerify', true], [0, 'wsPath', '/d2']],
    notes: '顶层锚点定义段不得截断 proxies 提取；<< 合并键只补缺失项'
  },
  {
    id: 'D3_anchor_top_level_flow_merge',
    tags: ['anchor', 'merge-key', 'top-level-anchor', 'flow-map'],
    yaml: y(
      'anchors:',
      '  tpl: &tpl {udp: true, network: ws, ws-opts: {path: /tpl, headers: {Host: tpl.example.test}}}',
      'proxies:',
      '  - name: D3 顶层流式锚点合并',
      '    <<: *tpl',
      '    type: vless',
      '    server: d3.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000033'
    ),
    expectNodes: 1,
    fields: [
      [0, 'udp', true],
      [0, 'network', 'ws'],
      [0, 'wsPath', '/tpl'],
      [0, 'wsHost', 'tpl.example.test']
    ]
  },
  {
    id: 'D4_multidoc_unindented_list',
    tags: ['multidoc', 'unindented-list', 'document-marker'],
    yaml: y(
      'proxies:',
      '- {name: D4a 零缩进, type: ss, server: d4a.example.test, port: 8388,',
      '   cipher: aes-256-gcm, password: REDACTED}',
      '...',
      '---',
      'proxies:',
      '- {name: D4b 次文档, type: trojan, server: d4b.example.test, port: 443,',
      '   password: REDACTED}',
      'proxy-groups: []'
    ),
    expectNodes: 2,
    fields: [[0, 'type', 'ss'], [1, 'type', 'trojan']],
    notes: '顶格序列项 + 文档标记不得截断分节'
  },
  {
    id: 'D5_top_level_merge_key_noise',
    tags: ['merge-key', 'top-level-noise', 'stray-line'],
    yaml: y(
      'proxies:',
      '  - {name: D5a, type: ss, server: d5a.example.test, port: 8388, cipher: aes-256-gcm,',
      '     password: REDACTED}',
      '<<: *missing',
      '  - {name: D5b, type: ss, server: d5b.example.test, port: 8389, cipher: aes-256-gcm,',
      '     password: REDACTED}'
    ),
    expectNodes: 2,
    fields: [[0, 'name', 'D5a'], [1, 'name', 'D5b']],
    notes: '顶层 `<<:` 不得截断分节，也不得污染上一条目'
  },
  {
    id: 'D6_anchor_unresolved_is_missing_field',
    tags: ['alias', 'unresolved-alias', 'invalid-stats'],
    yaml: y(
      'proxies:',
      '  - {name: D6 未定义别名, type: vless, server: d6.example.test, port: 443, uuid: *nope}',
      '  - {name: D6 合法, type: ss, server: d6b.example.test, port: 8388, cipher: aes-256-gcm,',
      '     password: REDACTED}'
    ),
    expectNodes: 1,
    invalidCount: 1,
    reasons: ['缺少 uuid'],
    notes: '无法解析的别名 = 字段缺失（失败原因可统计），不是整条静默丢弃'
  },

  // ---------- E. 引号/转义/注释/尾逗号/重复键 ----------
  {
    id: 'E1_quotes_and_escapes',
    tags: ['quotes', 'escape', 'comma', 'colon', 'braces', 'hash'],
    yaml: y(
      'proxies:',
      '  - {name: "E1: 值含逗号,冒号{大括号}与#井号", type: ss, server: e1.example.test,',
      '     port: 8388, cipher: aes-256-gcm, password: "p,a:s{s}#1",',
      '     plugin: \'v2ray-plugin\', plugin-opts: \'{mode: websocket, host: e1.example.test}\'}'
    ),
    expectNodes: 1,
    fields: [
      [0, 'name', 'E1: 值含逗号,冒号{大括号}与#井号'],
      [0, 'password', 'p,a:s{s}#1']
    ],
    extras: [{ i: 0, key: 'plugin' }, { i: 0, key: 'plugin-opts' }]
  },
  {
    id: 'E2_flow_inline_comment',
    tags: ['inline-comment', 'flow-map', 'single-quote-escape'],
    yaml: y(
      'proxies:',
      "  - {name: 'E2 it''s ok', type: ss, server: e2.example.test, port: 8388,",
      '     cipher: aes-256-gcm, password: REDACTED} # 行内注释'
    ),
    expectNodes: 1,
    fields: [[0, 'name', "E2 it's ok"]],
    notes: 'flow-map 尾部行内注释不得使整条被判未闭合'
  },
  {
    id: 'E3_block_inline_comment_quoted',
    tags: ['inline-comment', 'block-style', 'quoted-value'],
    yaml: y(
      'proxies:',
      '  - name: "E3 注释后置"   # 说明',
      '    type: ss',
      '    server: e3.example.test',
      '    port: 8388',
      '    cipher: aes-256-gcm',
      '    password: "p # k"    # 值内含井号'
    ),
    expectNodes: 1,
    fields: [[0, 'name', 'E3 注释后置'], [0, 'password', 'p # k']]
  },
  {
    id: 'E4_trailing_comma_duplicate_key',
    tags: ['trailing-comma', 'duplicate-key'],
    yaml: y(
      'proxies:',
      '  - {name: E4 尾逗号, type: ss, server: e4.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED, udp: true,}',
      '  - {name: E4 重复键, type: ss, server: e4.example.test, port: 8389,',
      '     cipher: aes-256-gcm, cipher: aes-128-gcm, password: REDACTED}'
    ),
    expectNodes: 2,
    fields: [[0, 'udp', true], [1, 'cipher', 'aes-256-gcm']],
    notes: '尾逗号容忍；重复键取首个（与 YAML 解析器语义一致）'
  },

  // ---------- F. 端口/协议/IPv6/Unicode/BOM ----------
  {
    id: 'F1_port_string_and_ipv6',
    tags: ['port-string', 'bare-ipv6', 'bracket-ipv6'],
    yaml: y(
      'proxies:',
      '  - {name: F1 字符串端口, type: ss, server: f1.example.test, port: "443",',
      '     cipher: aes-256-gcm, password: REDACTED}',
      '  - {name: F1 裸 IPv6, type: vless, server: 2001:db8:1::370:7334, port: 443,',
      '     uuid: 00000000-0000-4000-8000-000000000041, tls: true, network: tcp}',
      '  - {name: F1 方括号 IPv6, type: vless, server: "[2001:db8:2::9]", port: 8443,',
      '     uuid: 00000000-0000-4000-8000-000000000042, tls: true}'
    ),
    expectNodes: 3,
    fields: [
      [0, 'port', 443],
      [1, 'server', '2001:db8:1::370:7334'],
      [2, 'server', '[2001:db8:2::9]'],
      [2, 'port', 8443]
    ],
    notes: '方括号 IPv6 原样透传（与其它客户端一致，不做二次改写）'
  },
  {
    id: 'F2_types_matrix',
    tags: ['types', 'vless', 'vmess', 'trojan', 'ss', 'ssr', 'hysteria2', 'hysteria',
      'anytls', 'tuic', 'unknown-future'],
    yaml: y(
      'proxies:',
      '  - {name: F2 vless, type: vless, server: f2a.example.test, port: 443,',
      '     uuid: 00000000-0000-4000-8000-0000000000a1, tls: true}',
      '  - {name: F2 vmess, type: vmess, server: f2b.example.test, port: 443,',
      '     uuid: 00000000-0000-4000-8000-0000000000a2, alterId: 0, cipher: auto}',
      '  - {name: F2 trojan, type: trojan, server: f2c.example.test, port: 443, password: REDACTED}',
      '  - {name: F2 ss, type: ss, server: f2d.example.test, port: 8388,',
      '     cipher: 2022-blake3-aes-256-gcm, password: REDACTED}',
      '  - {name: F2 ssr, type: ssr, server: f2e.example.test, port: 8389,',
      '     cipher: aes-256-cfb, password: REDACTED, protocol: auth_aes128_md5,',
      '     obfs: tls1.2_ticket_auth}',
      '  - {name: F2 hysteria2, type: hysteria2, server: f2f.example.test, port: 443,',
      '     password: REDACTED, sni: f2f.example.test, up: 100Mbps, down: 200Mbps, alpn: [h3]}',
      '  - {name: F2 hysteria, type: hysteria, server: f2g.example.test, port: 443,',
      '     auth-str: REDACTED, sni: f2g.example.test, alpn: [h3, h2]}',
      '  - {name: F2 anytls, type: anytls, server: f2h.example.test, port: 443,',
      '     password: REDACTED, client-fingerprint: chrome}',
      '  - {name: F2 tuic, type: tuic, server: f2i.example.test, port: 443,',
      '     uuid: 00000000-0000-4000-8000-0000000000a3, password: REDACTED,',
      '     congestion-controller: bbr, alpn: [h3]}',
      '  - {name: F2 未知未来协议, type: future-quic, server: f2j.example.test, port: 8443,',
      '     token: REDACTED, future-opt: {enabled: true}}'
    ),
    expectNodes: 10,
    fields: [
      [0, 'type', 'vless'],
      [1, 'alterId', 0],
      [2, 'password', 'REDACTED'],
      [3, 'cipher', '2022-blake3-aes-256-gcm'],
      [4, 'protocol', 'auth_aes128_md5'],
      [5, 'alpnList', 'h3'],
      [5, 'hyUp', '100Mbps'],
      [9, 'type', 'future-quic']
    ],
    // tuic/hysteria 属无结构化槽位的中继协议: alpn 在 extraOpts 里原样透传(不丢字段),
    // 结构化槽位 alpnList 只对 vless/vmess/trojan/hysteria2 生效。
    extras: [{ i: 8, key: 'alpn', has: 'h3' }, { i: 6, key: 'alpn', has: 'h2' },
      { i: 9, key: 'token' }, { i: 9, key: 'future-opt' }],
    notes: '未知未来协议按中继透传保留核心字段与额外键，不被丢弃'
  },
  {
    id: 'F3_bom_crlf_unicode',
    tags: ['bom', 'crlf', 'unicode', 'emoji'],
    yaml: '\uFEFFproxies:\r\n'
      + '  # 注释行\r\n'
      + '  - {name: "F3 🚀 香港 ①", type: ss, server: f3.example.test, port: 8388,\r\n'
      + '     cipher: aes-256-gcm, password: REDACTED}\r\n'
      + '# 分节内注释\r\n'
      + 'proxy-groups: []\r\n',
    expectNodes: 1,
    fields: [[0, 'name', 'F3 🚀 香港 ①']]
  },

  // ---------- G. 去重语义 ----------
  {
    id: 'G1_promo_same_content_diff_name',
    tags: ['dedup', 'promo-node', 'name-in-fingerprint'],
    yaml: y(
      'proxies:',
      '  - {name: "G1 剩余流量: 12GB", type: ss, server: g1.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED}',
      '  - {name: "G1 套餐到期: 2026-01-01", type: ss, server: g1.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED}',
      '  - {name: "G1 有超过20多个节点", type: ss, server: g1.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED}'
    ),
    expectNodes: 3,
    notes: '面板推广/公告节点与真实节点同 server:port:凭据，仅名字不同 —— 必须全部保留'
  },
  {
    id: 'G2_exact_duplicate_still_deduped',
    tags: ['dedup', 'exact-duplicate'],
    yaml: y(
      'proxies:',
      '  - {name: G2 同名同内容, type: ss, server: g2.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED}',
      '  - {name: G2 同名同内容, type: ss, server: g2.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED}'
    ),
    expectNodes: 1,
    notes: 'name + 内容完全一致才算重复'
  },
  {
    id: 'G3_same_hostport_diff_path',
    tags: ['dedup', 'same-hostport-diff-path', 'regression-guard'],
    yaml: y(
      'proxies:',
      '  - {name: G3 路径 A, type: vless, server: g3.example.test, port: 443,',
      '     uuid: 00000000-0000-4000-8000-000000000051, network: ws,',
      '     ws-opts: {path: /a, headers: {Host: g3.example.test}}}',
      '  - {name: G3 路径 B, type: vless, server: g3.example.test, port: 443,',
      '     uuid: 00000000-0000-4000-8000-000000000052, network: ws,',
      '     ws-opts: {path: /b, headers: {Host: g3.example.test}}}'
    ),
    expectNodes: 2,
    fields: [[0, 'wsPath', '/a'], [1, 'wsPath', '/b']],
    notes: '同 server:port 但 path/uuid 不同 = 不同节点（既有正确行为不得回退）'
  },
  {
    id: 'G4_cross_source_dedup',
    tags: ['dedup', 'cross-source'],
    yaml: y(
      'proxies:',
      '  - {name: G4 共享, type: ss, server: g4.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED}'
    ),
    yamls: [
      y(
        'proxies:',
        '  - {name: G4 共享, type: ss, server: g4.example.test, port: 8388,',
        '     cipher: aes-256-gcm, password: REDACTED}'
      ),
      y(
        'proxies:',
        '  - {name: G4 共享, type: ss, server: g4.example.test, port: 8388,',
        '     cipher: aes-256-gcm, password: REDACTED}',
        '  - {name: G4 镜像同内容, type: ss, server: g4.example.test, port: 8388,',
        '     cipher: aes-256-gcm, password: REDACTED}'
      )
    ],
    expectNodes: 2,
    notes: '跨订阅同名同内容仍去重；仅名字不同者保留'
  },

  // ---------- H. 无效条目统计 ----------
  {
    id: 'H1_invalid_required_fields_stats',
    tags: ['invalid-stats', 'required-fields'],
    yaml: y(
      'proxies:',
      '  - {name: H1 缺 uuid, type: vless, server: h1.example.test, port: 443}',
      '  - {name: H1 缺 password, type: trojan, server: h1b.example.test, port: 443}',
      '  - {name: H1 端口非法, type: ss, server: h1c.example.test, port: 99999,',
      '     cipher: aes-256-gcm, password: REDACTED}',
      '  - {name: H1 合法, type: ss, server: h1d.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED}'
    ),
    expectNodes: 1,
    invalidCount: 3,
    reasons: ['缺少 uuid', '缺少 password', '端口超出范围'],
    notes: '缺字段/非法字段的节点数必须可统计并给出用户可见原因'
  },
  {
    id: 'H2_unsupported_type_is_separate_stat',
    tags: ['invalid-stats', 'unsupported-type'],
    yaml: y(
      'proxies:',
      '  - {name: H2 非法协议名, type: 1bad, server: h2.example.test, port: 53}',
      '  - {name: H2 合法, type: ss, server: h2b.example.test, port: 8388,',
      '     cipher: aes-256-gcm, password: REDACTED}'
    ),
    expectNodes: 1,
    invalidCount: 0,
    skippedCount: 1,
    notes: 'type 非法/不支持走 lastSkippedCount，与 lastInvalidCount 分开统计'
  },

  // ---------- I. 块标量（`|` / `>`，缩进与显式缩进指示符、空块体） ----------
  {
    id: 'I1_block_scalar_literal_pipe',
    tags: ['block-scalar', 'literal', 'clip', 'password-slot'],
    yaml: y(
      'proxies:',
      '  - name: I1 竖线块标量',
      '    type: ss',
      '    server: i1.example.test',
      '    port: 8388',
      '    cipher: aes-256-gcm',
      '    password: |',
      '      REDACTED-PW'
    ),
    expectNodes: 1,
    fields: [[0, 'password', 'REDACTED-PW']],
    notes: '`password: |` 后缩进块体必须成为字段值（此前按「字段缺失」整条丢节点）'
  },
  {
    id: 'I2_block_scalar_folded_and_indicators',
    tags: ['block-scalar', 'folded', 'chomp-strip', 'chomp-keep', 'explicit-indent'],
    yaml: y(
      'proxies:',
      '  - name: I2a 折叠 >-',
      '    type: trojan',
      '    server: i2a.example.test',
      '    port: 443',
      '    password: >-',
      '      FOLD-ONE',
      '      FOLD-TWO',
      '  - name: I2b 显式缩进 |2',
      '    type: trojan',
      '    server: i2b.example.test',
      '    port: 443',
      '    password: |2',
      '      INDENT-VALUE',
      '  - name: I2c 保留换行 |+',
      '    type: trojan',
      '    server: i2c.example.test',
      '    port: 443',
      '    password: |+',
      '      PLUS-VALUE'
    ),
    expectNodes: 3,
    fields: [
      [0, 'password', 'FOLD-ONE FOLD-TWO'],
      [1, 'password', 'INDENT-VALUE'],
      [2, 'password', 'PLUS-VALUE']
    ],
    notes: '`>-` 折叠并去尾换行；`|2` 显式缩进指示符；`|+` 保留换行标记'
  },
  {
    id: 'I3_block_scalar_empty_body_invalid',
    tags: ['block-scalar', 'empty-body', 'invalid-stats'],
    yaml: y(
      'proxies:',
      '  - name: I3 空块体',
      '    type: trojan',
      '    server: i3.example.test',
      '    port: 443',
      '    password: |',
      '  - name: I3b 合法',
      '    type: ss',
      '    server: i3b.example.test',
      '    port: 8388',
      '    cipher: aes-256-gcm',
      '    password: REDACTED'
    ),
    expectNodes: 1,
    invalidCount: 1,
    reasons: ['缺少 password'],
    notes: '块体为空 = 字段缺失 → 计 invalid，且不得吞掉后续节点'
  },

  // ---------- J. 锚点/别名（跨文档、链式、自引用/递归、嵌套 << 深链） ----------
  {
    id: 'J1_multidoc_anchor_merge',
    tags: ['anchor', 'multidoc', 'cross-document', 'merge-key'],
    yaml: y(
      'defaults: &md-base',
      '  udp: true',
      'proxies:',
      '  - name: J1a 文档一锚点',
      '    <<: *md-base',
      '    type: ss',
      '    server: j1a.example.test',
      '    port: 8388',
      '    cipher: aes-256-gcm',
      '    password: REDACTED',
      '...',
      '---',
      'defaults2: &md-base2',
      '  udp: true',
      '  tls: true',
      'proxies:',
      '  - name: J1b 文档二锚点',
      '    <<: *md-base2',
      '    type: vless',
      '    server: j1b.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000081'
    ),
    expectNodes: 2,
    fields: [
      [0, 'udp', true],
      [1, 'udp', true],
      [1, 'tls', true]
    ],
    notes: '两个文档各自的顶层锚点都要被同一次解析看到（跨 `---`/`...` 分节定义）'
  },
  {
    id: 'J2_alias_chain_self_and_recursive',
    tags: ['anchor', 'alias-chain', 'self-reference', 'recursive-anchor', 'alias-depth-limit'],
    yaml: y(
      'anchors:',
      '  chain1: &chain-uuid 00000000-0000-4000-8000-000000000071',
      '  chain2: &chain-uuid2 *chain-uuid',
      '  selfref: &self-alias *self-alias',
      '  recursive: &rec-base',
      '    <<: *rec-base',
      '    udp: true',
      'proxies:',
      '  - name: J2a 链式别名',
      '    type: vless',
      '    server: j2a.example.test',
      '    port: 443',
      '    uuid: *chain-uuid2',
      '  - name: J2b 自引用别名',
      '    type: vless',
      '    server: j2b.example.test',
      '    port: 443',
      '    uuid: *self-alias',
      '  - name: J2c 递归合并键',
      '    <<: *rec-base',
      '    type: ss',
      '    server: j2c.example.test',
      '    port: 8388',
      '    cipher: aes-256-gcm',
      '    password: REDACTED'
    ),
    expectNodes: 2,
    fields: [
      [0, 'uuid', '00000000-0000-4000-8000-000000000071'],
      [1, 'udp', true]
    ],
    invalidCount: 1,
    reasons: ['缺少 uuid'],
    notes: '别名→别名链式解引用生效；自引用/递归锚点限深处理，不死循环、只把该字段按缺失计入 invalid'
  },
  {
    id: 'J3_nested_merge_deep_chain',
    tags: ['anchor', 'merge-key', 'nested-merge', 'deep-chain', 'ws-opts'],
    yaml: y(
      'anchors:',
      '  ws-defaults: &ws-base',
      '    path: /deep',
      '    headers:',
      '      Host: j3.example.test',
      '  hdr: &hdr-base {Host: j3h.example.test}',
      'proxies:',
      '  - name: J3 嵌套深链合并',
      '    type: vless',
      '    server: j3.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000072',
      '    network: ws',
      '    ws-opts:',
      '      <<: *ws-base',
      '      path: /override',
      '  - name: J3b 嵌套 headers 合并',
      '    type: vless',
      '    server: j3b.example.test',
      '    port: 443',
      '    uuid: 00000000-0000-4000-8000-000000000073',
      '    network: ws',
      '    ws-opts:',
      '      path: /j3b',
      '      headers:',
      '        <<: *hdr-base'
    ),
    expectNodes: 2,
    fields: [
      [0, 'wsPath', '/override'],
      [0, 'wsHost', 'j3.example.test'],
      [1, 'wsPath', '/j3b'],
      [1, 'wsHost', 'j3h.example.test']
    ],
    extrasAbsent: [[0, 'path'], [0, 'headers'], [1, 'Host']],
    notes: '嵌套容器内的 `<<` 单层与多层深链都要展开，显式键优先（只补缺失项）'
  },

  // ---------- K. dialer-proxy 依赖 ----------
  {
    id: 'K1_dialer_proxy_same_and_missing',
    tags: ['dialer-proxy', 'dependency', 'missing-target', 'extra-relay'],
    yaml: y(
      'proxies:',
      '  - name: K1 中转',
      '    type: ss',
      '    server: k1a.example.test',
      '    port: 8388',
      '    cipher: aes-256-gcm',
      '    password: REDACTED',
      '  - name: K1 依赖中转',
      '    type: ss',
      '    server: k1b.example.test',
      '    port: 8389',
      '    cipher: aes-256-gcm',
      '    password: REDACTED',
      '    dialer-proxy: K1 中转',
      '  - name: K1 依赖缺失',
      '    type: ss',
      '    server: k1c.example.test',
      '    port: 8390',
      '    cipher: aes-256-gcm',
      '    password: REDACTED',
      '    dialer-proxy: K1 不存在'
    ),
    expectNodes: 3,
    extras: [{ i: 1, key: 'dialer-proxy', has: 'K1 中转' }],
    dialerMissing: 1,
    notes: 'dialer-proxy 必须原样保留(extraOpts)；指向不存在的节点名只给诊断，节点照样导入'
  },
  {
    id: 'K2_dialer_proxy_cycle_break',
    tags: ['dialer-proxy', 'dependency-cycle', 'self-loop', 'cycle-break'],
    yaml: y(
      'proxies:',
      '  - name: K2 A',
      '    type: ss',
      '    server: k2a.example.test',
      '    port: 8388',
      '    cipher: aes-256-gcm',
      '    password: REDACTED',
      '    dialer-proxy: K2 B',
      '  - name: K2 B',
      '    type: ss',
      '    server: k2b.example.test',
      '    port: 8389',
      '    cipher: aes-256-gcm',
      '    password: REDACTED',
      '    dialer-proxy: K2 A',
      '  - name: K2 自环',
      '    type: ss',
      '    server: k2c.example.test',
      '    port: 8390',
      '    cipher: aes-256-gcm',
      '    password: REDACTED',
      '    dialer-proxy: K2 自环'
    ),
    expectNodes: 3,
    extrasAbsent: [[0, 'dialer-proxy'], [1, 'dialer-proxy'], [2, 'dialer-proxy']],
    dialerBroken: 3,
    notes: 'A↔B 互依赖与自环都要被打破（移除环上依赖）且不死循环、不丢节点'
  },

  // ---------- M. 限额（单节点只跳自己 / 全局抛 YamlMergeError） ----------
  {
    id: 'M1_node_limits_per_node_invalid',
    tags: ['limit', 'per-node-limit', 'field-limit', 'item-limit', 'no-silent-truncation'],
    yaml: y(
      'proxies:',
      '  - {name: M1 超长字段, type: ss, server: m1a.example.test, port: 8388,'
        + ` cipher: aes-256-gcm, password: ${'A'.repeat(70000)}}`,
      '  - {name: M1 超长条目, type: ss, server: m1b.example.test, port: 8389,'
        + ` cipher: aes-256-gcm, password: REDACTED, huge: ${'B'.repeat(140000)}}`,
      '  - {name: M1 合法, type: ss, server: m1c.example.test, port: 8391,'
        + ' cipher: aes-256-gcm, password: REDACTED}'
    ),
    expectNodes: 1,
    invalidCount: 2,
    reasons: ['长度超过上限', '超过上限'],
    limitSkippedCount: 2,
    fields: [[0, 'name', 'M1 合法']],
    notes: '单字段 64KB / 单节点 128KB 超限只跳过那一条并计 invalid（不再整批抛错、不再静默截断）'
  },
  {
    id: 'M2_node_count_global_limit',
    tags: ['limit', 'global-limit', 'node-count'],
    yaml: 'proxies:\n' + Array.from({ length: 10001 }, (_, i) =>
      `  - {name: M2 n${i}, type: ss, server: m2${i}.example.test, port: 8388,`
      + ' cipher: aes-256-gcm, password: REDACTED}').join('\n'),
    expectNodes: 0,
    expectGlobalError: '订阅节点数量超过上限',
    notes: '全局限额仍然是 YamlMergeError（上层据此报「超限」而不是「内容坏了」）'
  },
  {
    id: 'M3_source_count_global_limit',
    tags: ['limit', 'global-limit', 'source-count'],
    yaml: 'proxies: []',
    yamls: Array.from({ length: 1001 }, () => 'proxies: []'),
    expectNodes: 0,
    expectGlobalError: '订阅来源数量超过上限',
    notes: '来源数 >1000 抛 YamlMergeError（全局限额，不静默截断）'
  }
];

export default corpus;
