# VPN tunnel (sing-box)

Cain (该隐) is a small VPN app: a Network Extension packet tunnel (`CainExt`)
that embeds the [sing-box](https://github.com/SagerNet/sing-box) core. The box
switches it on and off and swaps profiles through `vpn.*` capabilities, so one
iOS VPN slot carries both the tailnet (sing-box's native Tailscale endpoint) and
the regular proxy egress.

## Libbox (the sing-box core)

`Vendor/Libbox.xcframework` is a gomobile binding of `sing-box/experimental/libbox`.
It is not committed (git-ignored, ~hundreds of MB); rebuild it with:

    tools/build_libbox.sh

| | |
|---|---|
| sing-box tag | `v1.14.3` (commit `7054cac`) |
| gomobile | `github.com/sagernet/gomobile` `v0.1.13` (sing-box `make lib_install`) |
| Go | 1.27.2 (go.mod asks for ≥ 1.25.5) |
| slices | `ios` (arm64), `iossimulator` (arm64 + x86_64) |
| min iOS | 15.0 |
| build tags | `with_gvisor, with_quic, with_wireguard, with_utls, with_naive_outbound, with_clash_api, with_usbip, with_openvpn, with_openconnect, badlinkname, tfogo_checklinkname0, with_tailscale, ts_omit_logtail, ts_omit_ssh, ts_omit_drive, ts_omit_taildrop, ts_omit_webclient, ts_omit_doctor, ts_omit_capture, ts_omit_kube, ts_omit_aws, ts_omit_synology, ts_omit_bird, with_dhcp, grpcnotrace` |

The tag set is not hand-picked: the script runs sing-box's own
`cmd/internal/build_libbox -target apple -platform ios,iossimulator`, which is
what the official sing-box-for-apple app is built with. `with_tailscale` is in
its shared tag list since 1.11; `with_gvisor` gives the userspace TCP/IP stack.
`with_low_memory` is applied to non-macOS slices by the builder
(`-tags-not-macos`), which keeps the extension under iOS's ~50 MB memory cap.

## Targets and ids

| | |
|---|---|
| app | target `Cain`, bundle `dev.boringbox.cain`, display name 该隐 |
| tunnel | target `CainExt` (NEPacketTunnelProvider), bundle `dev.boringbox.cain.ext` |
| App Group | `group.dev.boringbox.cain` (profiles, selected profile, tunnel log) |

Ids come from `Config/Cain.xcconfig` (`CAIN_BUNDLE_ID`); the App Group and extension ids
follow from it. A fork sets its own in the gitignored `Config/Local.xcconfig`.

## How the tunnel runs

- The app keeps one `NETunnelProviderManager` pointing at `CainExt` (created and saved on
  first start; iOS asks once to allow the VPN).
- Profiles are sing-box JSON configs stored by name in the App Group
  (`Profiles/<name>.json`); the selected name is in `selected-profile`. Start passes the
  profile name; the extension reads the file itself, so a restart by iOS (no app involved)
  still finds the selected profile.
- Before handing the config to sing-box the extension sets `log.output` to the shared log
  file (`Logs/tunnel.log`, timestamps on) and leaves every other field alone. The log is a
  ring buffer: over 512 KB it is cut back to the newest 256 KB when the tunnel starts.
- Switching profile while on: the app sends the extension a `reload` message, and sing-box
  reloads in place (`startOrReloadService`) without dropping the tunnel.
- The extension answers sing-box's platform calls itself: it applies
  `NEPacketTunnelNetworkSettings` from sing-box's tun options and hands back the utun fd,
  follows the default interface with `NWPathMonitor`, and says "not supported" to shell,
  SSH, bridge and process lookup. The tailnet machine name defaults to `cain`.

## Entitlements, and what a paid account unlocks

Both targets carry:

| entitlement | value | free account? |
|---|---|---|
| `com.apple.developer.networking.networkextension` | `[packet-tunnel-provider]` | **no**: paid Apple Developer Program only |
| `com.apple.security.application-groups` | `[group.dev.boringbox.cain]` | yes |

Signing is Automatic. Simulator builds are ad-hoc signed and carry the entitlements unsigned
(`*-Simulated.xcent`), so everything compiles and the app UI runs. A packet tunnel cannot
run in the simulator. A signed device build needs a provisioning profile with the Network
Extension capability, which Apple only issues to paid teams; with a personal (free) team,
Xcode's automatic signing cannot create it. That is the one blocker. (Not attempted here, by
design: no device signing until the paid account exists.)

Builds checked:

    xcodegen generate
    xcodebuild -scheme Cain -destination 'platform=iOS Simulator,name=iPhone 17' build
    xcodebuild -scheme Cain -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

The last one compiles and links the device slice without signing; it is not installable.
The extension binary is about 75 MB (Debug); the ~50 MB iOS limit for packet tunnels is on
memory in use, not binary size, and sing-box's OOM killer is on.

## Driving it from the box

Cain is a second device on the same box as Bridge, using Bridge's existing job API
(`GET /bridge/jobs`, `POST /bridge/results`, `POST /bridge/events`; see Bridge's docs/API.md).
No new server endpoints. In Settings: the box URL, the token, and a device id (default `cain`).
The box can queue jobs for `cain` before the phone has ever polled:

    bridge job enqueue <account> cain vpn.status
    bridge job enqueue <account> cain vpn.start '{"profile":"home","note":"Going out; tailnet + proxy on"}'

**When jobs arrive.** Within a second while Cain is open (long poll); otherwise on iOS
background app refresh (roughly every 15 minutes or more, at iOS's discretion), or when Mu
taps Poll now. Cain does not register for silent push yet, so with the app closed a job can
wait. See "Next steps".

**Notes.** Every job may carry the agent's plain-words `note` (top level or `params.note`), shown
in Cain's activity feed; a job without one gets Cain's own words ("Box turned the VPN on").
Every vpn.* result also carries a `note` saying what happened, and that is the row's summary.
When Cain sees the tunnel go on or off it posts a `vpn` event to the box whose note is the
status line, e.g. `VPN on · profile home`.

### Capabilities

| capability | params | result |
|---|---|---|
| `vpn.status` | – | `{state, on, profile, since?, last_error?, note}`; `state` is `on`, `off`, `connecting`, `reconnecting`, `disconnecting` or `not set up` |
| `vpn.start` | `profile?` (default: the selected one; also selects it), `timeout?` s (5–60, default 20) | status, once the tunnel is on. Already on: switches profile in place if a different one was named |
| `vpn.stop` | `timeout?` s (3–30, default 10) | status, once off |
| `vpn.profile.list` | – | `{count, selected, profiles: [{name, bytes, modified, selected}], note}`; never the configs themselves |
| `vpn.profile.set` | `name` | `{selected, reloaded, note}`; while on, the tunnel reloads into it without dropping |
| `vpn.profile.put` | `name`, `config` (JSON object or JSON text), `select?` | `{name, bytes, replaced, selected, reloaded, complete: true, note}`. Replacing the running profile reloads it |
| `vpn.profile.put` (chunked) | `name`, `part` (1-based), `parts` (≤ 64), `data` (≤ 256 KB each), `select?` | `{name, received, parts, complete: false, note}` until the last part, then as above |
| `vpn.log.tail` | `lines?` (1–500, default 50) | `{count, lines, note}`, oldest first. The log can name hosts the tunnel connected to |

Profile names: 1–64 of `A–Z a–z 0–9 . _ -`, starting with a letter or digit. A profile is at
most 1 MB and must be one JSON object; sing-box checks the rest when the tunnel starts (a
start that fails returns `failed` with sing-box's message, also in `vpn.log.tail`).
Error codes: `bad_params`, `not_found` (no such profile, or none selected), `timeout`,
`failed`, `unknown_capability`.

### Profile size and chunks

The job API itself has no size limit. The reference box's CLI takes params as one command-line
argument, and Linux caps a single argument at 128 KB. A sing-box profile whose rule sets are
remote (`.srs` by URL, as the converter writes them) is a few KB, so the whole form is the
normal one. For anything bigger, cut the JSON text into pieces and send one `vpn.profile.put`
job per piece with `part`/`parts`/`data`. Parts may arrive in any order and more than once;
staging older than a day is dropped; a different `parts` count starts over. The profile is
validated when the last part lands.

## From a mihomo / Clash config

    python3 tools/clash2singbox.py clash.yaml -o profile.json
    python3 tools/clash2singbox.py clash.yaml --provider mylist=https://example.com/mylist.srs
    python3 tools/clash2singbox.py clash.yaml --no-tailscale

Python 3, stdlib only (it carries a small reader for the YAML subset Clash configs use, including
anchors and `<<` merges). It converts:

- **proxies**: ss (incl. obfs / v2ray-plugin), vmess, vless (incl. REALITY, Vision), trojan,
  hysteria2, tuic, socks5, http, snell v4; ws / grpc / h2 / http / httpupgrade transports;
  TLS, uTLS fingerprints. WireGuard becomes a sing-box endpoint.
- **proxy-groups**: select → selector; url-test → urltest; fallback and load-balance →
  urltest (warned). `use:` / `filter` / `include-all` are not converted (warned).
- **rules**: DOMAIN, -SUFFIX, -KEYWORD, -REGEX, IP-CIDR(6), SRC-IP-CIDR, DST-/SRC-PORT,
  NETWORK, GEOIP / GEOSITE (as SagerNet's remote `.srs` rule sets; `GEOIP,LAN` →
  `ip_is_private`), RULE-SET, MATCH → `route.final`. Consecutive lines of the same kind and
  target merge into one rule. Before the first IP rule without `no-resolve` it adds a `resolve`
  action, as Clash would resolve there. REJECT → `reject`, REJECT-DROP → `reject` / `drop`.
  AND / OR / NOT and port ranges are not converted (warned).
- **rule-providers**: by URL. sing-box can't read Clash-format lists, so a provider whose URL
  is not `.srs` / `.json` is skipped with a warning unless you give its sing-box equivalent with
  `--provider NAME=URL`.

It adds what Cain needs: a TUN inbound (gvisor stack); DNS with a `domestic` server (Clash's
first `nameserver`, else 223.5.5.5) for `geosite-cn` and a `remote` one (first `fallback`, else
1.1.1.1 over HTTPS) through the final outbound; rule-set downloads through the final outbound
(`http_clients`); and a **Tailscale endpoint** (`ts-ep`, hostname `cain`, MagicDNS for `ts.net`,
tailnet ranges routed to it) whose `auth_key` is the placeholder `${TS_AUTHKEY}`. sing-box
does not expand variables: substitute it when you upload (or run with
`--fill-authkey-from-env`, which reads `$TS_AUTHKEY`; keep that output out of git). Use a
reusable or tagged auth key; the machine then stays in the tailnet across restarts (state is
kept in the App Group). fake-ip DNS mode is not carried over (warned).

Tested with a synthetic config (`tests/fixtures/clash-sample.yaml`, reserved example domains
and documentation IPs only): `python3 -m unittest discover -s tests -v`. With a sing-box CLI at
`build/sing-box` (or `$SING_BOX`) the tests also run `sing-box check` on the output.

## What works today, and what waits on the paid account

Works now (simulator / Mac): the app, profile store, activity feed, box connection, all seven
capabilities against the box (they report the tunnel as `not set up` and `vpn.start` fails with
iOS's message, since the simulator has no VPN), the converter, all tests.

Round trip against a box, opt-in: run Bridge's `tools/mock_box.py` (token `devtoken`), queue
vpn.* jobs on it (`curl -XPOST localhost:8787/_enqueue -d '{"capability":"vpn.status"}'`),
then

    TEST_RUNNER_CAIN_E2E_BOX=http://localhost:8787 xcodebuild -scheme Cain \
      -destination 'platform=iOS Simulator,name=iPhone 17' test

The test polls once with the real job loop and capabilities; the mock box prints each result.
While the app only hosts tests it never polls on its own, so the test's poll is the only one.

Waits on a paid Apple Developer Program membership:
- `com.apple.developer.networking.networkextension` (packet-tunnel-provider) on both App IDs.
  Without it there is no provisioning profile, so no device install, no tunnel, no Tailscale.

### Next steps once the paid account exists

1. **Apple Developer portal → Identifiers**: register `dev.boringbox.cain` and
   `dev.boringbox.cain.ext`. On both, enable **Network Extensions** and **App Groups**.
2. **App Groups**: register `group.dev.boringbox.cain` and assign it to both identifiers.
3. Put the team id in `Config/Local.xcconfig` (`DEVELOPMENT_TEAM = …`), run
   `tools/build_libbox.sh` and `xcodegen generate`, open the project and build to the phone with
   Automatic signing. On first start iOS asks to allow the VPN configuration.
4. Upload a profile: `tools/clash2singbox.py` → substitute `${TS_AUTHKEY}` → `vpn.profile.put`
   (with `"select": true`) → `vpn.start`. Check `vpn.log.tail`.
5. **TestFlight**: in App Store Connect create the app (`dev.boringbox.cain`), archive in Xcode
   (Product → Archive) and upload; internal testing needs no review. Before any wider release,
   settle the license question in NOTICE (GPL-3.0 combined work).
6. Worth doing then: silent push (APNs, also paid-only) so a job reaches Cain within seconds
   with the app closed, as Bridge does; and measure the extension's memory with the real
   profile (iOS's packet-tunnel limit is about 50 MB).

## License

sing-box and sing-box-for-apple are GPL-3.0-or-later; Cain's own code is MIT. A built Cain
(the extension links Libbox) is a combined work distributed under GPL-3.0 terms. Details in
[NOTICE](../NOTICE).
