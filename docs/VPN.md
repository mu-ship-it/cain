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
