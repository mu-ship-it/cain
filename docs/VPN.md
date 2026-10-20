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

## License

sing-box and sing-box-for-apple are GPL-3.0-or-later; Cain's own code is MIT. A built Cain
(the extension links Libbox) is a combined work distributed under GPL-3.0 terms. Details in
[NOTICE](../NOTICE).
