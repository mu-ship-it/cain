# Cain (该隐)

The name is a pun: 该隐 (Gāiyǐn) is Chinese for Cain, and read word by word, 该 + 隐, it means “ought to be hidden”.

A small, self-controlled VPN app for iPhone. A Network Extension packet tunnel
embeds the [sing-box](https://github.com/SagerNet/sing-box) core, and a box you
run yourself switches it on and off and swaps profiles remotely through
Bridge's job API, so one iOS VPN slot carries both a
Tailscale tailnet and ordinary proxy egress.

Status: early. Builds for the simulator; running the tunnel on a phone needs a paid Apple
Developer account (Network Extension entitlement). See [docs/VPN.md](docs/VPN.md).

## Build (simulator, no account needed)

    brew install go xcodegen
    tools/build_libbox.sh      # sing-box core → Vendor/Libbox.xcframework (git-ignored)
    xcodegen generate
    xcodebuild -scheme Cain -destination 'platform=iOS Simulator,name=iPhone 17' build

## Driving Cain from your box

Cain is a second device on a [Bridge](#copied-from-bridge) box: same job API, no new
endpoints. Set the box URL, token and device id (`cain`) in Settings, then queue jobs:

    bridge job enqueue <account> cain vpn.profile.put '{"name":"home","config":{…},"select":true}'
    bridge job enqueue <account> cain vpn.start '{"note":"Going out"}'
    bridge job enqueue <account> cain vpn.status

Seven capabilities: `vpn.status`, `vpn.start`, `vpn.stop`, `vpn.profile.list`,
`vpn.profile.set`, `vpn.profile.put` (whole or chunked), `vpn.log.tail`. Every result carries a
plain-words `note` ("VPN on · profile home"), and Cain posts a `vpn` event to the box when the
tunnel goes on or off. Jobs arrive within a second while the app is open, otherwise on
background refresh. `tools/clash2singbox.py` turns a mihomo / Clash config into a sing-box
profile with a Tailscale endpoint. Details, limits and the paid-account next steps:
[docs/VPN.md](docs/VPN.md).

## Test

    xcodebuild -scheme Cain -destination 'platform=iOS Simulator,name=iPhone 17' test
    python3 -m unittest discover -s tests -v

## Project layout

    Cain/          the app: box connection (Core/), vpn.* capabilities, tunnel controller, screens
    CainExt/       the packet-tunnel extension (sing-box via Libbox)
    Shared/        compiled into both: App Group paths, profile store, tunnel log, theme
    CainTests/     unit tests (Swift Testing)
    Config/        bundle ids (Cain.xcconfig); your team id in Local.xcconfig (gitignored)
    tools/         build_libbox.sh, clash2singbox.py, make_icon.swift
    tests/         converter tests + a synthetic Clash config
    Vendor/        Libbox.xcframework (built, not committed)

## Copied from Bridge

Cain reuses code from Bridge (phonebridge, MIT, same author) by copying, at commit `ba990d1`:

| Cain | from Bridge |
|---|---|
| `Shared/Theme.swift` | `Shared/Theme.swift` (Boring Box look) |
| `Cain/Core/JSONValue.swift` | `Shared/JSONValue.swift` |
| `Cain/Core/ForegroundPoller.swift` | `Bridge/Core/ForegroundPoller.swift` |
| `Cain/Core/BackgroundTime.swift` | `Bridge/Core/BackgroundTime.swift` |
| `Cain/Core/Models.swift` | `Bridge/Core/Models.swift` (trimmed) |
| `Cain/Core/Capability.swift` | `Bridge/Core/Capability.swift` (trimmed, + `Params.profileName`) |
| `Cain/Core/BoxClient.swift` | `Bridge/Core/BoxClient.swift` (job API + events only) |
| `Cain/Core/Keychain.swift` | `Bridge/Core/Keychain.swift` (`BridgeConfig` → `BoxConfig`) |
| `Cain/Core/JobLoop.swift` | `Bridge/Core/JobLoop.swift` (trimmed) |
| `Cain/Core/Activity.swift` | `Bridge/Core/Activity.swift` (vpn.* summaries) |
| `Cain/Core/AppStatus.swift` | `Bridge/Core/AppStatus.swift` (polls + activity only) |
| `Cain/UI/SettingsView.swift` | `Bridge/UI/SettingsView.swift` (no duty mode) |
| `tools/make_icon.swift` | `tools/make_icon.swift` (adapted: Cain's mark, `--tinted`) |

Each copied file says so in its first line. Not a shared package yet: the two apps may drift.

## License

Cain's own code is MIT, see [LICENSE](LICENSE). The built app links sing-box (GPL-3.0),
so a built Cain is distributed under GPL-3.0 terms; see [NOTICE](NOTICE).
