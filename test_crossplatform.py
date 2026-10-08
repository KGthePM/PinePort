#!/usr/bin/env python3
"""Cross-platform logic tests for PinePort — runs on any OS (Linux CI, dev box).

Mocks PowerShell + psutil responses and exercises the Windows code paths
(win_listeners, win_gather, win_kill_pid, win_sys_stats) plus the shared
platform/config helpers. Real-Windows behavior is covered separately by
test_windows.py; Linux behavior by test_easywins.py / test_addon_path.py.

Run: python3 test_crossplatform.py
"""
import importlib.machinery, importlib.util, json, os, sys, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "pineports")

loader = importlib.machinery.SourceFileLoader("pineports_mod", SCRIPT)
spec = importlib.util.spec_from_loader("pineports_mod", loader)
pp = importlib.util.module_from_spec(spec)
loader.exec_module(pp)


class WinListeners(unittest.TestCase):
    def test_parses_listener_rows(self):
        rows = [
            {"OwningProcess": 4242, "LocalPort": 6310, "LocalAddress": "0.0.0.0"},
            # "::" = all interfaces -> externally reachable, same as Linux "*:"
            {"OwningProcess": 800, "LocalPort": 5357, "LocalAddress": "::"},
        ]
        with mock.patch.object(pp, "_ps_json", return_value=rows):
            got = pp.win_listeners()
        self.assertEqual(sorted(got), [(800, 5357, True), (4242, 6310, True)])

    def test_loopback_not_external(self):
        rows = [{"OwningProcess": 99, "LocalPort": 8101, "LocalAddress": "127.0.0.1"}]
        with mock.patch.object(pp, "_ps_json", return_value=rows):
            got = pp.win_listeners()
        self.assertEqual(got, [(99, 8101, False)])

    def test_single_result_dict_normalized(self):
        # ConvertTo-Json emits a bare object for one row, not a list
        row = {"OwningProcess": 7, "LocalPort": 80, "LocalAddress": "192.168.1.5"}
        with mock.patch.object(pp, "_ps_json", return_value=[row]):
            got = pp.win_listeners()
        self.assertEqual(got, [(7, 80, True)])

    def test_garbage_rows_skipped(self):
        rows = [
            {"OwningProcess": "x", "LocalPort": 80, "LocalAddress": "0.0.0.0"},
            {"OwningProcess": 0, "LocalPort": 81, "LocalAddress": "0.0.0.0"},
            {"OwningProcess": 5, "LocalPort": "bad", "LocalAddress": "0.0.0.0"},
            {"OwningProcess": 12, "LocalPort": 443, "LocalAddress": "0.0.0.0"},
        ]
        with mock.patch.object(pp, "_ps_json", return_value=rows):
            got = pp.win_listeners()
        self.assertEqual(got, [(12, 443, True)])

    def test_psutil_missing_returns_empty(self):
        with mock.patch.object(pp, "_ps_json", return_value=None):
            self.assertEqual(pp.win_listeners(), [])


class WinGather(unittest.TestCase):
    def _run(self, listeners, procs, labels=None):
        with mock.patch.object(pp, "win_listeners", return_value=listeners), \
             mock.patch.object(pp, "win_proc",
                               side_effect=lambda pid: procs.get(pid, ("", None, ""))), \
             mock.patch.object(pp, "load_labels", return_value=labels or {}), \
             mock.patch.object(pp, "badge_ports",
                               side_effect=lambda ports, labels: []):
            return pp.win_gather()

    def test_row_schema_and_grouping(self):
        rows = self._run(
            [(4242, 6310, True), (4242, 8797, False), (800, 5357, False)],
            {4242: ("python.exe", 120.5, "python pineports"), 800: ("svchost.exe", 40.0, "")})
        self.assertEqual(len(rows), 2)
        py = next(r for r in rows if r["pid"] == 4242)
        self.assertEqual(py["name"], "python.exe")
        self.assertEqual(py["ports"], [6310, 8797])
        self.assertEqual(py["links"], [6310])
        self.assertEqual(py["kind"], "user")
        self.assertEqual(py["rss"], 120.5)
        self.assertEqual(py["cmd"], "python pineports")
        self.assertEqual(py["new"], [])
        self.assertIn("pid", py)

    def test_docker_process_flagged(self):
        rows = self._run(
            [(900, 13378, True)],
            {900: ("com.docker.backend.exe", 300.0, "")})
        self.assertEqual(rows[0]["kind"], "docker")

    def test_unknown_pid_fallback_name(self):
        rows = self._run([(31337, 9000, False)], {})
        self.assertEqual(rows[0]["name"], "pid 31337")
        self.assertIsNone(rows[0]["rss"])

    def test_label_overrides_name(self):
        rows = self._run([(4242, 6310, False)],
                         {4242: ("python.exe", 10.0, "")},
                         labels={6310: "PinePort UI"})
        self.assertEqual(rows[0]["name"], "PinePort UI")

    def test_sorted_by_rss_desc(self):
        rows = self._run(
            [(1, 100, False), (2, 200, False)],
            {1: ("a.exe", 10.0, ""), 2: ("b.exe", 500.0, "")})
        self.assertEqual([r["pid"] for r in rows], [2, 1])


class WinKill(unittest.TestCase):
    def test_terminate_success(self):
        fake = mock.MagicMock()
        fake.name.return_value = "node.exe"
        fake.wait.return_value = 0
        with mock.patch.object(pp, "_psutil") as ps:
            ps.Process.return_value = fake
            ps.NoSuchProcess = type("NoSuchProcess", (Exception,), {})
            ps.AccessDenied = type("AccessDenied", (Exception,), {})
            msg = pp.win_kill_pid(4242, 3000)
        self.assertEqual(msg, "stopped node.exe (pid 4242) on :3000")
        fake.terminate.assert_called_once()
        fake.kill.assert_not_called()

    def test_escalates_to_kill(self):
        fake = mock.MagicMock()
        fake.name.return_value = "node.exe"
        fake.wait.side_effect = [Exception("timeout"), 0]
        with mock.patch.object(pp, "_psutil") as ps:
            ps.Process.return_value = fake
            ps.NoSuchProcess = type("NoSuchProcess", (Exception,), {})
            ps.AccessDenied = type("AccessDenied", (Exception,), {})
            msg = pp.win_kill_pid(4242, 3000)
        self.assertIn("stopped node.exe", msg)
        fake.kill.assert_called_once()

    def test_access_denied_honest_message(self):
        fake = mock.MagicMock()
        fake.name.return_value = "system.exe"
        with mock.patch.object(pp, "_psutil") as ps:
            AD = type("AccessDenied", (Exception,), {})
            fake.terminate.side_effect = AD()
            ps.Process.return_value = fake
            ps.NoSuchProcess = type("NoSuchProcess", (Exception,), {})
            ps.AccessDenied = AD
            msg = pp.win_kill_pid(4, 445)
        self.assertIn("elevated", msg)
        self.assertIn("no permission", msg)

    def test_no_such_process(self):
        with mock.patch.object(pp, "_psutil") as ps:
            ns = type("NoSuchProcess", (Exception,), {})
            ps.Process.side_effect = ns("gone")
            ps.NoSuchProcess = ns
            ps.AccessDenied = type("AccessDenied", (Exception,), {})
            msg = pp.win_kill_pid(9999, 80)
        self.assertIn("already gone", msg)

    def test_no_psutil(self):
        with mock.patch.object(pp, "_psutil", None):
            msg = pp.win_kill_pid(5, 80)
        self.assertIn("pip install psutil", msg)

    def test_win_kill_port_finds_listener(self):
        with mock.patch.object(pp, "win_listeners",
                               return_value=[(4242, 6310, True)]), \
             mock.patch.object(pp, "win_kill_pid",
                               return_value="stopped x (pid 4242) on :6310") as kp, \
             mock.patch.object(pp, "docker_container_for_port", return_value=None):
            msg = pp.win_kill_port("6310")
        self.assertEqual(msg, "stopped x (pid 4242) on :6310")
        kp.assert_called_once_with(4242, 6310)

    def test_win_kill_port_nothing_there(self):
        with mock.patch.object(pp, "win_listeners", return_value=[]), \
             mock.patch.object(pp, "docker_container_for_port", return_value=None):
            msg = pp.win_kill_port(1234)
        self.assertEqual(msg, "nothing listening on :1234")

    def test_win_kill_port_docker_first(self):
        with mock.patch.object(pp, "docker_container_for_port", return_value="abc123"), \
             mock.patch.object(pp.subprocess, "run") as run, \
             mock.patch.object(pp, "win_listeners") as wl:
            run.return_value = mock.MagicMock(returncode=0, stdout="pine_container", stderr="")
            msg = pp.win_kill_port(5432)
        self.assertIn("docker container pine_container", msg)
        wl.assert_not_called()


class WinStats(unittest.TestCase):
    def test_shape_with_psutil(self):
        t = mock.MagicMock(idle=500.0, user=100.0, system=50.0)
        t.__iter__ = lambda s: iter([100.0, 50.0, 500.0])
        vm = mock.MagicMock(percent=55.5, used=8 * 2**30, total=16 * 2**30)
        du = mock.MagicMock(percent=70.2, free=100 * 2**30)
        with mock.patch.object(pp, "_psutil") as ps, \
             mock.patch.object(pp, "_last_win_cpu", None):
            ps.cpu_times.return_value = t
            ps.virtual_memory.return_value = vm
            ps.disk_usage.return_value = du
            ps.boot_time.return_value = 0
            st = pp.win_sys_stats()
        for k in ("ram_pct", "ram_used", "ram_total", "cpu_pct", "disk_pct",
                  "disk_free", "uptime", "load1"):
            self.assertIn(k, st)
        self.assertEqual(st["ram_pct"], 55.5)
        self.assertEqual(st["disk_pct"], 70.2)
        self.assertEqual(st["load1"], 0.0)

    def test_shape_without_psutil(self):
        with mock.patch.object(pp, "_psutil", None):
            st = pp.win_sys_stats()
        self.assertEqual(st["uptime"], "-")
        self.assertEqual(st["load1"], 0.0)


class PlatformConfig(unittest.TestCase):
    def test_linux_config_path(self):
        with mock.patch.object(pp, "IS_WIN", False):
            p = pp.CONFIG_PATH("pineports-pin")
        self.assertTrue(p.endswith(os.path.join(".config", "pineports-pin")))

    def test_windows_config_path(self):
        with mock.patch.object(pp, "IS_WIN", True), \
             mock.patch.dict(os.environ, {"APPDATA": tempfile.gettempdir()}):
            p = pp.CONFIG_PATH("pineports-pin")
        self.assertEqual(p, os.path.join(tempfile.gettempdir(), "pineports",
                                         "pineports-pin"))
        self.assertTrue(os.path.isdir(os.path.dirname(p)))

    def test_docker_constant(self):
        # this box is Linux -> absolute path preserved for the sudoers rule
        self.assertEqual(pp.DOCKER, "/usr/bin/docker")

    def test_dispatch_is_linux_impl_here(self):
        self.assertIs(pp.gather, pp.linux_gather)
        self.assertIs(pp.sys_stats, pp.linux_sys_stats)
        self.assertIs(pp.kill_port, pp.linux_kill_port)


if __name__ == "__main__":
    unittest.main(verbosity=2)
