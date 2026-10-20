#!/usr/bin/env python3
"""Convert a mihomo / Clash YAML config into a sing-box (1.14) JSON profile for Cain.

    python3 tools/clash2singbox.py clash.yaml -o profile.json
    python3 tools/clash2singbox.py clash.yaml --provider mylist=https://example.com/mylist.srs
    python3 tools/clash2singbox.py clash.yaml --no-tailscale

Stdlib only (it carries a small YAML reader for the subset Clash configs use). Converts:
proxies, proxy-groups, rules, rule-providers given by URL. Adds a TUN inbound for iOS, a DNS
split (domestic / remote / tailnet), and a Tailscale endpoint whose auth key is left as the
placeholder ${TS_AUTHKEY}: sing-box does not expand variables, so substitute it when you upload
(or pass --fill-authkey-from-env to take it from $TS_AUTHKEY). Anything it can't carry over is
listed as a warning on stderr; the profile is still written.
"""
import argparse
import json
import os
import re
import sys

AUTHKEY_PLACEHOLDER = "${TS_AUTHKEY}"
GEOSITE_URL = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-{}.srs"
GEOIP_URL = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-{}.srs"
TAILNET_V4, TAILNET_V6 = "100.64.0.0/10", "fd7a:115c:a1e0::/48"


class ConvertError(Exception):
    pass


# ---------------------------------------------------------------------------------------------
# YAML (the subset Clash / mihomo configs use)
# ---------------------------------------------------------------------------------------------

class YAMLError(ConvertError):
    pass


def _strip_comment(line):
    """Drops a `#` comment that starts the line or follows whitespace, outside quotes."""
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
            elif ch == "\\" and quote == '"':
                continue
        elif ch in "'\"" and (i == 0 or line[i - 1] in " \t:[{,-"):
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def _plain_scalar(text):
    t = text.strip()
    if t in ("", "~", "null", "Null", "NULL"):
        return None
    if t in ("true", "True", "TRUE"):
        return True
    if t in ("false", "False", "FALSE"):
        return False
    if re.fullmatch(r"[-+]?\d+", t):
        return int(t)
    if re.fullmatch(r"[-+]?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?", t):
        return float(t)
    return t


def _quoted(text, i):
    """Parses a quoted scalar starting at text[i]; returns (value, index after it)."""
    q = text[i]
    out = []
    j = i + 1
    while j < len(text):
        ch = text[j]
        if q == "'" and ch == "'":
            if j + 1 < len(text) and text[j + 1] == "'":
                out.append("'")
                j += 2
                continue
            return "".join(out), j + 1
        if q == '"' and ch == "\\":
            nxt = text[j + 1] if j + 1 < len(text) else ""
            simple = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "/": "/", "0": "\0"}
            if nxt in simple:
                out.append(simple[nxt])
                j += 2
                continue
            if nxt == "u":
                out.append(chr(int(text[j + 2:j + 6], 16)))
                j += 6
                continue
            raise YAMLError(f"unsupported escape \\{nxt}")
        if q == '"' and ch == '"':
            return "".join(out), j + 1
        out.append(ch)
        j += 1
    raise YAMLError(f"unterminated quote in: {text.strip()}")


class _Flow:
    """Recursive reader for flow collections: {a: 1, b: [x, y]}."""

    def __init__(self, text, anchors):
        self.text, self.i, self.anchors = text, 0, anchors

    def skip(self):
        while self.i < len(self.text) and self.text[self.i] in " \t\n":
            self.i += 1

    def value(self):
        self.skip()
        ch = self.text[self.i] if self.i < len(self.text) else ""
        if ch == "{":
            return self.mapping()
        if ch == "[":
            return self.sequence()
        if ch in "'\"":
            v, self.i = _quoted(self.text, self.i)
            return v
        if ch == "*":
            m = re.match(r"\*([^\s,\]\}]+)", self.text[self.i:])
            self.i += m.end()
            return _alias(self.anchors, m.group(1))
        start = self.i
        depth = 0
        while self.i < len(self.text):
            c = self.text[self.i]
            if c in ",]}" and depth == 0:
                break
            if c == ":" and depth == 0 and (self.i + 1 == len(self.text) or self.text[self.i + 1] in " ,]}"):
                break
            self.i += 1
        return _plain_scalar(self.text[start:self.i])

    def mapping(self):
        self.i += 1
        out = {}
        while True:
            self.skip()
            if self.text[self.i] == "}":
                self.i += 1
                return out
            key = self.value()
            self.skip()
            if self.i < len(self.text) and self.text[self.i] == ":":
                self.i += 1
                val = self.value()
            else:
                val = None
            out[str(key) if not isinstance(key, str) else key] = val
            self.skip()
            if self.text[self.i] == ",":
                self.i += 1
            elif self.text[self.i] != "}":
                raise YAMLError(f"expected , or }} in: {self.text.strip()}")

    def sequence(self):
        self.i += 1
        out = []
        while True:
            self.skip()
            if self.text[self.i] == "]":
                self.i += 1
                return out
            out.append(self.value())
            self.skip()
            if self.text[self.i] == ",":
                self.i += 1
            elif self.text[self.i] != "]":
                raise YAMLError(f"expected , or ] in: {self.text.strip()}")


def _alias(anchors, name):
    if name not in anchors:
        raise YAMLError(f"unknown alias *{name}")
    return json.loads(json.dumps(anchors[name]))   # a copy


def _balanced(text):
    depth, quote = 0, None
    for ch in text:
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
    return depth <= 0


def _split_key(content):
    """'key: value' → (key, value-text) or None when the line is not a mapping entry."""
    if content[0] in "'\"":
        key, j = _quoted(content, 0)
        rest = content[j:].lstrip()
        if not rest.startswith(":"):
            return None
        return key, rest[1:].strip()
    if content[0] in "[{":
        return None
    m = re.match(r"([^:]+?)\s*:(\s+|$)", content)
    if not m:
        return None
    return m.group(1).strip(), content[m.end():].strip()


def parse_yaml(text):
    lines = []
    for raw in text.replace("\t", "  ").splitlines():
        stripped = _strip_comment(raw).rstrip()
        if not stripped.strip() or stripped.strip() in ("---", "..."):
            continue
        if stripped.lstrip().startswith("%"):
            continue
        lines.append([len(stripped) - len(stripped.lstrip()), stripped.lstrip()])
    anchors = {}
    if not lines:
        return {}
    value, i = _block(lines, 0, lines[0][0], anchors)
    if i != len(lines):
        raise YAMLError(f"unexpected indentation at: {lines[i][1]}")
    return value


def _block(lines, i, indent, anchors):
    if lines[i][1] == "-" or lines[i][1].startswith("- "):
        return _sequence(lines, i, indent, anchors)
    return _mapping(lines, i, indent, anchors)


def _inline_value(lines, i, text, indent, anchors):
    """The value after `key:` or `- `; may continue on deeper lines. Returns (value, next i)."""
    anchor = None
    m = re.match(r"&(\S+)\s*", text)
    if m:
        anchor, text = m.group(1), text[m.end():]
    if text.startswith("*"):
        value = _alias(anchors, text[1:].strip())
    elif text in ("|", "|-", "|+", ">", ">-", ">+"):
        parts = []
        while i < len(lines) and lines[i][0] > indent:
            parts.append(lines[i][1])
            i += 1
        value = ("\n" if text[0] == "|" else " ").join(parts)
    elif text == "":
        if i < len(lines) and (lines[i][0] > indent or
                               (lines[i][0] == indent and (lines[i][1] == "-" or lines[i][1].startswith("- ")))):
            value, i = _block(lines, i, lines[i][0], anchors)
        else:
            value = None
    elif text[0] in "[{":
        while not _balanced(text):
            if i >= len(lines):
                raise YAMLError("unterminated flow collection")
            text += " " + lines[i][1]
            i += 1
        value = _Flow(text, anchors).value()
    elif text[0] in "'\"":
        value, _ = _quoted(text, 0)
    else:
        value = _plain_scalar(text)
    if anchor:
        anchors[anchor] = value
    return value, i


def _mapping(lines, i, indent, anchors):
    out = {}
    while i < len(lines) and lines[i][0] == indent:
        content = lines[i][1]
        if content == "-" or content.startswith("- "):
            break
        kv = _split_key(content)
        if kv is None:
            raise YAMLError(f"expected 'key: value' at: {content}")
        key, rest = kv
        value, i = _inline_value(lines, i + 1, rest, indent, anchors)
        if key == "<<":
            for src in value if isinstance(value, list) else [value]:
                if not isinstance(src, dict):
                    raise YAMLError("<< merge needs a mapping")
                for k, v in src.items():
                    out.setdefault(k, v)
        else:
            out[key] = value
    if i < len(lines) and lines[i][0] > indent:
        raise YAMLError(f"unexpected indentation at: {lines[i][1]}")
    return out, i


def _sequence(lines, i, indent, anchors):
    out = []
    while i < len(lines) and lines[i][0] == indent and (lines[i][1] == "-" or lines[i][1].startswith("- ")):
        content = lines[i][1][1:]
        rest = content.lstrip()
        if rest and _split_key(rest) is not None and rest[0] not in "[{":
            # "- key: value": a mapping whose first entry shares the dash line.
            inner = indent + 1 + (len(content) - len(rest))
            lines[i] = [inner, rest]
            value, i = _mapping(lines, i, inner, anchors)
        else:
            value, i = _inline_value(lines, i + 1, rest, indent, anchors)
        out.append(value)
    return out, i


# ---------------------------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------------------------

def _list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _tls(p, always=False):
    if not (always or p.get("tls")):
        return None
    tls = {"enabled": True}
    sni = p.get("sni") or p.get("servername")
    if sni:
        tls["server_name"] = str(sni)
    if p.get("skip-cert-verify"):
        tls["insecure"] = True
    if p.get("alpn"):
        tls["alpn"] = [str(a) for a in _list(p["alpn"])]
    if p.get("client-fingerprint"):
        tls["utls"] = {"enabled": True, "fingerprint": str(p["client-fingerprint"])}
    reality = p.get("reality-opts")
    if reality:
        tls["reality"] = {"enabled": True, "public_key": str(reality.get("public-key", ""))}
        if reality.get("short-id") is not None:
            tls["reality"]["short_id"] = str(reality["short-id"])
        tls.setdefault("utls", {"enabled": True, "fingerprint": "chrome"})
    return tls


def _transport(p, warn):
    network = p.get("network")
    if network in (None, "tcp"):
        return None
    if network == "ws":
        o = p.get("ws-opts") or {}
        t = {"type": "ws", "path": str(o.get("path", "/"))}
        if o.get("headers"):
            t["headers"] = {str(k): str(v) for k, v in o["headers"].items()}
        if o.get("max-early-data"):
            t["max_early_data"] = int(o["max-early-data"])
            t["early_data_header_name"] = str(o.get("early-data-header-name", "Sec-WebSocket-Protocol"))
        return t
    if network == "grpc":
        o = p.get("grpc-opts") or {}
        return {"type": "grpc", "service_name": str(o.get("grpc-service-name", ""))}
    if network == "h2":
        o = p.get("h2-opts") or {}
        t = {"type": "http", "path": str(o.get("path", "/"))}
        if o.get("host"):
            t["host"] = [str(h) for h in _list(o["host"])]
        return t
    if network == "http":
        o = p.get("http-opts") or {}
        t = {"type": "http", "method": str(o.get("method", "GET"))}
        if o.get("path"):
            t["path"] = str(_list(o["path"])[0])
        if o.get("headers"):
            t["headers"] = {str(k): [str(x) for x in _list(v)] for k, v in o["headers"].items()}
        return t
    if network == "httpupgrade":
        o = p.get("http-upgrade-opts") or p.get("ws-opts") or {}
        t = {"type": "httpupgrade", "path": str(o.get("path", "/"))}
        host = (o.get("headers") or {}).get("Host")
        if host:
            t["host"] = str(host)
        return t
    warn(f"proxy {p.get('name')!r}: transport {network!r} is not supported, dropped the proxy")
    raise ValueError("transport")


def _mbps(value):
    if value is None:
        return None
    m = re.match(r"\s*(\d+(?:\.\d+)?)", str(value))
    return int(float(m.group(1))) if m else None


def convert_proxy(p, warn):
    """One Clash proxy → (kind, sing-box object) with kind 'outbound' or 'endpoint'; None if unsupported."""
    name, kind = p.get("name"), p.get("type")
    if not name or not kind:
        warn(f"proxy without name or type skipped: {p!r:.80}")
        return None
    base = {"tag": str(name), "server": str(p.get("server", "")), "server_port": int(p.get("port", 0) or 0)}
    try:
        if kind == "ss":
            o = {"type": "shadowsocks", **base, "method": str(p.get("cipher", "")), "password": str(p.get("password", ""))}
            plugin, opts = p.get("plugin"), p.get("plugin-opts") or {}
            if plugin == "obfs":
                o["plugin"] = "obfs-local"
                o["plugin_opts"] = f"obfs={opts.get('mode', 'http')};obfs-host={opts.get('host', '')}"
            elif plugin == "v2ray-plugin":
                o["plugin"] = "v2ray-plugin"
                parts = [f"mode={opts.get('mode', 'websocket')}"]
                if opts.get("tls"):
                    parts.append("tls")
                if opts.get("host"):
                    parts.append(f"host={opts['host']}")
                if opts.get("path"):
                    parts.append(f"path={opts['path']}")
                o["plugin_opts"] = ";".join(parts)
            elif plugin:
                warn(f"proxy {name!r}: ss plugin {plugin!r} is not supported, dropped the proxy")
                return None
            if p.get("udp-over-tcp"):
                o["udp_over_tcp"] = True
            return "outbound", o
        if kind == "vmess":
            o = {"type": "vmess", **base, "uuid": str(p.get("uuid", "")),
                 "security": str(p.get("cipher", "auto")), "alter_id": int(p.get("alterId", 0) or 0)}
        elif kind == "vless":
            o = {"type": "vless", **base, "uuid": str(p.get("uuid", ""))}
            if p.get("flow"):
                o["flow"] = str(p["flow"])
            if p.get("packet-encoding"):
                o["packet_encoding"] = str(p["packet-encoding"])
        elif kind == "trojan":
            o = {"type": "trojan", **base, "password": str(p.get("password", ""))}
            o["tls"] = _tls(p, always=True)
        elif kind == "hysteria2":
            o = {"type": "hysteria2", **base, "password": str(p.get("password", ""))}
            if p.get("ports"):
                o["server_ports"] = [str(r).replace("-", ":") for r in str(p["ports"]).split(",")]
            if _mbps(p.get("up")):
                o["up_mbps"] = _mbps(p["up"])
            if _mbps(p.get("down")):
                o["down_mbps"] = _mbps(p["down"])
            if p.get("obfs"):
                o["obfs"] = {"type": str(p["obfs"]), "password": str(p.get("obfs-password", ""))}
            o["tls"] = _tls(p, always=True)
            return "outbound", o
        elif kind == "tuic":
            o = {"type": "tuic", **base, "uuid": str(p.get("uuid", "")), "password": str(p.get("password", ""))}
            if p.get("congestion-controller"):
                o["congestion_control"] = str(p["congestion-controller"])
            if p.get("udp-relay-mode"):
                o["udp_relay_mode"] = str(p["udp-relay-mode"])
            if p.get("reduce-rtt"):
                o["zero_rtt_handshake"] = True
            o["tls"] = _tls(p, always=True)
            return "outbound", o
        elif kind in ("socks5", "http"):
            o = {"type": "socks" if kind == "socks5" else "http", **base}
            if kind == "socks5":
                o["version"] = "5"
            if p.get("username"):
                o["username"] = str(p["username"])
                o["password"] = str(p.get("password", ""))
            tls = _tls(p)
            if tls:
                o["tls"] = tls
            return "outbound", o
        elif kind == "snell":
            if int(p.get("version", 1) or 1) != 4:
                warn(f"proxy {name!r}: snell v{p.get('version', 1)} is not supported (sing-box has v4 and v6 only), dropped")
                return None
            o = {"type": "snell", **base, "version": 4, "psk": str(p.get("psk", ""))}
            obfs = p.get("obfs-opts") or {}
            if obfs.get("mode"):
                o["obfs_mode"] = str(obfs["mode"])
                if obfs.get("host"):
                    o["obfs_host"] = str(obfs["host"])
            return "outbound", o
        elif kind == "wireguard":
            address = [a for a in (p.get("ip"), p.get("ipv6")) if a]
            address = [a if "/" in str(a) else f"{a}/{128 if ':' in str(a) else 32}" for a in address]
            peer = {"address": base["server"], "port": base["server_port"],
                    "public_key": str(p.get("public-key", "")),
                    "allowed_ips": [str(a) for a in _list(p.get("allowed-ips"))] or ["0.0.0.0/0", "::/0"]}
            if p.get("pre-shared-key"):
                peer["pre_shared_key"] = str(p["pre-shared-key"])
            if p.get("reserved") is not None:
                reserved = p["reserved"]
                peer["reserved"] = reserved if isinstance(reserved, list) else [int(x) for x in str(reserved).split(",")]
            o = {"type": "wireguard", "tag": str(name), "address": address,
                 "private_key": str(p.get("private-key", "")), "peers": [peer]}
            if p.get("mtu"):
                o["mtu"] = int(p["mtu"])
            return "endpoint", o
        else:
            warn(f"proxy {name!r}: type {kind!r} is not supported, dropped")
            return None
        # vmess / vless / trojan share tls + transport
        if kind != "trojan":
            tls = _tls(p)
            if tls:
                o["tls"] = tls
        transport = _transport(p, warn)
        if transport:
            o["transport"] = transport
        return "outbound", o
    except ValueError:
        return None


def _special_target(name):
    upper = str(name).upper()
    if upper == "DIRECT":
        return "direct"
    if upper in ("REJECT", "REJECT-DROP", "REJECT-TINY", "PASS", "COMPATIBLE"):
        return None
    return name


RULE_FIELDS = {
    "DOMAIN": "domain", "DOMAIN-SUFFIX": "domain_suffix", "DOMAIN-KEYWORD": "domain_keyword",
    "DOMAIN-REGEX": "domain_regex", "IP-CIDR": "ip_cidr", "IP-CIDR6": "ip_cidr",
    "SRC-IP-CIDR": "source_ip_cidr", "DST-PORT": "port", "SRC-PORT": "source_port",
    "PROCESS-NAME": "process_name", "NETWORK": "network",
}


def convert(clash, tailscale=True, hostname="cain", providers=None, warn=None):
    """Clash dict → sing-box dict. `warn(msg)` is called for everything that can't be carried over."""
    warnings = []
    warn = warn or warnings.append
    providers = dict(providers or {})
    if not isinstance(clash, dict):
        raise ConvertError("the YAML top level is not a mapping")

    outbounds, endpoints, tags = [], [], set()
    for p in _list(clash.get("proxies")):
        if not isinstance(p, dict):
            warn(f"proxy entry is not a mapping: {p!r:.60}")
            continue
        converted = convert_proxy(p, warn)
        if not converted:
            continue
        kind, obj = converted
        if obj["tag"] in tags or obj["tag"] == "direct":
            warn(f"duplicate proxy name {obj['tag']!r}, kept the first")
            continue
        tags.add(obj["tag"])
        (endpoints if kind == "endpoint" else outbounds).append(obj)

    group_names = [g.get("name") for g in _list(clash.get("proxy-groups")) if isinstance(g, dict)]
    known = tags | {str(n) for n in group_names if n} | {"direct"}

    groups = []
    for g in _list(clash.get("proxy-groups")):
        if not isinstance(g, dict) or not g.get("name"):
            continue
        name, gtype = str(g["name"]), g.get("type", "select")
        if name in tags:
            warn(f"group {name!r} has the same name as a proxy, skipped the group")
            continue
        for key in ("use", "include-all", "include-all-proxies", "filter"):
            if g.get(key):
                warn(f"group {name!r}: {key!r} (proxy providers / filters) is not converted; list proxies by name")
        members = []
        for m in _list(g.get("proxies")):
            target = _special_target(m)
            if target is None:
                warn(f"group {name!r}: member {m!r} has no sing-box outbound, dropped")
            elif str(target) not in known:
                warn(f"group {name!r}: member {m!r} was not converted, dropped")
            elif target not in members:
                members.append(str(target))
        if not members:
            warn(f"group {name!r} has no usable members, using direct")
            members = ["direct"]
        if gtype == "select":
            groups.append({"type": "selector", "tag": name, "outbounds": members, "default": members[0]})
        elif gtype in ("url-test", "fallback", "load-balance"):
            if gtype != "url-test":
                warn(f"group {name!r}: {gtype} is approximated by urltest")
            o = {"type": "urltest", "tag": name, "outbounds": members}
            if g.get("url"):
                o["url"] = str(g["url"])
            if g.get("interval"):
                o["interval"] = f"{int(g['interval'])}s"
            if g.get("tolerance") is not None:
                o["tolerance"] = int(g["tolerance"])
            groups.append(o)
        else:
            warn(f"group {name!r}: type {gtype!r} is not supported, skipped")
            known.discard(name)

    # Rules
    rule_sets, rules, final = {}, [], None
    # Clash resolves a domain before its first IP rule (unless `no-resolve`); sing-box needs it asked for.
    resolved = False
    provider_defs = clash.get("rule-providers") or {}

    def rule_set_for(tag, url):
        fmt = "binary" if url.split("?")[0].endswith(".srs") else "source"
        rule_sets.setdefault(tag, {"type": "remote", "tag": tag, "format": fmt, "url": url, "update_interval": "1d"})
        return tag

    def target_of(raw):
        upper = str(raw).upper()
        if upper in ("REJECT", "REJECT-TINY"):
            return {"action": "reject"}
        if upper == "REJECT-DROP":
            return {"action": "reject", "method": "drop"}
        t = _special_target(raw)
        if t is None or str(t) not in known:
            return None
        return {"action": "route", "outbound": str(t)}

    for line in _list(clash.get("rules")):
        parts = [x.strip() for x in str(line).split(",")]
        rtype = parts[0].upper()
        if rtype in ("AND", "OR", "NOT", "SUB-RULE"):
            warn(f"rule {line!r}: logical rules ({rtype}) are not converted, skipped")
            continue
        if rtype == "MATCH" and len(parts) >= 2:
            t = target_of(parts[1])
            final = t["outbound"] if t and t["action"] == "route" else final
            if not t:
                warn(f"rule {line!r}: target not converted")
            continue
        if len(parts) < 3:
            warn(f"rule {line!r}: not understood, skipped")
            continue
        value, target = parts[1], target_of(parts[2])
        if not target:
            warn(f"rule {line!r}: target {parts[2]!r} not converted, skipped")
            continue
        if rtype in RULE_FIELDS:
            field = RULE_FIELDS[rtype]
            if field == "process_name":
                warn(f"rule {line!r}: PROCESS-NAME never matches on iOS")
            if field in ("port", "source_port"):
                if not value.isdigit():
                    warn(f"rule {line!r}: port ranges are not converted, skipped")
                    continue
                item = int(value)
            elif field == "network":
                item = value.lower()
            else:
                item = value
            match = (field, item)
        elif rtype in ("GEOIP", "GEOSITE"):
            lower = value.lower()
            if rtype == "GEOIP" and lower in ("lan", "private"):
                match = ("ip_is_private", True)
            else:
                prefix = "geoip" if rtype == "GEOIP" else "geosite"
                url = (GEOIP_URL if rtype == "GEOIP" else GEOSITE_URL).format(lower)
                match = ("rule_set", rule_set_for(f"{prefix}-{lower}", url))
        elif rtype == "RULE-SET":
            definition = provider_defs.get(value) or {}
            url = providers.get(value) or definition.get("url")
            if not url:
                warn(f"rule {line!r}: rule-provider {value!r} has no URL, skipped")
                continue
            if value not in providers and not re.search(r"\.(srs|json)(\?|$)", str(url)):
                warn(f"rule {line!r}: rule-provider {value!r} is in Clash format ({url}); sing-box needs .srs or "
                     f"sing-box JSON. Pass --provider {value}=<sing-box rule-set URL>. Skipped")
                continue
            match = ("rule_set", rule_set_for(str(value), str(url)))
        else:
            warn(f"rule {line!r}: {rtype} is not converted, skipped")
            continue

        field, item = match
        ip_based = field == "ip_cidr" or (rtype == "GEOIP" and field == "rule_set")
        if ip_based and not resolved and "no-resolve" not in [x.lower() for x in parts[3:]]:
            rules.append({"action": "resolve"})
            resolved = True
        prev = rules[-1] if rules else None
        if (prev and field in prev and len(prev) == 1 + len(target) and isinstance(prev[field], list)
                and all(prev.get(k) == v for k, v in target.items())):
            if item not in prev[field]:
                prev[field].append(item)
        else:
            rules.append({field: item if field == "ip_is_private" else [item], **target})

    if final is None:
        final = groups[0]["tag"] if groups else (outbounds[0]["tag"] if outbounds else "direct")
        warn(f"no MATCH rule; final outbound is {final!r}")

    # DNS: domestic resolver for China sites, remote through the final outbound for the rest.
    dns_conf = clash.get("dns") or {}
    if dns_conf.get("enhanced-mode") == "fake-ip":
        warn("dns: fake-ip mode is not converted; the profile resolves real IPs")
    domestic = _dns_server("domestic", _list(dns_conf.get("nameserver"))[:1] or ["223.5.5.5"], warn)
    remote = _dns_server("remote", _list(dns_conf.get("fallback"))[:1] or ["https://1.1.1.1/dns-query"], warn)
    if final != "direct":
        remote["detour"] = final
    servers = [{"type": "local", "tag": "local"}, domestic, remote]
    dns_rules = []
    if "geosite-cn" in rule_sets:
        dns_rules.append({"rule_set": ["geosite-cn"], "server": "domestic"})

    route_rules = [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}]
    if tailscale:
        endpoint = {"type": "tailscale", "tag": "ts-ep", "state_directory": "tailscale",
                    "auth_key": AUTHKEY_PLACEHOLDER, "hostname": hostname, "accept_routes": True}
        if final != "direct":
            endpoint["detour"] = final          # reach the Tailscale control plane through the proxy
        endpoints.append(endpoint)
        servers.append({"type": "tailscale", "tag": "ts-dns", "endpoint": "ts-ep", "accept_default_resolvers": False})
        dns_rules.insert(0, {"domain_suffix": ["ts.net"], "server": "ts-dns"})
        route_rules.append({"ip_cidr": [TAILNET_V4, TAILNET_V6], "action": "route", "outbound": "ts-ep"})
        route_rules.append({"domain_suffix": ["ts.net"], "action": "route", "outbound": "ts-ep"})
    route_rules.append({"ip_is_private": True, "action": "route", "outbound": "direct"})

    config = {
        "log": {"level": "info", "timestamp": True},
        "dns": {"servers": servers, "rules": dns_rules, "final": "remote"},
        "inbounds": [{
            "type": "tun", "tag": "tun-in",
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "auto_route": True, "strict_route": True, "stack": "gvisor",
        }],
        "outbounds": [*groups, *outbounds, {"type": "direct", "tag": "direct"}],
        "route": {
            "rules": route_rules + rules,
            "final": final,
            "auto_detect_interface": True,
            "default_domain_resolver": "local",
        },
        "experimental": {"cache_file": {"enabled": True}},
    }
    if endpoints:
        config["endpoints"] = endpoints
    if rule_sets:
        config["route"]["rule_set"] = list(rule_sets.values())
        # Rule sets download through the proxy (GitHub is often unreachable direct).
        config["http_clients"] = [{"tag": "via-final", "detour": final}]
        config["route"]["default_http_client"] = "via-final"
    return config, warnings


def _dns_server(tag, entries, warn):
    raw = str(entries[0]).strip()
    m = re.match(r"(?:(https|tls|quic|udp|tcp)://)?([^/:\]]+|\[[^\]]+\])(?::(\d+))?(/.*)?$", raw)
    if raw in ("system", "dhcp://system") or raw.startswith("dhcp://") or not m:
        if not m and raw not in ("system",):
            warn(f"dns {tag}: {raw!r} not understood, using the system resolver")
        return {"type": "local", "tag": tag}
    scheme, host, port, path = m.group(1) or "udp", m.group(2).strip("[]"), m.group(3), m.group(4)
    server = {"type": scheme, "tag": tag, "server": host}
    if port:
        server["server_port"] = int(port)
    if scheme == "https" and path and path != "/dns-query":
        server["path"] = path
    if not re.fullmatch(r"[\d.]+|[0-9a-fA-F:]+", host):
        server["domain_resolver"] = "local"
    return server


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="mihomo / Clash YAML config")
    ap.add_argument("-o", "--output", help="write here instead of stdout")
    ap.add_argument("--hostname", default="cain", help="tailnet machine name (default: cain)")
    ap.add_argument("--no-tailscale", action="store_true", help="leave out the Tailscale endpoint")
    ap.add_argument("--provider", action="append", default=[], metavar="NAME=URL",
                    help="sing-box rule-set URL (.srs or .json) for a Clash rule-provider; repeatable")
    ap.add_argument("--fill-authkey-from-env", action="store_true",
                    help="replace ${TS_AUTHKEY} with $TS_AUTHKEY (keep the output out of git)")
    args = ap.parse_args(argv)

    providers = {}
    for item in args.provider:
        name, sep, url = item.partition("=")
        if not sep or not url:
            ap.error(f"--provider wants NAME=URL, got {item!r}")
        providers[name] = url

    try:
        with open(args.input, encoding="utf-8") as f:
            clash = parse_yaml(f.read())
        config, warnings = convert(clash, tailscale=not args.no_tailscale, hostname=args.hostname,
                                   providers=providers)
    except ConvertError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    text = json.dumps(config, indent=2, ensure_ascii=False) + "\n"
    if args.fill_authkey_from_env and not args.no_tailscale:
        key = os.environ.get("TS_AUTHKEY")
        if not key:
            print("error: --fill-authkey-from-env but $TS_AUTHKEY is not set", file=sys.stderr)
            return 1
        text = text.replace(AUTHKEY_PLACEHOLDER, key)
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
