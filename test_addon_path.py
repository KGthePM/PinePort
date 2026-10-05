#!/usr/bin/env python3
"""addon probe must find helpers even when PATH is minimal (systemd user
manager at boot has no ~/.local/bin until a desktop session imports it)"""
import importlib.util
from importlib.machinery import SourceFileLoader
import os

os.environ["PATH"] = "/usr/bin:/bin"  # simulate boot-time user manager env

loader = SourceFileLoader("pineports", "/home/kg/PinePort/pineports")
spec = importlib.util.spec_from_loader("pineports", loader)
pp = importlib.util.module_from_spec(spec)
loader.exec_module(pp)

assert "needle" in pp.ADDONS, "needle add-on not found with minimal PATH"
assert pp.ADDONS["needle"]["cmd"].startswith("/home/kg/.local/bin"), pp.ADDONS["needle"]["cmd"]
print(f"ADDONS with minimal PATH: {sorted(pp.ADDONS)}")
print("ADDON PATH CHECK PASSED")
