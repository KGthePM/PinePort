#!/usr/bin/env python3
"""Real-Windows smoke test for PinePort. Skips on other OSes.

Run on a Windows box with:  python test_windows.py
Optional full data (recommended):  pip install psutil
"""
import os, sys, unittest

IS_WIN = sys.platform == "win32"

loader_reason = "not on Windows"
if IS_WIN:
    import importlib.machinery, importlib.util
    HERE = os.path.dirname(os.path.abspath(__file__))
    SCRIPT = os.path.join(HERE, "pineports")
    loader = importlib.machinery.SourceFileLoader("pineports_win", SCRIPT)
    spec = importlib.util.spec_from_loader("pineports_win", loader)
    pp = importlib.util.module_from_spec(spec)
    loader.exec_module(pp)

WIN_REASON = "runs only on Windows (smoke test against real OS)"


@unittest.skipUnless(IS_WIN, WIN_REASON)
class WinSmoke(unittest.TestCase):
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

    def test_sys_stats_shape(self):
        st = pp.sys_stats()
        for k in ("ram_pct", "ram_used", "ram_total", "cpu_pct", "disk_pct",
                  "disk_free", "uptime", "load1"):
            self.assertIn(k, st)

    def test_kill_own_python_port(self):
        import socket, threading, time
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        t = threading.Thread(target=srv.accept, daemon=True)
        t.start()
        time.sleep(0.2)
        try:
            msg = pp.win_kill_port(port)
            self.assertIn("stopped", msg.lower())
        finally:
            srv.close()

    def test_kill_empty_port_message(self):
        msg = pp.win_kill_port(1)  # port 1 is never ours
        self.assertIn("nothing listening", msg)


if __name__ == "__main__":
    unittest.main(verbosity=2)
