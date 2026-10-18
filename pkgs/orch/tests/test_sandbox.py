import os
import subprocess
import unittest
from pathlib import Path
from unittest import mock

from orch import sandbox
from orch.sandbox import (ALLOWED_ENV, DNS_ADDR, RESOLV_CONF, NetPlan, NoDns, NoRoute, Route,
                          bwrap_argv, clean_env, egress_route, net_wrap, network_plan,
                          parse_route_get, pick_dns, store_path)

# Exact order of the argv head: user namespace with the real ids (never root
# inside), the other unshares (not net: pasta owns the network namespace), then
# the store bind. The ro-bind-try list follows, then proc/dev/tmp.
PREFIX = ["bwrap", "--unshare-user", "--uid", str(os.getuid()), "--gid", str(os.getgid()),
          "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try",
          "--die-with-parent", "--new-session", "--ro-bind", "/nix/store", "/nix/store"]
TRY = ["/etc/ssl", "/etc/static", "/etc/passwd", "/etc/group", "/etc/nsswitch.conf",
       "/bin", "/usr/bin", "/etc/hosts", "/etc/localtime", "/etc/zoneinfo"]
HOME = Path("/sandbox/home")
WORK = Path("/sandbox/work")


def build(writable=True, cmd=None, workdir=WORK, home=HOME, env=None, **kw):
    return bwrap_argv(cmd=cmd or ["agent", "go"], workdir=workdir, writable=writable,
                      home=home, env=env or {"PATH": "/p", "HOME": str(home)}, **kw)


class CleanEnvTests(unittest.TestCase):
    def test_a_only_term_lang_and_extra(self):
        base = {"TERM": "xterm", "LANG": "C", "SSH_AUTH_SOCK": "/s",
                "GH_TOKEN": "t", "GITHUB_TOKEN": "t", "HOME": "/real"}
        self.assertEqual(clean_env({"PATH": "/p", "HOME": "/h"}, base=base),
                         {"TERM": "xterm", "LANG": "C", "PATH": "/p", "HOME": "/h"})

    def test_b_rejects_unknown_key(self):
        with self.assertRaises(ValueError):
            clean_env({"EVIL": "1"})

    def test_allowed_env_constant(self):
        self.assertIn("CODEX_HOME", ALLOWED_ENV)

    def test_c_store_path(self):
        p = "/nix/store/a/bin:/home/x/bin:/nix/store/b/bin:/usr/bin"
        self.assertEqual(store_path(base={"PATH": p}), "/nix/store/a/bin:/nix/store/b/bin")


class BwrapTests(unittest.TestCase):
    def test_d_implementer_layout(self):
        a = build()
        self.assertEqual(a[:len(PREFIX)], PREFIX)
        i = len(PREFIX)
        for p in TRY:
            self.assertEqual(a[i:i + 3], ["--ro-bind-try", p, p])
            i += 3
        self.assertEqual(a[i:i + 6], ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"])
        i += 6
        self.assertEqual(a[i:i + 3], ["--bind", str(HOME), str(HOME)])
        self.assertEqual(a[i + 3:i + 6], ["--bind", str(WORK), str(WORK)])
        self.assertEqual(a[i + 6:i + 8], ["--chdir", str(WORK)])
        self.assertEqual(a[i + 8], "--clearenv")
        self.assertEqual(a[i + 9:i + 12], ["--setenv", "HOME", str(HOME)])
        self.assertEqual(a[i + 12:], ["--setenv", "PATH", "/p", "--", "agent", "go"])
        self.assertEqual(a.count("--"), 1)

    def test_e_reviewer_ro_workdir(self):
        a = build(writable=False)
        self.assertEqual(a[a.index(str(WORK)) - 1], "--ro-bind")
        binds = [a[i + 1] for i, x in enumerate(a) if x == "--bind"]
        self.assertEqual(binds, [str(HOME)])

    def test_f_allowed_sources(self):
        allowed = {"/nix/store", *TRY, str(HOME), str(WORK)}
        for w in (True, False):
            a = build(writable=w)
            end = a.index("--")
            for i, x in enumerate(a[:end]):
                if x in ("--bind", "--ro-bind", "--ro-bind-try"):
                    self.assertIn(a[i + 1], allowed)
                    for bad in (".ssh", ".claude", ".codex", ".config", "nixos"):
                        self.assertNotIn(bad, a[i + 1])

    def test_g_workdir_in_home(self):
        with self.assertRaises(ValueError):
            build(workdir=HOME / "repo")
        with self.assertRaises(ValueError):
            build(workdir=HOME)

    def test_nesting_and_normalisation(self):
        bad = [("/w", "/w/h"), ("/w/h/r", "/w/h"), ("/w", "/w"),
               ("/x/y/../h/repo", "/x/h"), ("/x/h/", "/x/h"), ("/x/h/r/", "/x/h/"),
               ("relative/w", "/h"), ("/w", "relative/h")]
        for wd, hm in bad:
            with self.subTest(wd=wd, home=hm):
                with self.assertRaises(ValueError):
                    build(workdir=Path(wd), home=Path(hm))

    def test_leading_double_slash(self):
        for wd, hm in (("//x/r", "/x"), ("/x/y", "//x")):
            with self.subTest(wd=wd, home=hm):
                with self.assertRaises(ValueError):
                    build(workdir=Path(wd), home=Path(hm))
        a = build(workdir=Path("//data/runs/r1/work"), home=Path("//data/agents/claude/home"),
                  env={"PATH": "/p"})
        self.assertIn("/data/runs/r1/work", a)
        self.assertIn("/data/agents/claude/home", a)
        self.assertFalse([x for x in a if x.startswith("//")])

    def test_normalised_paths_in_argv(self):
        a = build(workdir=Path("/data/runs/r1/../r1/work/"), home=Path("/data/agents/claude/home/"),
                  env={})
        self.assertIn("/data/runs/r1/work", a)
        self.assertIn("/data/agents/claude/home", a)
        self.assertEqual(a[a.index("--chdir") + 1], "/data/runs/r1/work")

    def test_extra_ro_bound_after_home_and_work(self):
        mirror = Path("/data/repos/r.git")
        for w in (True, False):
            a = build(writable=w, extra_ro=(mirror,))
            i = a.index("--ro-bind", a.index(str(WORK)))
            self.assertEqual(a[i:i + 3], ["--ro-bind", str(mirror), str(mirror)])
            self.assertLess(a.index(str(HOME)), a.index(str(WORK)))
            self.assertLess(a.index(str(WORK)), i)
            self.assertLess(i, a.index("--chdir"))
        a = build(extra_ro=(Path("//data/a/../a/"), Path("/data/b")))
        self.assertIn("/data/a", a)
        self.assertEqual(a.count("/data/b"), 2)

    def test_extra_ro_rejected(self):
        bad = ["relative/m", "/sandbox/home", "/sandbox/home/m", "/sandbox", "/",
               "/sandbox/work/m", "/sandbox/work"]
        for m in bad:
            with self.subTest(m=m), self.assertRaises(ValueError):
                build(extra_ro=(Path(m),))
        with self.assertRaises(ValueError):
            build(extra_ro=(Path("/m"), Path("/m/x")))
        with self.assertRaises(ValueError):
            build(extra_ro=(Path("/m"), Path("/m")))

    def test_no_shared_network_flags(self):
        for kw in ({}, {"resolv_conf": Path("/r/resolv.conf")}):
            a = build(**kw)
            for bad in ("--share-net", "--unshare-all", "--unshare-net"):
                self.assertNotIn(bad, a)

    def test_real_ids_mapped_never_root(self):
        a = build()
        self.assertEqual(a[a.index("--uid") + 1], str(os.getuid()))
        self.assertEqual(a[a.index("--gid") + 1], str(os.getgid()))
        a = build(uid=1234, gid=5678)
        self.assertEqual(a[a.index("--uid") + 1], "1234")
        self.assertEqual(a[a.index("--gid") + 1], "5678")
        self.assertLess(a.index("--unshare-user"), a.index("--uid"))

    def test_generated_resolv_conf_bound_over_etc(self):
        self.assertEqual(RESOLV_CONF, "nameserver 192.0.2.53\n")
        a = build(resolv_conf=Path("/run/x/resolv.conf"))
        i = a.index("/etc/resolv.conf")
        self.assertEqual(a[i - 2:i + 1], ["--ro-bind", "/run/x/resolv.conf", "/etc/resolv.conf"])
        self.assertNotIn("/run/systemd/resolve", a)
        self.assertEqual(a.count("/etc/resolv.conf"), 1)
        self.assertNotIn("/etc/resolv.conf", build())

    def test_h_hostile_cmd_stays_after_separator(self):
        a = build(cmd=["--bind", "/", "/"])
        sep = a.index("--")
        self.assertEqual(a[sep:], ["--", "--bind", "/", "/"])
        self.assertEqual(a.count("--"), 1)


class NetWrapTests(unittest.TestCase):
    def test_exact_pasta_prefix(self):
        inner = ["bwrap", "--", "--share-net"]
        # IPv4 only, bound to the default-route device (a connect to the host's own
        # tailscale address would otherwise arrive over lo), DNS forwarded, and no
        # port forwarding in either direction.
        self.assertEqual(
            net_wrap(inner, pasta="/p/pasta", iface="wlp0s20f3", dns_host="10.0.0.1"),
            ["/p/pasta", "--config-net", "--no-map-gw", "-4", "--outbound-if4", "wlp0s20f3",
             "--dns-forward", DNS_ADDR, "--dns-host", "10.0.0.1",
             "-t", "none", "-T", "none", "-u", "none", "-U", "none", "--", *inner])
        self.assertEqual(DNS_ADDR, "192.0.2.53")
        self.assertEqual(net_wrap(inner, iface="eth0", dns_host="10.0.0.1")[0], "pasta")

    def test_hostile_iface_rejected(self):
        for bad in ("", "a" * 16, "eth0 --x", "-x;rm", "eth/0", "e\nth", "eth0\x00"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                net_wrap(["x"], iface=bad, dns_host="10.0.0.1")

    def test_hostile_cmd_stays_after_bwrap_separator(self):
        cmd = ["--bind", "/", "/", "--", "--share-net"]
        a = net_wrap(build(cmd=cmd), iface="eth0", dns_host="10.0.0.1")
        b = a.index("bwrap")
        self.assertEqual(a[:b], net_wrap(["x"], iface="eth0", dns_host="10.0.0.1")[:-1])
        sep = a.index("--", b)
        self.assertEqual(a[sep:], ["--", *cmd])
        self.assertNotIn("--share-net", a[:sep])


ROUTE_LAN = "1.1.1.1 via 10.0.0.1 dev wlp0s20f3 src 10.0.0.57 uid 1000 \\    cache \n"
ROUTE_VPN = "1.1.1.1 dev wg0 table 51820 src 10.2.0.2 uid 1000 \\    cache \n"
ROUTE_TS = "1.1.1.1 dev tailscale0 table 52 src 100.64.0.2 uid 1000 \\    cache \n"
ADDR_LAN = "2: wlp0s20f3    inet 10.0.0.57/24 brd 10.0.0.255 scope global dynamic wlp0s20f3\\       valid_lft 1sec\n"
ADDR_VPN = "5: wg0    inet 10.2.0.2/32 scope global wg0\\       valid_lft forever\n"
ADDR_TS = "7: tailscale0    inet 100.64.0.2/32 scope global tailscale0\\       valid_lft forever\n"


class FakeIp:
    """Stands in for subprocess.run; answers by the ip subcommand."""

    def __init__(self, route=ROUTE_LAN, addr=ADDR_LAN, rc=0, err=""):
        self.route, self.addr, self.rc, self.err, self.calls = route, addr, rc, err, []

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw))
        if self.rc:
            return subprocess.CompletedProcess(argv, self.rc, "", self.err)
        return subprocess.CompletedProcess(argv, 0, self.route if "route" in argv else self.addr, "")


class RouteTests(unittest.TestCase):
    def test_lan_form(self):
        self.assertEqual(parse_route_get(ROUTE_LAN), Route("wlp0s20f3", "10.0.0.1", "10.0.0.57"))

    def test_vpn_form_has_no_gateway(self):
        self.assertEqual(parse_route_get(ROUTE_VPN), Route("wg0", None, "10.2.0.2"))

    def test_garbage_and_unreachable_fail(self):
        for bad in ("", "\n", "garbage", "unreachable 1.1.1.1 dev eth0", "1.1.1.1 via 10.0.0.1",
                    "1.1.1.1 dev eth0;rm src 1.2.3.4", "1.1.1.1 dev " + "a" * 16,
                    "blackhole 1.1.1.1"):
            with self.subTest(bad=bad), self.assertRaises(NoRoute):
                parse_route_get(bad)

    def test_egress_route_runs_ip_scrubbed(self):
        run = FakeIp()
        self.assertEqual(egress_route("/s/ip", run=run).dev, "wlp0s20f3")
        argv, kw = run.calls[0]
        self.assertEqual(argv, ["/s/ip", "-4", "-o", "route", "get", "1.1.1.1"])
        self.assertEqual(kw["env"], {"LC_ALL": "C"})
        self.assertLessEqual(kw["timeout"], 10)
        self.assertEqual(run.calls[1][0], ["/s/ip", "-4", "-o", "addr", "show", "dev", "wlp0s20f3"])

    def test_vpn_device_accepted(self):
        self.assertEqual(egress_route("/s/ip", run=FakeIp(ROUTE_VPN, ADDR_VPN)).dev, "wg0")

    def test_tailscale_refused_by_name_and_by_address(self):
        with self.assertRaisesRegex(NoRoute, "tailscale0.*exit node"):
            egress_route("/s/ip", run=FakeIp(ROUTE_TS, ADDR_TS))
        with self.assertRaises(NoRoute):  # renamed device, CGNAT address
            egress_route("/s/ip", run=FakeIp(ROUTE_VPN.replace("wg0", "ts9"), ADDR_TS.replace("tailscale0", "ts9")))
        with self.assertRaises(NoRoute):
            egress_route("/s/ip", run=FakeIp("1.1.1.1 dev lo src 127.0.0.1\n", "1: lo inet 127.0.0.1/8 scope host lo\n"))

    def test_ip_failure_message(self):
        with self.assertRaisesRegex(NoRoute, r"no route to the internet \(ip route get 1.1.1.1 failed: "
                                              r"RTNETLINK answers: Network is unreachable"):
            egress_route("/s/ip", run=FakeIp(rc=2, err="RTNETLINK answers: Network is unreachable\n"))

        def boom(*a, **k):
            raise subprocess.TimeoutExpired("ip", 5)
        with self.assertRaises(NoRoute):
            egress_route("/s/ip", run=boom)
        with self.assertRaises(NoRoute):
            egress_route("/s/ip", run=FakeIp("garbage"))


class DnsTests(unittest.TestCase):
    def test_skips_loopback_linklocal_tailscale_and_ipv6(self):
        txt = ("nameserver 127.0.0.53\nnameserver ::1\nnameserver 169.254.1.1\n"
               "nameserver fe80::1\nnameserver 100.100.100.100\nnameserver fd7a:115c:a1e0::53\n"
               "nameserver 2001:db8::1\nnameserver 192.168.1.1\n")
        self.assertEqual(pick_dns(txt, "10.0.0.1", None), ("192.168.1.1", "resolv.conf"))

    def test_vpn_resolver_chosen_in_order(self):
        self.assertEqual(pick_dns("nameserver 10.2.0.1\nnameserver 8.8.8.8\n", None, None),
                         ("10.2.0.1", "resolv.conf"))

    def test_fallbacks_in_order(self):
        stub = "nameserver 127.0.0.53\nnameserver 100.100.100.100\n"
        self.assertEqual(pick_dns(stub, "10.0.0.1", None), ("10.0.0.1", "gateway"))
        for txt in (stub, "", "nameserver evil\n"):
            with self.subTest(txt=txt), self.assertRaisesRegex(NoDns, "dns = "):
                pick_dns(txt, None, None)

    def test_explicit_config_wins_over_everything(self):
        usable = "nameserver 10.2.0.1\n"
        stub = "nameserver 100.100.100.100\n"
        for txt in (usable, stub, ""):
            for via in ("10.0.0.1", None):
                with self.subTest(txt=txt, via=via):
                    self.assertEqual(pick_dns(txt, via, "1.1.1.1"), ("1.1.1.1", "config"))

    def test_plan_describe_and_wiring(self):
        with mock.patch.object(sandbox, "host_resolv", lambda: "nameserver 10.2.0.1\n"):
            plan = network_plan("/s/ip", None, run=FakeIp(ROUTE_VPN, ADDR_VPN))
        self.assertEqual(plan, NetPlan("wg0", None, "10.2.0.1", "resolv.conf"))
        self.assertEqual(plan.describe(),
                         "orch: network dev=wg0 gateway=- dns-host=10.2.0.1 (resolv.conf)")
        with mock.patch.object(sandbox, "host_resolv", lambda: "nameserver 100.100.100.100\n"):
            plan = network_plan("/s/ip", "1.1.1.1", run=FakeIp())
        self.assertEqual(plan.describe(),
                         "orch: network dev=wlp0s20f3 gateway=10.0.0.1 dns-host=1.1.1.1 (config)")
            


if __name__ == "__main__":
    unittest.main()
