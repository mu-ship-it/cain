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

## Project layout

    Cain/          the app: tunnel controller, home screen
    CainExt/       the packet-tunnel extension (sing-box via Libbox)
    Shared/        compiled into both: App Group paths, profile store, tunnel log, theme
    Config/        bundle ids (Cain.xcconfig); your team id in Local.xcconfig (gitignored)
    tools/         build_libbox.sh
    Vendor/        Libbox.xcframework (built, not committed)

## Copied from Bridge

Cain reuses code from Bridge (phonebridge, MIT, same author) by copying, at commit `ba990d1`:

| Cain | from Bridge |
|---|---|
| `Shared/Theme.swift` | `Shared/Theme.swift` (Boring Box look) |

## License

Cain's own code is MIT, see [LICENSE](LICENSE). The built app links sing-box (GPL-3.0),
so a built Cain is distributed under GPL-3.0 terms; see [NOTICE](NOTICE).
