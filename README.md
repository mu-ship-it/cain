# Cain (该隐)

The name is a pun: 该隐 (Gāiyǐn) is Chinese for Cain, and read word by word, 该 + 隐, it means “ought to be hidden”.

A small, self-controlled VPN app for iPhone. A Network Extension packet tunnel
embeds the [sing-box](https://github.com/SagerNet/sing-box) core, and a box you
run yourself switches it on and off and swaps profiles remotely through
Bridge's job API, so one iOS VPN slot carries both a
Tailscale tailnet and ordinary proxy egress.

Status: early. See [docs/VPN.md](docs/VPN.md) for the sing-box core build.

## Build the sing-box core

    brew install go
    tools/build_libbox.sh      # → Vendor/Libbox.xcframework (git-ignored)

## License

MIT, see [LICENSE](LICENSE).
