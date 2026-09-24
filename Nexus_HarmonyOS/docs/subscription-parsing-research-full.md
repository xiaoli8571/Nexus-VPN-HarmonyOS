# Subscription parsing — full verified detail (appendix)

> Technical appendix to `subscription-parsing-research.md` (~1,200-word report). This file
> holds the complete per-client evidence: exact identifiers, converter mappings, error
> strings and URLs. `web_search` was unavailable (HTTP 401 on the search endpoint), so
> every claim below is grounded in a fetched primary source (raw GitHub source / official
> docs). Branch used for mihomo: **Meta**.

## 1. mihomo (MetaCubeX/mihomo) — the core

### 1.1 Who parses

The **core parses**, always. A `proxy-provider` is a first-class core object owning a
*vehicle* (transport), a *parser* (bytes → `[]C.Proxy`), a *health-check*, and exposing
itself to proxy-groups by name.

`provider.ParseProxyProvider(name, mapping, tunnel)` —
[`adapter/provider/parser.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/adapter/provider/parser.go):

```go
type proxyProviderSchema struct {
	Type          string           `provider:"type"`
	Path          string           `provider:"path,omitempty"`
	URL           string           `provider:"url,omitempty"`
	Proxy         string           `provider:"proxy,omitempty"`
	Interval      int              `provider:"interval,omitempty"`
	Filter        string           `provider:"filter,omitempty"`
	ExcludeFilter string           `provider:"exclude-filter,omitempty"`
	ExcludeType   string           `provider:"exclude-type,omitempty"`
	DialerProxy   string           `provider:"dialer-proxy,omitempty"`
	SizeLimit     int64            `provider:"size-limit,omitempty"`
	Payload       []map[string]any `provider:"payload,omitempty"`
	AgeSecretKey  string           `provider:"age-secret-key,omitempty"`

	HealthCheck healthCheckSchema   `provider:"health-check,omitempty"`
	Override    overrideSchema      `provider:"override,omitempty"`
	Header      map[string][]string `provider:"header,omitempty"`
}
```

**Corrections to the brief's premise:**
- There is **no `format` field** on `proxy-providers`.
- There is **no `user-agent` field** — it is a `header:` entry (docs example:
  `header: User-Agent: ["mihomo/1.18.3"]`).
- There is **no top-level `lazy`** — it is `health-check.lazy`, defaulting to `true` in
  code: `schema := &proxyProviderSchema{HealthCheck: healthCheckSchema{Lazy: true}}`.
- `format: yaml|base64|text` is a **GUI-side** concept. In the core, `format` exists
  **only on `rule-providers`** (see §1.9).

Official docs: <https://wiki.metacubex.one/en/config/proxy-providers/> — `type`
(`http`/`file`/`inline`), `path`, `url`, `interval`, `proxy`, `size-limit`,
`age-secret-key`, `header`, `health-check{enable,url,interval,timeout,lazy,expected-status}`,
`override` (+`override-expr`, a yq v4 subset), `filter`, `exclude-filter`, `exclude-type`,
`payload`.

### 1.2 What is passed to the core

| `type` | Vehicle | Received |
|---|---|---|
| `http` | `resource.HTTPVehicle` | **the raw URL** + `header`, `proxy`, `size-limit`, 20 s timeout. Core downloads and caches to `path` (default `C.Path.GetPathByHash("proxies", url)`). |
| `file` | `resource.FileVehicle` | a local path, constrained by `C.Path.IsSafePath` / `SAFE_PATHS`. |
| `inline` | none | `payload:` used directly. |

[`component/resource/vehicle.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/component/resource/vehicle.go):
`HTTPVehicle.Read` GETs via `mihomoHttp.HttpRequest`, supports `If-None-Match`/ETag
(global `etag-support`), and returns `(buf, hash)` — the hash is compared so unchanged
payloads do **not** trigger a proxy rebuild. `subscription-userinfo` is captured via
`SetInRead` and persisted through `cachefile.Cache()` (`NewProxySetProvider`). `payload:`
also serves as a **fallback proxy list** when the HTTP/file parse fails.

### 1.3 Format detection — no `format` field

`NewProxiesParser` in [`adapter/provider/provider.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/adapter/provider/provider.go):

```go
if err := yaml.Unmarshal(buf, schema); err != nil {
	proxies, err1 := convert.ConvertsV2Ray(buf)
	if err1 != nil { return nil, fmt.Errorf("%w, %w", err, err1) }
	schema.Proxies = proxies
}
if schema.Proxies == nil {
	return nil, errors.New("file must have a `proxies` field")
}
```

`age.DecryptBytes(buf, ageSecretKey)` runs **before** this. Accepted inputs: **Clash YAML
with `proxies:`**, **plain `scheme://` links**, **base64 of that list**. Docs confirm
([content page](https://wiki.metacubex.one/en/config/proxy-providers/content/)):
"`YAML`/`uri`/`base64` cannot be written in the same file; `uri`/`base64` do not require
the `proxies:` field". **No sing-box JSON, Quantumult X, Surge or LOON.**

### 1.4 Base64 / plain detection

[`common/convert/base64.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/common/convert/base64.go):

```go
// DecodeBase64 try to decode content from the given bytes, which can be in
// base64.RawStdEncoding, base64.StdEncoding or just plaintext.
func DecodeBase64(buf []byte) []byte {
	result, err := tryDecodeBase64(buf)
	if err != nil { return buf }   // plaintext passthrough
	return result
}
```

`tryDecodeBase64` tries `RawStdEncoding` then `StdEncoding`. `TryDecodeBase64` (per-field,
for `ssr://` bodies, `vmess://` JSON, username:password) tries `StdEncoding`/`URLEncoding`
when `len%4 == 0`, else `RawStdEncoding`/`RawURLEncoding`.

### 1.5 Link → proxy conversion

[`common/convert/converter.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/common/convert/converter.go)
— splits on `\n`, trims `" \r"`, `strings.Cut(line, "://")`, lowercases the scheme,
`switch`es. Schemes: `hysteria`, `hysteria2`/`hy2`/`hysteria2+realm`/`hy2+realm`, `tuic`,
`trojan`, `vless`, `vmess`, `ss`, `ssr`, `socks`/`socks5`/`socks5h`/`http`/`https`,
`anytls`, `mieru`.

- **Duplicate names** de-duplicated by `uniqueName(names, name)` → `name-01`, `name-02`.
  Essential: Clash rejects duplicate proxy names.
- `vmess://` tries **base64-JSON** (v2rayN; keys `ps/add/port/id/aid/scy/net/type/host/
  path/tls/sni/alpn`) then falls back to the **Xray VMessAEAD URI** via `handleVShareLink`.
  Hard-codes `alterId: 0`, `cipher: "auto"`, `udp: true`, `xudp: true`, `tls: false`.
- `ss://` tries three shapes (`user:pass@host:port`, base64 `method:password@host:port`,
  `ss://<base64>` with no port) and validates with `VerifyMethod(cipher, password)`,
  retrying `encRaw` if invalid. Plugin string `plugin=obfs-local;obfs=http;obfs-host=…`
  parsed by rewriting `;`→`&` and `urlParseQuery("pluginName="+plugin)`.
- `hysteria2` port hopping via `splitHysteria2Ports` → rewrites URL to first port, returns
  raw `ports` → `ports:` field.

[`common/convert/v.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/common/convert/v.go)
— `handleVShareLink` (shared by `vless` and AEAD `vmess`):

```go
tls := strings.ToLower(query.Get("security"))
if strings.HasSuffix(tls, "tls") || tls == "reality" {
	proxy["tls"] = true
	if fingerprint := query.Get("fp"); fingerprint == "" {
		proxy["client-fingerprint"] = "chrome"
	} else { proxy["client-fingerprint"] = fingerprint }
	if alpn := query.Get("alpn"); alpn != "" { proxy["alpn"] = strings.Split(alpn, ",") }
	if pcs := query.Get("pcs"); pcs != "" { proxy["fingerprint"] = pcs }
}
if sni := query.Get("sni"); sni != "" { proxy["servername"] = sni }
if realityPublicKey := query.Get("pbk"); realityPublicKey != "" {
	realityOpts := map[string]any{"public-key": realityPublicKey, "short-id": query.Get("sid")}
	if value := query.Get("support-x25519mlkem768"); value != "" { /* bool */ }
	proxy["reality-opts"] = realityOpts
}
switch query.Get("packetEncoding") {
case "none":
case "packet": proxy["packet-addr"] = true
default:       proxy["xudp"] = true
}
```

Transport: `type=tcp` + `headerType=http` → `http`; `type=http` → `h2`; `ws`/`httpupgrade`
→ `ws-opts` with a **randomised** `User-Agent` (`RandUserAgent()`), `ed` →
`max-early-data` (ws) or `v2ray-http-upgrade-fast-open: true` (httpupgrade), `eh` →
`early-data-header-name`; `grpc` → `grpc-opts.grpc-service-name` from `serviceName`;
`xhttp` → `xhttp-opts` via `parseXHTTPExtra` (~120 lines translating xray-core `extra`:
`xmux`→`reuse-settings`, `downloadSettings`→`download-settings`, `xPadding*`, `seq*`,
`session*`, `scMaxEachPostBytes`, …).

Per-protocol: `vless` → `flow` (lowercased), `encryption`; `trojan` → `allowInsecure`→
`skip-cert-verify`, `type`→`network`, `pcs`→`fingerprint`, default
`client-fingerprint: "chrome"`; `hysteria` → `peer`→`sni`, `auth`→`auth_str`,
`up`/`upmbps`, `down`/`downmbps`, `insecure`, `protocol`, `obfs`; `hysteria2` → `obfs`,
`obfs-password`, `sni`, `pinSHA256`→`fingerprint`, `down`/`up`, `?auth=` for realm,
`+realm` → `realm-opts{enable,server-url,token,realm-id,stun-servers}`; `tuic` →
`congestion_control`→`congestion-controller`, `udp_relay_mode`→`udp-relay-mode`,
`disable_sni=1`→`disable-sni`, `uuid:password` (v5) vs `token` (v4) discriminated by
presence of a password in userinfo.

### 1.6 Per-node failure handling

**Silent per-node drop; zero-node result is a hard error.** Every scheme branch
`continue`s on failure. Only vless and AEAD-vmess log:
`log.Warnln("error:%s line:%s", err.Error(), line)`. Terminal:
`return nil, fmt.Errorf("convert v2ray subscribe error: format invalid")`.

So: **all-or-nothing per subscription, silent best-effort per node, no user-visible
diagnostics.** Filter/override errors *are* fatal and name the index:
`fmt.Errorf("proxy %d error: %w", idx, err)`, `fmt.Errorf("proxy %d override error: %w", …)`,
`errors.New("doesn't match any proxy, please check your filter")`.

### 1.7 Filter / override semantics

- `filter`: split on `` ` `` into `regexp2` regexes, OR-ed; must match at least one.
  (The outer `for _, filterReg := range filterRegs` loop can append a proxy twice, but
  `proxiesSet` guards by name.)
- `exclude-filter`: split on `` ` ``, any match skips.
- `exclude-type`: split on `|`, `strings.EqualFold` vs the mapping's `type`, applied
  **before** `filter`.
- `override`: `override.Apply(mapping)` mutates the **raw mapping before `ParseProxy`**,
  so new/unknown fields are overridable. `override-expr` runs after fixed fields.
- Provider proxies use `adapter.ParseProxy(..., adapter.WithProviderName(pdName))`.

### 1.8 API surface

`providerForApi` exposes `name`, `type`, `vehicleType`, `proxies`, `testUrl`,
`expectedStatus`, `updatedAt`, `subscriptionInfo` — a GUI can read parsed providers via
`/providers/proxies` without parsing anything.

### 1.9 The `format` asymmetry

[`rules/provider/parse.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/rules/provider/parse.go)
has `Format string \`provider:"format,omitempty"\`` on `ruleProviderSchema` —
`proxy-providers` has no equivalent.
[`constant/provider/interface.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/constant/provider/interface.go):

```go
func ParseRuleFormat(s string) (format RuleFormat, err error) {
	switch s {
	case "", "yaml": format = YamlRule
	case "text":     format = TextRule
	case "mrs":      format = MrsRule
	default: err = fmt.Errorf("unsupported format type: %s", s)
	}
	return
}
```

`format: yaml|text|mrs` is a **rule-provider** concept; a `proxy-provider` is sniffed with
no field to declare it. This is the largest source of confusion in the brief's premise.

### 1.10 `override` uses pointer fields deliberately

[`adapter/provider/override.go`](https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/adapter/provider/override.go):
`TFO *bool`, `MPTcp *bool`, `UDP *bool`, `UDPOverTCP *bool`, `Up *string`, `Down *string`,
`DialerProxy *string`, `SkipCertVerify *bool`, `NameCertVerify *string`,
`Interface *string`, `RoutingMark *int`, `IPVersion *string`, `AdditionalPrefix *string`,
`AdditionalSuffix *string`, `ProxyName []overrideProxyNameSchema`, `OverrideExpr []OverrideExpr`.
`Apply` nil-checks each (`if o.TFO != nil { mapping["tfo"] = *o.TFO }`), so only
explicitly-set keys apply — a value-struct unmarshal would clobber every node with Go zero
values. Order inside `Apply`: fixed fields → `proxy-name` regex replace →
`additional-prefix` → `additional-suffix` → `override-expr`.

---

## 2. NekoBox + sing-box

### 2.1 Who parses

- **NekoBox: parses in Kotlin, itself.** `RawUpdater.parseRaw(text, fileName)`;
  `GroupUpdater.executeUpdate()` fetches via `Libcore.newHttpClient()` and reads the
  `Subscription-Userinfo` header.
- **sing-box core: no subscription/share-link parser at all.** Exhaustive tree scan found
  **zero** `subscription*` paths and no `vless://`-style parsing. `common/convertor/`
  contains only `adguard/convertor.go`. The core is config-file-only: `cmd_check.go` is
  `readConfigAndMerge()` → `box.New()`. GUIs are separate submodules (`clients/android`,
  `clients/apple`, `clients/desktop`).
- NekoBox links a **vendored/patched sing-box as a library** (`libcore.Libcore`).
- Branch note: sing-box default branch is **`testing`**; `dev` and `main` both 404.

### 2.2 Format detection — sniffing, no enum

No format enum exists. Each stage is `try/catch` and **fails silently to the next**:

```kotlin
if (text.contains("proxies:")) { … YAML/Clash … }         // 1 naive substring
else if (text.contains("[Interface]")) { … WireGuard … }  // 2 INI
try { parseJSON(JSONTokener(text).nextValue()) }          // 3
try { parseProxies(text.decodeBase64UrlSafe()) }          // 4
try { parseProxies(text) }                                // 5
return null
```

Clash detection is a bare substring, so it breaks on `proxies :`. `Util.b64Decode`
normalises `-`/`_`→`+`/`/` then tries `Base64.DEFAULT` and `Base64.NO_WRAP`.
**No user-facing format override** — only `subscription.customUserAgent`, `forceResolve`
and `deduplication` on `SubscriptionBean`.

### 2.3 Formats and schemes

- **Clash YAML: yes** — SnakeYAML `proxies:` covering `socks5`, `http`, `ss` (+
  `plugin`/`plugin-opts` obfs & v2ray-plugin), `vmess`, `vless`, `trojan`, `anytls`,
  `hysteria`, `hysteria2`, `tuic`; reads top-level `global-client-fingerprint`;
  `clashCipher()` maps `"dummy"` → `"none"`. `clash://install-config?url=` becomes a
  subscription.
- **Links:** `sn://`, `socks://|socks4://|socks4a://|socks5://`, `http(s)://`, `vmess://`,
  `vless://`, `trojan://`, `trojan-go://`, `ss://`, `naive+`, `hysteria://`,
  `hysteria2://|hy2://`, `tuic://`, `anytls://`. **Not supported:** `ssr://`, `snell://`,
  `wireguard://` (WG only via `.conf`), `mieru`, ssh links.
- **sing-box JSON: yes** — JSON with `outbounds` → `ConfigBean` (`type = 1`), filtering
  `dns|block|direct|selector|urltest`. Clash YAML is **translated into NekoBox beans**,
  not passed through.
- **Quantumult X: partial** — only the `Subscription-Userinfo` header.
- **Surge / LOON: no.**

### 2.4 Per-node failures

**Drop the node, never abort:** each branch is
`runCatching { entities.add(parseX(this)) }.onFailure { Logs.w(it) }`. Only two aborts:
`SubscriptionFoundException` (link starts `clash://install-config?` or
`sn://subscription?`) and `parseRaw` returning `null` → `no_proxies_found`.
**No per-node diagnostics in the UI**: `GroupManager.Interface` has
`onUpdateFailure(group, message)` (one whole-subscription string) and
`onUpdateSuccess(group, changed, added, updated, deleted, duplicate, byUser)` — name
lists, not errors.

### 2.5 Nodes → core config

Room/Kryo DB first, **then** generated sing-box JSON. Beans (`VMessBean`,
`ShadowsocksBean`, `HysteriaBean`, `TuicBean`, `WireGuardBean`, `AnyTLSBean`,
`SOCKSBean`, `HttpBean`, `TrojanBean`, `SSHBean`) persist as Kryo blobs in `ProxyEntity`;
`fmt/ConfigBuilder.kt: buildConfig()` builds `MyOptions` and emits `gson.toJson(configMap)`.

Verified: `group/RawUpdater.kt`, `ktx/Formats.kt`, `group/GroupUpdater.kt`,
`fmt/ConfigBuilder.kt`, `database/GroupManager.kt`;
trees <https://api.github.com/repos/MatsuriDayo/NekoBoxForAndroid/git/trees/main?recursive=1>
and <https://api.github.com/repos/SagerNet/sing-box/git/trees/testing?recursive=1>.

---

## 3. FlClash (chen08209/FlClash)

### 3.1 Who parses

**Delegates entirely to a vendored mihomo.** `core/go.mod`:
`replace github.com/metacubex/mihomo => ./Clash.Meta`; `.gitmodules`: `core/Clash.Meta` →
`github.com/chen08209/Clash.Meta`, branch `FlClash`. **No `clash-rs` anywhere under `lib/`.**
Three files whose names suggest parsing are red herrings: `lib/common/converter.dart`
(`Uint8List`↔`List<int>`), `lib/common/provider_reader.dart`
(`typedef ProviderReader = T Function<T>(ProviderListenable<T> provider)` — Riverpod), and
`lib/common/proxy.dart` (system-proxy plugin handle).

### 3.2 What is passed

**A generated Clash YAML config containing `proxy-providers:`.**

1. **Profile bytes are downloaded by Dart**: `Profile.update` →
   `request.getFileResponseForUrl(url)` (`dio` + `IOHttpClientAdapter`; `findProxy` →
   `FlClashHttpOverrides.findProxyForReader`, so **the download goes through the running
   proxy**). Reads `content-disposition` and `subscription-userinfo`
   (`SubscriptionInfo.formHString`: `upload=..;download=..;total=..;expire=..`), then
   `Profile.saveFile` writes `profiles/<id>.yaml`.
2. **Providers inside a profile are fetched by mihomo**; FlClash only rewrites their
   `path:`: `_makeRealProfileTask` calls
   `confineProviders('proxy-providers', proxiesProviderDirectoryName)` /
   `confineProviders('rule-providers', …)` setting
   `provider['path'] = join(profilesPath, providersDirectoryName, profileId, type, key.toMd5())`
   with key `'$name@$url'`; `type == 'inline'` skipped.

Transport is **IPC/RPC, not REST**: `CoreMethod` has `getConfig`, `setupConfig`,
`validateConfig`, `getExternalProviders`, `getExternalProvider`, `updateExternalProvider`,
`sideLoadExternalProvider`, `clearEffect`. Core side: `loadConfig` →
`filepath.Join(constant.Path.HomeDir(), "config.yaml")` → `executor.ParseWithBytes(buf)`.

### 3.3 Formats accepted — Clash YAML only

`Profile.saveFile` writes a temp file, awaits `validate(path)`, throws `MessageException`
if the error string is non-empty. That is `handleValidateConfig` → mihomo
`config.UnmarshalRawConfig`. Verified in **both** upstream and FlClash's own fork
([`config/config.go`](https://raw.githubusercontent.com/chen08209/Clash.Meta/FlClash/config/config.go)):

```go
func UnmarshalRawConfig(buf []byte) (*RawConfig, error) {
	rawCfg := DefaultRawConfig()
	buf, err := age.DecryptBytes(buf)
	if err != nil { return nil, fmt.Errorf("decrypt config error: %w", err) }
	if err := yaml.Unmarshal(buf, rawCfg); err != nil { return nil, err }
	return rawCfg, nil      // <-- no ConvertsV2Ray here
}
```

A v2ray/base64 subscription URL **cannot** be pasted into FlClash's profile importer; only
`proxies:`-bearing Clash YAML passes. Share links are reachable only transitively via a
`proxy-provider` whose `url:` the *core* fetches.

### 3.4 Per-node failures → fail the whole subscription

No Dart per-node try/catch. **Validate-then-atomic-replace**: temp write → `validate` →
`MessageException`, previous `profiles/<id>.yaml` untouched; surfaced via
`globalState.loadingRun(...)`. Runtime `applyConfig` logs
`"config apply failed, falling back to the built-in default - no proxies will be available: %v"`
and applies `config.ParseRawConfig(config.DefaultRawConfig())`. Provider refresh errors
map to `provider_not_found`, `provider_updating`, `provider_update_error`,
`request_bad_response`, `request_error` (`providerRequestErrorCode`).

### 3.5 Overwrite chain

`OverwriteType { standard, script, custom }` stored as `profiles.overwriteType` +
`scriptId` + `matchTarget`: `standard` merges added/disabled rules with MATCH-placeholder
retargeting; `custom` sets `rawConfig['proxy-groups']`/`['rules']`; `script` →
`lib/common/javascript.dart handleEvaluate(scriptContent, config)` ships the **whole config
as JSON** to a Rust `evaluate_script` bridge (QuickJS/`rquickjs`), expects
`main(config)` to return the config, force-creates `config['proxy-providers'] = {}` when
absent, rejects non-Map returns with `'script did not return a configuration object'`,
10 s interrupt deadline + memory ceiling. Order (`lib/providers/actions/setup.dart`
`getProfile`): `_core.getConfig(profileId)` → optional `handleEvaluate` →
`makeRealProfileTask` → YAML.

### 3.6 Where filter / UA / lazy live

Not DB columns. `profiles` is exactly `id, label, currentGroupName, url, lastUpdateDate,
overwriteType, scriptId, matchTarget, autoUpdateDurationMillis, subscriptionInfo,
autoUpdate, selectedMap, unfoldSet, order`. `filter`, `exclude-filter`, `exclude-type`,
`lazy`, `interval` are modelled on **proxy groups** (`lib/models/clash_config.dart`
`ProxyGroup`). UA override is **global only**: `PatchClashConfig.globalUa` → `global-ua`.

### 3.7 Providers read back, not parsed

No `/providers/proxies` REST call in `lib/`. `Providers.syncProviders()` →
`getExternalProviders()`; core `handleGetExternalProviders` builds from
`tunnel.ProvidersSnapshot()` + `tunnel.RuleProvidersSnapshot()`, keeping only
`p.VehicleType() != cp.Compatible`; `toExternalProvider` returns
`Name/Type/VehicleType/Count/UpdateAt/Path/SubscriptionInfo`. Controller defaults off
(`ExternalControllerStatus.close`) and loopback-only. *(The `.agents/architecture.md`
file in this repo notes the core RPC surface.)*

---

## 4. ClashMetaForAndroid (MetaCubeX/ClashMetaForAndroid)

### 4.1 Who parses — delegates; not a format adapter

**No Kotlin parser**: no `ConvertsV2Ray`, no base64, no `proxy-providers:` template in
Kotlin. Core is the submodule `core/src/foss/golang/clash` → `MetaCubeX/mihomo` branch
**Alpha**, via `replace github.com/metacubex/mihomo => ../../foss/golang/clash`.

### 4.2 What is passed — the raw URL only

```kotlin
// ProfileProcessor.kt
Clash.fetchAndValid(context.processingDir, source, force) { … }.await()
```

The **core downloads** and writes the body verbatim
([`fetch.go`](https://raw.githubusercontent.com/MetaCubeX/ClashMetaForAndroid/main/core/src/main/golang/native/config/fetch.go)):

```go
configPath := P.Join(path, "config.yaml")
if _, err := os.Stat(configPath); os.IsNotExist(err) || force {
	header, err := fetch(url, configPath)   // raw bytes, unmodified
```

Sole explicit header `User-Agent: ClashMetaForAndroid/<versionName>`; **60 s timeout**;
schemes `http`/`https`/`content://`; extracts `subscription-userinfo` and
`profile-update-interval`. **No `proxy-providers:` block is ever synthesised.** A CMFA
profile is literally the downloaded body + a `providers/` dir.

### 4.3 Format — YAML only at the top level

[`load.go`](https://raw.githubusercontent.com/MetaCubeX/ClashMetaForAndroid/main/core/src/main/golang/native/config/load.go)
(`main`) calls `config.UnmarshalRawConfig(configData)` — pure `yaml.Unmarshal`, **no
share-link fallback** (verified directly). `validConfig` errors with
`"profile does not contain 'proxies' or 'proxy-providers'"`. Same trap as FlClash/Verge.
*(Minor branch divergence: some builds on `Alpha` add a fallback here; `main` does not.)*

### 4.4 Per-node failures — mixed

Malformed lines `continue`; `log.Warnln("error:%s line:%s", …)` only for
`handleVShareLink`. Per-proxy `adapter.ParseProxy` errors **abort the whole provider**
(`proxy %d error: %w`). Surface: `FetchAndValid` error → `C.fetch_complete` → Kotlin
`.await()` throws → `ProfileWorker.failed()` posts a failure notification. Progress via
`FetchStatus` actions `FetchConfiguration` / `FetchProviders` / `SubscriptionInfo` /
`Verifying`.

### 4.5 Override — global JSON, not per-profile YAML

```go
if err := json.NewDecoder(strings.NewReader(ReadOverride(OverrideSlotPersist))).Decode(cfg); err != nil {
	log.Warnln("Apply persist override: %s", err.Error())
}
```

Stored at `constant.Path.Resolve("override.json")`, slots `OverrideSlotPersist` /
`OverrideSlotSession`. **Global (not per-profile)**, **JSON (not YAML)**, and its typed
schema `ConfigurationOverride.kt` deliberately excludes
`proxies`/`proxy-providers`/`proxy-groups` — so it **cannot inject providers**. No
template/merge/script chain. Processor order: `patchExternalController → patchOverride →
patchGeneral → patchProfile → patchDns → patchTun → patchListeners → patchProviders →
validConfig`. `patchProviders` rewrites each provider `path` to
`profileDir + "/providers/" + path` (hash of URL when absent).
`patchExternalController` runs *before* `patchOverride` so the override wins.

---

## 5. Clash Verge Rev (clash-verge-rev/clash-verge-rev)

### 5.1 Who parses — the GUI does (Rust)

[`src-tauri/src/config/prfitem.rs`](https://raw.githubusercontent.com/clash-verge-rev/clash-verge-rev/main/src-tauri/src/config/prfitem.rs)
(`PrfItem::from_url`):

```rust
let yaml = serde_yaml_ng::from_str::<Mapping>(data)
    .context("the remote profile data is invalid yaml")?;
if !yaml.contains_key("proxies") && !yaml.contains_key("proxy-providers") {
    bail!("profile does not contain `proxies` or `proxy-providers`");
}
```

`proxy-providers` present in the subscription are passed through verbatim (fetched by
mihomo); the app only *reads* them (`enhance/mod.rs::cleanup_proxy_groups` collects keys to
keep `use:`/`proxies:` references valid) and nudges the core via
`request_runtime_provider_sync(...)`. **`clash-rs` is not used** — absent from both
`Cargo.toml`s and `Cargo.lock`; `base64` appears only for HTTP Basic auth.

### 5.2 Download and what reaches the core

`utils/network.rs::NetworkManager::get` with
`User-Agent: clash-verge/v{CARGO_PKG_VERSION}` (overridable via `PrfOption.user_agent`),
redirects `limited(10)`, rustls + webpki fallback, default timeout **20 s**
(`option.timeout_seconds`), `danger_accept_invalid_certs`; proxy modes
`ProxyType::{None, Localhost, System}` with retry direct → clash → system. Parses
`subscription-userinfo` (plus any `*-subscription-userinfo` prefix) into
`PrfExtra { upload, download, total, expire }`, plus `profile-update-interval` and
`profile-web-page-url`.

Bytes → `<app_data>/profiles/<uid>.yaml` (`R` remote / `L` local). `enhance::enhance()`
builds `IRuntime.config`; `Config::runtime_config_yaml()` serialises with a
`# Generated by Clash Verge` header to `<app_data>/config.yaml`. Assembly: `process_seq_items`
→ `merge_default_config(clash_config)` → `apply_builtin_scripts` → `use_tun` →
`apply_dns_settings` → **global Merge → global Script → profile Merge → profile Script** →
enforce authoritative → `cleanup_proxy_groups` → `use_sort`.

### 5.3 Formats

**Clash YAML only.** No base64/plain link list, sing-box JSON, Quantumult X, Surge or LOON
paths exist. `PrfItem` (serde rename `type`): `uid, itype, name, file, desc, url,
selected: Vec<PrfSelected{name, now}>, extra: PrfExtra, updated, option: PrfOption, home,
file_data`, with `itype ∈ {remote, local, merge, script, rules, proxies, groups}`.

### 5.4 Enhance chain

- **Merge** (`enhance/merge.rs`): `deep_merge(a, b)` recursive mapping merge; keys
  lowercased via `use_lowercase`. `enhance/seq.rs::use_seq` handles
  `prepend`/`append`/`delete` on `rules`/`proxies`/`proxy-groups` (new proxies auto-added
  to the first `select` group).
- **Script** (`enhance/script.rs`): **`boa_engine = "0.22.0"`**, entry
  `main(config, profileName)`, limits 5 s timeout / 10M loop iterations / 10 MB JSON /
  1000 outputs / 1 MB logs, `console.*` via `__verge_log__`. **Fail-soft**: on error logs
  `("exception", reason)` and returns the input config unchanged.
- `IRuntime { config, dns_override, exists_keys, chain_logs }`; surfaced via
  `get_runtime_logs`.

### 5.5 Errors / atomicity

Import is **atomic per profile**: `cmd/profile.rs::import_profile` returns
`PROFILE_IMPORT_FAILED`, item not appended. Whole-config validation runs the mihomo
sidecar `-t -d <app_dir> -f <check.yaml>` (`core/validate.rs`) with
`ValidationErrorKind::{FileMissing, FileRead, YamlSyntax, YamlMapping, ScriptSyntax,
ScriptMissingMain, CoreRejected, ProcessTerminated, Timeout}`. Profile switching is
transactional (`patch_profiles_config` draft + `discard_and_restore`). Per-node failures
are not reported; `cleanup_proxy_groups` silently prunes dangling members. Frontend does
**no** parsing — only `invoke('import_profile', { url, option })` and friends.

Docs: <https://www.clashverge.dev/guide/profile.html> ·
<https://www.clashverge.dev/guide/script.html>

---

## 6. Comparison

| | **mihomo** | **NekoBox** | **FlClash** | **CMFA** | **Clash Verge Rev** |
|---|---|---|---|---|---|
| Parser lives in | core (Go) | **GUI (Kotlin)** | core (vendored mihomo) | core (mihomo submodule) | **GUI (Rust)** |
| Core has link parser? | **yes** (`ConvertsV2Ray`) | n/a | yes | yes | yes (unused at top level) |
| Top-level format | n/a | YAML/JSON/WG/b64/links | **Clash YAML only** | **Clash YAML only** | **Clash YAML only** |
| Handed to core | config w/ `proxy-providers:` | — (self-contained) | generated config + `path:` rewrite | **raw URL only** | bytes → generated config |
| Who downloads | core | GUI (`Libcore`) | GUI (`dio`, via proxy) | **core** (60 s) | GUI (`reqwest`, 20 s) |
| `subscription-userinfo` | yes, cached | yes | yes | yes | yes → `PrfExtra` |
| base64 link list | yes | yes | **no** | **no** | **no** |
| plain link list | yes | yes | **no** | **no** | **no** |
| sing-box JSON | no | yes (`ConfigBean`) | no | no | no |
| Quantumult X | no | header only | no | no | no |
| Surge / LOON | no | no | no | no | no |
| `format` field | **rule-providers only** | none (sniffs) | none | none | none |
| Format detection | YAML → b64/links | substring → WG → JSON → b64 → links | mihomo validate gate | mihomo validate gate | YAML + key check |
| Per-node failure | drop + `Warnln` | drop + `Logs.w` | n/a (core) | drop, but `ParseProxy` aborts | n/a (core) |
| Whole-sub failure | zero nodes ⇒ error | `no_proxies_found` | `MessageException`, atomic | failure notification | `PROFILE_IMPORT_FAILED` |
| Per-node diagnostics? | **no** | **no** | **no** | **no** | **no** |
| Override/merge/script | `override` + `override-expr` | none | `OverwriteType` | global JSON | Merge + Script (`boa`) |
| Providers read back via | — | own DB | core RPC | — | `request_runtime_provider_sync` |

## 7. Converged reference architecture

1. **The core owns link→proxy conversion; the GUI owns transport, caching and UI.** Four
   of five clients reimplement no parsing. Even FlClash and CMFA — which bundle mihomo —
   add only a UA string, a timeout, header extraction and `path:` rewriting.
2. **Pass a `proxy-provider`, not parsed nodes.** The unit handed to the core is a provider
   (URL or file), because that is what yields `interval`, `filter`, `exclude-type`,
   `override`, health-check, ETag revalidation and `payload` fallback for free.
   Verge/FlClash/CMFA additionally confine the provider's `path:` to an app-owned
   directory (mirroring mihomo's `IsSafePath`/`SAFE_PATHS`).
3. **Detect format by trying, in a fixed order — never by a declared field.**
4. **Two-tier error policy: silent per-node drop, loud whole-subscription failure.** No
   client surfaces per-node diagnostics.
5. **Cache to disk by content hash**; unchanged hash skips the proxy rebuild.
6. **Validate the composed config before applying it** (sidecar `-t`, `validConfig`,
   `validateConfig`), with rollback where possible.
7. **A post-download mutation chain layered outside parsing** — operating on *parsed
   config*, never raw subscription bytes.

**Recommendation:** put a `proxy-provider` in the generated config and let the core fetch
it. Hand-roll a parser only when the core genuinely lacks one (NekoBox's situation).

## 8. Pitfalls of a hand-rolled app-language parser

Grounded in what the core does that a naive reimplementation omits.

**Lossy protocol mapping**
- **REALITY** must emit `reality-opts: {public-key: <pbk>, short-id: <sid>}`; mihomo also
  reads `support-x25519mlkem768`. Treating `security=reality` as plain TLS silently
  produces a node that connects to the wrong thing. Note `fp` → `client-fingerprint`
  (default `"chrome"`) while `pcs` → `fingerprint` — **two different fields**.
- **`flow`**: `flow=xtls-rprx-vision` must be lowercased and preserved; dropping it is a
  hard handshake failure on many servers.
- **hysteria2 up/down**: `up`/`down` (and `upmbps`/`downmbps` for hysteria1) are bandwidth
  strings; also `obfs` + `obfs-password`, `pinSHA256` → `fingerprint`, and **port
  hopping** (`splitHysteria2Ports` → `ports:`), which a naive `url.Parse` mangles because
  `host:1000-2000` is not a valid port.
- **tuic**: `congestion_control` → `congestion-controller`, `udp_relay_mode` →
  `udp-relay-mode`, `disable_sni=1` → `disable-sni`, and the **v4-vs-v5 discrimination**
  (`uuid:password` ⇒ v5; bare token ⇒ v4) — backwards yields wrong-version auth.
- **ws early-data**: `ed` → `max-early-data` **plus** `early-data-header-name:
  "Sec-WebSocket-Protocol"`, and `ed` must then be *deleted from the path*. `eh`
  overrides the header name. For `httpupgrade`, `ed` instead sets
  `v2ray-http-upgrade-fast-open: true`. `Host`/`User-Agent` must be injected into
  `ws-opts.headers` (mihomo uses a **randomised** UA).
- **grpc**: `serviceName` → `grpc-opts.grpc-service-name` (not `service-name`).
- **alpn**: comma-split into a **list**; passing the raw string silently disables ALPN.
- **`packetEncoding`**: `none` / `packet` → `packet-addr: true` / default → `xudp: true`.
  Three-way, not two-way.
- **xhttp**: xray-core's `extra` JSON → `xhttp-opts` (~30 renamed keys). Effectively
  unimplementable by hand.
- **ss**: three URL shapes + plugin-string parsing (`;` → `&`) + cipher validation via
  `VerifyMethod`, with a base64-alphabet retry.
- **vmess**: base64-JSON *then* AEAD-URI fallback; `net`/`type` cross-mapping
  (`type=http` ⇒ `http`, `net=http` ⇒ `h2`); hard-coded `alterId: 0`, `cipher: "auto"`.

**Structural**
- **Duplicate names are fatal in Clash.** `uniqueName` emits `name-01`, `name-02`; a
  parser preserving provider names verbatim produces a config the core rejects.
  Verge/FlClash work around this via `additional-prefix`/`additional-suffix` and
  `cleanup_proxy_groups`.
- **Base64 leniency.** Strict decoding rejects unpadded input; mihomo tries
  `RawStdEncoding` then `StdEncoding` and otherwise **treats input as plaintext**.
  NekoBox normalises `-`/`_`→`+`/`/` and tries `DEFAULT` and `NO_WRAP`.
- **Unknown/new fields are the real risk.** `override.Apply` mutates the *raw mapping*
  before `ParseProxy`, and `override-expr` is a yq subset precisely so users can patch
  fields the core doesn't model. Emit mappings, not typed structs.
- **`override` needs pointer/nil semantics**, or a value-struct unmarshal clobbers every
  node with zero values.
- **Proxy-group semantics belong to the core**: `use:`, `proxyGroupsDagSort` cycle
  detection, sorted `AllProxies`/`AllProviders` pools, the reserved `default` provider,
  the synthetic `GLOBAL` group, `COMPATIBLE`.
- **Rule providers are a separate pipeline**: `behavior` (`domain|ipcidr|classical`) and
  `format` (`yaml|text|mrs`), plus `path-in-bundle` and `.mrs` binaries.
- **Don't parse at the top level.** FlClash, CMFA and Verge all require Clash YAML for the
  *profile itself* (`UnmarshalRawConfig` has no share-link fallback), while the
  `proxy-provider` path *does* fall back to `ConvertsV2Ray`. Routing a link list through
  the profile path instead of a provider is the most common integration bug.
- **Transport details matter**: serve `subscription-userinfo`, `profile-update-interval`,
  `Content-Disposition`; honour `ETag`/`If-None-Match` (`etag-support`); `size-limit`;
  and let the download go through the tunnel (FlClash's `findProxy`; mihomo's `proxy:`).
