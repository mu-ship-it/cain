"""Tests for tools/clash2singbox.py (stdlib unittest). Run: python3 -m unittest discover -s tests -v

Uses only the synthetic tests/fixtures/clash-sample.yaml. If a sing-box binary is found
($SING_BOX, else build/sing-box), every generated profile is also checked with `sing-box check`.
"""
import io
import ipaddress
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import clash2singbox as c2s  # noqa: E402

FIXTURE = ROOT / "tests" / "fixtures" / "clash-sample.yaml"
SING_BOX = os.environ.get("SING_BOX") or str(ROOT / "build" / "sing-box")
HAS_SING_BOX = os.access(SING_BOX, os.X_OK)


def load_fixture():
    return c2s.parse_yaml(FIXTURE.read_text(encoding="utf-8"))


def by_tag(items):
    return {o["tag"]: o for o in items}


class YAMLTests(unittest.TestCase):
    def test_scalars_and_quotes(self):
        doc = c2s.parse_yaml(
            "a: 1\nb: -2.5\nc: true\nd: null\ne: ~\nf: 'it''s'\ng: \"tab\\t\\u00e9\"\n"
            "h: plain text # comment\ni: \"# not a comment\"\nj: http://x.example/#frag\nk: 0123abcd\n")
        self.assertEqual(doc, {"a": 1, "b": -2.5, "c": True, "d": None, "e": None, "f": "it's", "g": "tab\té",
                               "h": "plain text", "i": "# not a comment", "j": "http://x.example/#frag",
                               "k": "0123abcd"})

    def test_block_and_flow_collections(self):
        doc = c2s.parse_yaml(
            "list:\n- one\n- two\nnested:\n  - name: x\n    opts: {a: 1, b: [p, 'q, r']}\n  - [1, 2]\n"
            "flow: {k: {deep: [a, {z: 0}]}}\nempty:\nmulti: [a,\n  b]\n")
        self.assertEqual(doc["list"], ["one", "two"])
        self.assertEqual(doc["nested"], [{"name": "x", "opts": {"a": 1, "b": ["p", "q, r"]}}, [1, 2]])
        self.assertEqual(doc["flow"], {"k": {"deep": ["a", {"z": 0}]}})
        self.assertIsNone(doc["empty"])
        self.assertEqual(doc["multi"], ["a", "b"])

    def test_anchors_and_merge(self):
        doc = c2s.parse_yaml("base: &b\n  x: 1\n  y: 2\nuse:\n  <<: *b\n  y: 3\nref: *b\n")
        self.assertEqual(doc["use"], {"x": 1, "y": 3})
        self.assertEqual(doc["ref"], {"x": 1, "y": 2})

    def test_block_scalar(self):
        self.assertEqual(c2s.parse_yaml("s: |\n  line one\n  line two\nt: 1\n"),
                         {"s": "line one\nline two", "t": 1})

    def test_errors(self):
        for bad in ("a: *nope\n", "a: 'open\n", "a: 1\n   b: 2\n", "a: [1, 2\n"):
            with self.subTest(bad=bad), self.assertRaises(c2s.YAMLError):
                c2s.parse_yaml(bad)


class ConvertTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config, cls.warnings = c2s.convert(load_fixture())
        cls.out = by_tag(cls.config["outbounds"])
        cls.endpoints = by_tag(cls.config["endpoints"])

    def test_proxies(self):
        ss = self.out["🇭🇰 HK ss"]
        self.assertEqual((ss["type"], ss["server_port"], ss["method"]), ("shadowsocks", 8388, "aes-256-gcm"))
        self.assertEqual(ss["plugin"], "obfs-local")
        self.assertEqual(ss["plugin_opts"], "obfs=http;obfs-host=cdn.example.org")

        vmess = self.out["日本 vmess"]
        self.assertEqual(vmess["transport"], {"type": "ws", "path": "/ray", "headers": {"Host": "jp.example.com"}})
        self.assertEqual(vmess["tls"], {"enabled": True, "server_name": "jp.example.com"})

        vless = self.out["US vless"]
        self.assertEqual(vless["flow"], "xtls-rprx-vision")
        self.assertEqual(vless["tls"]["reality"]["short_id"], "0123abcd")
        self.assertEqual(vless["tls"]["utls"], {"enabled": True, "fingerprint": "chrome"})
        self.assertEqual(vless["transport"], {"type": "grpc", "service_name": "grpcsvc"})

        trojan = self.out["SG trojan"]
        self.assertEqual(trojan["tls"], {"enabled": True, "server_name": "sg.example.com", "insecure": True,
                                         "alpn": ["h2", "http/1.1"]})

        hy2 = self.out["TW hy2"]
        self.assertEqual((hy2["up_mbps"], hy2["down_mbps"]), (50, 200))
        self.assertEqual(hy2["obfs"], {"type": "salamander", "password": "example-obfs"})

        self.assertEqual(self.out["KR tuic"]["congestion_control"], "bbr")
        self.assertEqual(self.out["home socks"]["version"], "5")

        wg = self.endpoints["WG"]
        self.assertEqual(wg["address"], ["10.0.0.2/32"])
        self.assertEqual(wg["peers"][0]["reserved"], [1, 2, 3])
        self.assertEqual(wg["peers"][0]["allowed_ips"], ["0.0.0.0/0", "::/0"])
        self.assertNotIn("WG", self.out)            # wireguard is an endpoint since sing-box 1.11

        self.assertNotIn("old snell", self.out)
        self.assertEqual(self.out["direct"], {"type": "direct", "tag": "direct"})

    def test_groups(self):
        self.assertEqual(self.out["Proxy"], {"type": "selector", "tag": "Proxy", "default": "Auto",
                                             "outbounds": ["Auto", "🇭🇰 HK ss", "日本 vmess", "US vless", "direct"]})
        auto = self.out["Auto"]
        self.assertEqual((auto["type"], auto["interval"], auto["tolerance"]), ("urltest", "300s", 50))
        self.assertEqual(auto["url"], "https://www.gstatic.com/generate_204")   # from the << merge
        self.assertEqual(self.out["Backup"]["outbounds"], ["WG", "home socks"])
        self.assertEqual(self.out["Ads"]["outbounds"], ["direct"])

    def test_rules(self):
        route = self.config["route"]
        rules = route["rules"]
        self.assertEqual(rules[:2], [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}])
        self.assertIn({"domain_suffix": ["ads.example.com"], "action": "reject"}, rules)
        # Consecutive same-type, same-target lines become one rule.
        self.assertIn({"domain_suffix": ["example.org", "example.net"], "action": "route", "outbound": "Proxy"}, rules)
        # resolve goes right before the first IP rule without no-resolve (IP-CIDR6 here).
        no_resolve = rules.index({"ip_cidr": ["198.51.100.0/24"], "action": "route", "outbound": "direct"})
        self.assertEqual(rules[no_resolve + 1], {"action": "resolve"})
        self.assertEqual(rules[no_resolve + 2]["ip_cidr"], ["2001:db8::/32"])
        self.assertEqual(rules.count({"action": "resolve"}), 1)
        self.assertIn({"port": [22], "action": "route", "outbound": "direct"}, rules)
        self.assertIn({"rule_set": ["streaming"], "action": "route", "outbound": "Backup"}, rules)
        self.assertEqual(rules[-1], {"rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "direct"})
        self.assertEqual(route["final"], "Proxy")

        sets = by_tag(route["rule_set"])
        self.assertEqual(sets["streaming"]["format"], "binary")
        self.assertEqual(sets["geoip-cn"]["url"], c2s.GEOIP_URL.format("cn"))
        self.assertNotIn("clash-list", sets)        # Clash-format provider: skipped with a warning
        self.assertEqual(self.config["http_clients"], [{"tag": "via-final", "detour": "Proxy"}])
        self.assertEqual(route["default_http_client"], "via-final")

    def test_dns_and_tailscale(self):
        dns = self.config["dns"]
        servers = by_tag(dns["servers"])
        self.assertEqual(servers["domestic"], {"type": "https", "tag": "domestic", "server": "dns.example.net",
                                               "domain_resolver": "local"})
        self.assertEqual(servers["remote"], {"type": "tls", "tag": "remote", "server": "192.0.2.53", "detour": "Proxy"})
        self.assertEqual(dns["rules"][0], {"domain_suffix": ["ts.net"], "server": "ts-dns"})
        self.assertIn({"rule_set": ["geosite-cn"], "server": "domestic"}, dns["rules"])

        ts = self.endpoints["ts-ep"]
        self.assertEqual(ts["auth_key"], "${TS_AUTHKEY}")
        self.assertEqual((ts["hostname"], ts["detour"]), ("cain", "Proxy"))
        self.assertIn({"ip_cidr": [c2s.TAILNET_V4, c2s.TAILNET_V6], "action": "route", "outbound": "ts-ep"},
                      self.config["route"]["rules"])

    def test_warnings(self):
        text = "\n".join(self.warnings)
        for expected in ("snell v1", "fallback is approximated", "'REJECT' has no sing-box outbound",
                         "Clash format", "logical rules (AND)", "fake-ip"):
            self.assertIn(expected, text)

    def test_options(self):
        config, _ = c2s.convert(load_fixture(), tailscale=False,
                                providers={"clash-list": "https://rules.example.com/clash-list.json"})
        self.assertNotIn("ts-ep", by_tag(config["endpoints"]))
        self.assertNotIn("ts-dns", by_tag(config["dns"]["servers"]))
        self.assertEqual(by_tag(config["route"]["rule_set"])["clash-list"]["format"], "source")

        minimal, warnings = c2s.convert({"proxies": [{"name": "a", "type": "socks5", "server": "192.0.2.9", "port": 1}]})
        self.assertEqual(minimal["route"]["final"], "a")
        self.assertNotIn("rule_set", minimal["route"])
        self.assertIn("no MATCH rule", warnings[-1])
        with self.assertRaises(c2s.ConvertError):
            c2s.convert(["not", "a", "mapping"])

    def test_references_resolve(self):
        """`sing-box check` validates the schema but not references; check those here."""
        for config in (self.config, c2s.convert(load_fixture(), tailscale=False)[0]):
            outs = {o["tag"] for o in config["outbounds"]} | {e["tag"] for e in config.get("endpoints", [])}
            servers = {s["tag"] for s in config["dns"]["servers"]}
            sets = {r["tag"] for r in config["route"].get("rule_set", [])}
            clients = {c["tag"] for c in config.get("http_clients", [])}
            refs = [m for o in config["outbounds"] for m in o.get("outbounds", [])]
            refs += [r["outbound"] for r in config["route"]["rules"] if "outbound" in r]
            refs += [config["route"]["final"]]
            refs += [x["detour"] for x in config["dns"]["servers"] + config.get("endpoints", []) + config.get("http_clients", [])
                     if "detour" in x]
            for ref in refs:
                self.assertIn(ref, outs)
            for rule in config["dns"]["rules"]:
                self.assertIn(rule["server"], servers)
                for tag in rule.get("rule_set", []):
                    self.assertIn(tag, sets)
            for server in config["dns"]["servers"]:
                if "domain_resolver" in server:
                    self.assertIn(server["domain_resolver"], servers)
            self.assertIn(config["dns"]["final"], servers)
            self.assertIn(config["route"]["default_domain_resolver"], servers)
            for rule in config["route"]["rules"]:
                for tag in rule.get("rule_set", []):
                    self.assertIn(tag, sets)
            if clients:
                self.assertIn(config["route"]["default_http_client"], clients)

    def test_fixture_is_synthetic(self):
        """Guard: the sample must only ever name reserved example domains and documentation IPs."""
        docs = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32")]
        hosts = [o.get("server") for o in self.config["outbounds"] if o.get("server")]
        hosts += [p["address"] for e in self.config["endpoints"] for p in e.get("peers", [])]
        for host in hosts:
            with self.subTest(host=host):
                try:
                    self.assertTrue(any(ipaddress.ip_address(host) in n for n in docs))
                except ValueError:
                    self.assertRegex(host, r"(^|\.)example\.(com|org|net)$")


class CLITests(unittest.TestCase):
    def run_main(self, *args, env=None):
        out, err = io.StringIO(), io.StringIO()
        old = dict(os.environ)
        os.environ.pop("TS_AUTHKEY", None)
        os.environ.update(env or {})
        try:
            with redirect_stdout(out), redirect_stderr(err):
                code = c2s.main([str(FIXTURE), *args])
        finally:
            os.environ.clear()
            os.environ.update(old)
        return code, out.getvalue(), err.getvalue()

    def test_stdout_and_warnings(self):
        code, out, err = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("${TS_AUTHKEY}", out)
        self.assertIn("🇭🇰 HK ss", out)                 # not \u-escaped
        self.assertIn("warning: proxy 'old snell'", err)

    def test_fill_authkey(self):
        code, _, err = self.run_main("--fill-authkey-from-env")
        self.assertEqual(code, 1)
        self.assertIn("TS_AUTHKEY is not set", err)
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "p.json"
            code, _, _ = self.run_main("--fill-authkey-from-env", "-o", str(target),
                                       env={"TS_AUTHKEY": "tskey-auth-EXAMPLE"})
            self.assertEqual(code, 0)
            self.assertEqual(by_tag(json.loads(target.read_text())["endpoints"])["ts-ep"]["auth_key"],
                             "tskey-auth-EXAMPLE")

    def test_bad_provider_flag(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            c2s.main([str(FIXTURE), "--provider", "nourl"])


@unittest.skipUnless(HAS_SING_BOX, "no sing-box binary (set $SING_BOX or build build/sing-box)")
class SingBoxCheckTests(unittest.TestCase):
    def check(self, config):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(config, f)
        try:
            proc = subprocess.run([SING_BOX, "check", "-c", f.name], capture_output=True, text=True, timeout=60)
        finally:
            os.unlink(f.name)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_full_profile_passes_sing_box_check(self):
        self.check(c2s.convert(load_fixture())[0])

    def test_variants_pass_sing_box_check(self):
        self.check(c2s.convert(load_fixture(), tailscale=False)[0])
        self.check(c2s.convert({"proxies": [{"name": "a", "type": "socks5", "server": "192.0.2.9", "port": 1}],
                                "rules": ["MATCH,DIRECT"]})[0])


if __name__ == "__main__":
    unittest.main()
