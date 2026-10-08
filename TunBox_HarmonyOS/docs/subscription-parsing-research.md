# Subscription parsing in mihomo / Clash clients — reference design

> Condensed report (spec target ≈1,200 words). Full verified detail — every Go/Rust/Kotlin
> identifier and converter mapping — is in `subscription-parsing-research-full.md`.
> `web_search` was unavailable (HTTP 401), so all claims come from fetched primary sources.

## mihomo (MetaCubeX/mihomo) — the core parses, always

A `proxy-provider` is a first-class core object: vehicle (transport) + parser (bytes →
`[]C.Proxy`) + health-check. Entry point `provider.ParseProxyProvider`
([parser.go](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/adapter/provider/parser.go)).
Types: `http` (core receives **the raw URL**), `file` (a path, checked against
`IsSafePath`/`SAFE_PATHS`), `inline` (`payload:`).

**Correction to the premise:** `proxy-providers` has **no `format`, no `user-agent`, and
no top-level `lazy`.** `lazy` is `health-check.lazy` (defaults `true` in code);
`user-agent` is just a `header:` entry. `format: yaml|base64|text` is a *GUI* concept —
and in the core it exists **only on `rule-providers`**, where
`ParseRuleFormat` accepts `""|yaml|text|mrs`
([interface.go](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/constant/provider/interface.go)).

**Format detection** is a two-step sniff in `NewProxiesParser`, not a field:
try Clash YAML, and on unmarshal failure fall back to `convert.ConvertsV2Ray`; then
require `schema.Proxies != nil` (`file must have a 'proxies' field`). Accepted: Clash YAML
with `proxies:`, a plain `scheme://` link list, or base64 of that list
([docs](https://wiki.metacubex.one/en/config/proxy-providers/content/)). **No sing-box
JSON, Quantumult X, Surge or LOON.** Base64-vs-plain is not a branch: `DecodeBase64` tries
`RawStdEncoding` then `StdEncoding` and otherwise returns the **original bytes**
([base64.go](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/common/convert/base64.go)).

`ConvertsV2Ray` handles `hysteria`, `hysteria2`/`hy2`/`+realm`, `tuic`, `trojan`, `vless`,
`vmess`, `ss`, `ssr`, `socks*`, `http(s)`, `anytls`, `mieru`; `handleVShareLink`
([v.go](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/common/convert/v.go))
carries the protocol fidelity: REALITY → `reality-opts{public-key,short-id}` (+
`support-x25519mlkem768`), `fp`→`client-fingerprint` (default `"chrome"`) vs `pcs`→
`fingerprint`, `flow`, `alpn` comma-split, `packetEncoding`→`xudp`/`packet-addr`,
`ed`→`max-early-data`+`early-data-header-name`, `serviceName`→`grpc-service-name`,
and xray `extra`→`xhttp-opts` (~30 renamed keys).

**Failure policy: silent per-node drop, loud whole-subscription failure.** Every scheme
branch `continue`s on error; only vless/AEAD-vmess log `Warnln("error:%s line:%s")`. Zero
nodes ⇒ `convert v2ray subscribe error: format invalid`. Per-proxy
`adapter.ParseProxy` errors *are* fatal (`proxy %d error: %w`). **No per-node diagnostics
exist.** `override.Apply` mutates the raw mapping before `ParseProxy` using **pointer
fields** so only explicitly-set keys apply.

## NekoBox + sing-box

**NekoBox parses in Kotlin; the sing-box core has no subscription parser at all.**
Exhaustive tree scan found zero `subscription*` paths and no `vless://`-style parsing;
`common/convertor/` holds only `adguard/convertor.go`. The core is config-file-only
(`cmd_check.go` → `box.New()`). NekoBox links a patched sing-box as a library.

`RawUpdater.parseRaw` sniffs, with each stage failing **silently** to the next:
`contains("proxies:")` → `contains("[Interface]")` → `parseJSON` →
`parseProxies(decodeBase64UrlSafe)` → `parseProxies`. **No format enum and no UI override.**
Clash YAML detection is a bare substring, so it breaks on `proxies :`. Accepts Clash YAML,
sing-box JSON (`outbounds` → `ConfigBean`), WireGuard `.conf`, base64 and plain links;
schemes include `ss`, `vmess`, `vless`, `trojan`, `hysteria(2)`, `tuic`, `anytls` —
**not `ssr://`**, `snell://`, `mieru`. Quantumult X only for the `Subscription-Userinfo`
header; **no Surge/LOON**. Per-node failures are dropped
(`runCatching{…}.onFailure{Logs.w(it)}`); only nested-subscription detection or an empty
result aborts. Nodes go to a Room/Kryo DB, then `ConfigBuilder.buildConfig()` emits
**sing-box JSON**.

## FlClash, CMFA, Clash Verge Rev — all three: no app-language parser

| | FlClash | CMFA | Verge Rev |
|---|---|---|---|
| Parses in app? | no (vendored mihomo) | no (mihomo submodule) | **yes, Rust** |
| Handed to core | generated config + `path:` rewrite | **raw URL only** | downloaded bytes → generated config |
| Downloads | Dart `dio`, **through the proxy** | **the core**, 60 s | `reqwest`, 20 s |
| Top-level formats | Clash YAML only | Clash YAML only | Clash YAML only |
| Post-chain | `OverwriteType{standard,script,custom}` | global JSON `override.json` | Merge → Script (`boa_engine`) |

- **FlClash**: `core/go.mod` `replace github.com/metacubex/mihomo => ./Clash.Meta`
  (branch `FlClash`); **no `clash-rs`**. `confineProviders` rewrites each provider `path:`
  to an app-owned file keyed `'$name@$url'`. Transport is IPC/RPC (`getConfig`,
  `setupConfig`, `validateConfig`, `getExternalProviders`), not REST.
- **CMFA**: `Clash.fetchAndValid(processingDir, source, force)` passes the URL; the core
  writes the body verbatim as `config.yaml` with sole header
  `User-Agent: ClashMetaForAndroid/<version>`. `override.json` is **global, JSON, and
  cannot inject providers**. No merge/script chain.
- **Verge Rev**: `PrfItem::from_url` does `serde_yaml_ng::from_str::<Mapping>` and `bail!`s
  unless `proxies`/`proxy-providers` is present. `clash-rs` absent from Cargo.toml/lock.
  Import is atomic (`PROFILE_IMPORT_FAILED`); validation runs the mihomo sidecar `-t`;
  profile switches use a draft transaction with rollback. Scripts fail soft.

**The shared trap:** all three accept **only Clash YAML** for the *profile itself*,
because `UnmarshalRawConfig` is pure `yaml.Unmarshal` with **no `ConvertsV2Ray`
fallback** — verified in upstream, in FlClash's fork, and in CMFA's `load.go`. The
share-link path is reachable **only** via `proxy-providers`. Routing a link list through
the profile path instead of a provider is the most common integration bug.

## Converged reference architecture

1. **Core owns link→proxy conversion**; the GUI owns transport, caching, UI. Four of five
   clients reimplement no parsing.
2. **Pass a `proxy-provider`, not parsed nodes** — you inherit `interval`, `filter`,
   `exclude-type`, `override`, health-check, ETag revalidation, `payload` fallback.
3. **Detect by trying, in fixed order — never by a declared field.** No client exposes a
   format selector.
4. **Two-tier errors: silent node drop, loud empty-result failure.** No client surfaces
   per-node diagnostics.
5. **Cache by content hash**; unchanged hash skips the rebuild.
6. **Validate the composed config before applying** (sidecar `-t`, `validConfig`, or
   `validateConfig`), with rollback where possible.
7. **Mutate *parsed config*, never raw bytes**, in a post-download chain.

**Recommendation:** generate a `proxy-provider` and let the core fetch it. Hand-roll a
parser only when the core genuinely lacks one (NekoBox's situation).

## Pitfalls of a hand-rolled parser

**Lossy protocol mapping:** REALITY `reality-opts`; `fp` vs `pcs` (two different fields);
`flow` lowercasing; hysteria2 `up`/`down` and **port hopping** (`host:1000-2000` is not a
valid port, so `url.Parse` mangles it); tuic `congestion_control`→
`congestion-controller`, `udp_relay_mode`, `disable_sni`, and v4-vs-v5 `uuid:password`
vs bare `token`; ws `ed`→`max-early-data` **plus** deleting `ed` from the path, and
`httpupgrade`'s different meaning; `serviceName`→`grpc-service-name`; `alpn` must be a
**list**; `packetEncoding` is three-way; xhttp `extra` is effectively unimplementable;
`ss` has three URL shapes + plugin strings + cipher validation; `vmess` is base64-JSON
**then** AEAD-URI.

**Structural:** duplicate names are **fatal** in Clash (mihomo emits `name-01`) —
naive parsers produce configs the core rejects; base64 must be lenient (unpadded →
plaintext); **unknown/new fields** require emitting mappings rather than typed structs
(this is exactly why `override-expr` is a yq subset); `override` needs pointer/nil
semantics; proxy-group semantics (`use:`, DAG sort, reserved `default`, synthetic
`GLOBAL`) belong to the core; `rule-providers` are a separate pipeline with
`behavior` + `format: yaml|text|mrs`; and don't forget transport details —
`subscription-userinfo`, `profile-update-interval`, `ETag`/`If-None-Match`,
`size-limit`, and tunnelling the download.
