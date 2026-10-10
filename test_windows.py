#!/usr/bin/env python3
"""Real-Windows smoke test for PinePort. Skips on other OSes.

Run on a Windows box with:  python test_windows.py
Requires psutil:  python -m pip install psutil
"""
import hashlib, http.client, json, os, subprocess, sys, tempfile, threading, time, unittest
from unittest import mock

IS_WIN = sys.platform == "win32"

loader_reason = "not on Windows"
_config_tmp = None
if IS_WIN:
    import importlib.machinery, importlib.util
    _config_tmp = tempfile.TemporaryDirectory()
    os.environ["APPDATA"] = _config_tmp.name
    HERE = os.path.dirname(os.path.abspath(__file__))
    SCRIPT = os.path.join(HERE, "pineports")
    loader = importlib.machinery.SourceFileLoader("pineports_win", SCRIPT)
    spec = importlib.util.spec_from_loader("pineports_win", loader)
    pp = importlib.util.module_from_spec(spec)
    loader.exec_module(pp)

WIN_REASON = "runs only on Windows (smoke test against real OS)"


@unittest.skipUnless(IS_WIN, WIN_REASON)
class WinSmoke(unittest.TestCase):
    def test_psutil_available(self):
        self.assertIsNotNone(
            pp._psutil, f"psutil is not installed for {sys.executable}")

    def test_listeners_nonempty(self):
        got = pp.win_listeners()
        self.assertIsInstance(got, list)
        self.assertGreater(len(got), 0, "no listening sockets found?")
        for pid, port, ext in got:
            self.assertIsInstance(pid, int)
            self.assertIsInstance(port, int)
            self.assertIsInstance(ext, bool)

    def test_gather_schema(self):
        rows = pp.gather()
        self.assertIsInstance(rows, list)
        for r in rows:
            for k in ("name", "pid", "rss", "cmd", "ports", "links", "kind", "new"):
                self.assertIn(k, r)
            self.assertIsInstance(r["ports"], list)

    def test_bundled_docker_addon_is_registered(self):
        self.assertIn("docker", pp.ADDONS)
        cmd = pp.ADDONS["docker"]["cmd"]
        if isinstance(cmd, list):
            self.assertEqual(cmd[0], sys.executable)
        else:
            self.assertTrue(os.path.basename(cmd).startswith("pineports-docker"))

    def test_sys_stats_values(self):
        st = pp.sys_stats()
        for k in ("ram_pct", "ram_used", "ram_total", "cpu_pct", "disk_pct",
                  "disk_free", "uptime", "load1", "net_down", "net_up", "conns"):
            self.assertIn(k, st)
        self.assertGreater(st["ram_total"], 0)
        self.assertAlmostEqual(
            st["ram_total"],
            round(pp._psutil.virtual_memory().total / 2**30, 1), places=1)
        self.assertGreaterEqual(st["ram_pct"], 0)
        self.assertLessEqual(st["ram_pct"], 100)
        self.assertGreaterEqual(st["disk_pct"], 0)
        self.assertLessEqual(st["disk_pct"], 100)
        self.assertNotEqual(st["uptime"], "-")

    def test_web_login_and_services(self):
        with open(pp.PIN_FILE, "w") as f:
            f.write(hashlib.sha256(b"1234").hexdigest())
        server = pp.ThreadingHTTPServer(("127.0.0.1", 0), pp.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            conn.request("POST", "/api/login", body="1234")
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            cookie = response.getheader("Set-Cookie").split(";", 1)[0]
            response.read()
            conn.close()

            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            conn.request("GET", "/api/services", headers={"Cookie": cookie})
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            data = json.loads(response.read())
            self.assertIn("services", data)
            self.assertIn("stats", data)
            conn.close()

            with mock.patch.object(pp, "kill_port", return_value="stopped") as kill:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                conn.request("POST", "/api/kill",
                             body=json.dumps({"port": "4321", "pid": "9876"}),
                             headers={"Cookie": cookie})
                response = conn.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), b"stopped")
                kill.assert_called_once_with("4321", 9876)
                conn.close()

            with open(pp.PIN_FILE, "w") as f:
                f.write(hashlib.sha256(b"5678").hexdigest())
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            conn.request("GET", "/api/services", headers={"Cookie": cookie})
            response = conn.getresponse()
            self.assertIn(b"<form", response.read())
            conn.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_kill_own_python_port(self):
        code = ("import socket,time; s=socket.socket(); "
                "s.bind(('127.0.0.1',0)); s.listen(); "
                "print(s.getsockname()[1],flush=True); time.sleep(30)")
        child = subprocess.Popen([sys.executable, "-c", code],
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        try:
            port = int(child.stdout.readline().strip())
            deadline = time.time() + 10
            while time.time() < deadline:
                if any(pid == child.pid and p == port
                       for pid, p, _ext in pp.win_listeners()):
                    break
                time.sleep(0.1)
            else:
                self.fail(f"child listener :{port} was not discovered")
            msg = pp.win_kill_port(port, child.pid)
            self.assertIn("stopped", msg.lower())
            child.wait(timeout=10)
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)

def tearDownModule():
    if _config_tmp:
        _config_tmp.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
