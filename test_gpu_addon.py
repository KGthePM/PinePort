#!/usr/bin/env python3
"""offline checks for the pineports-gpu add-on"""
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.abspath(__file__))

# 1. the CLI parses mocked nvidia-smi output, mapping [N/A] -> null
mock = "/tmp/pineports-gpu-test-bin/nvidia-smi"
os.makedirs(os.path.dirname(mock), exist_ok=True)
with open(mock, "w") as f:
    f.write("""#!/bin/bash
if [[ "$1" == --query-gpu=* && "$2" == "--format=csv,noheader,nounits" ]]; then
  echo "0, NVIDIA GeForce RTX 4070, 34, 5120, 12288, 61, 143.5, 200, 55"
  echo "1, NVIDIA GeForce RTX 3060, 0, 990, 12288, 38, [N/A], 170, [N/A]"
else
  echo "unexpected args: $@" >&2; exit 1
fi
""")
os.chmod(mock, 0o755)
os.environ["PATH"] = os.path.dirname(mock) + ":" + os.environ["PATH"]

cli = os.path.join(REPO, "pineports-gpu")
r = subprocess.run([cli], capture_output=True, text=True)
assert r.returncode == 0, r.stderr
d = json.loads(r.stdout)
g = d["gpus"]
assert g[0]["name"] == "NVIDIA GeForce RTX 4070"
assert g[0]["power_draw"] == 143.5 and g[0]["fan"] == 55
assert g[1]["power_draw"] is None and g[1]["fan"] is None, "[N/A] must map to null"
assert g[1]["util"] == 0.0, "a real 0 reading must not become null"
assert isinstance(d["updated"], float)
r2 = subprocess.run([cli, "--cached"], capture_output=True, text=True)
assert json.loads(r2.stdout)["gpus"] == g, "--cached must match live output"
print("1. CLI parse + [N/A]->null + --cached parity — OK")

# 2. the probe finds pineports-gpu (on PATH here) and registers it with the
#    right args/timeouts
loader = SourceFileLoader("pineports", os.path.join(REPO, "pineports"))
spec = importlib.util.spec_from_loader("pineports", loader)
pp = importlib.util.module_from_spec(spec)
loader.exec_module(pp)
assert "gpu" in pp.ADDONS, "gpu add-on not registered"
a = pp.ADDONS["gpu"]
assert a["cached"] == ["--cached"] and a["live"] == []
assert a["timeout"] == (10, 10)
print("2. ADDONS registration — OK:", a)

# 3. PAGE carries the gpu renderer and the registration
src = open(os.path.join(REPO, "pineports")).read()
assert "gpu:(box,d)=>" in src, "missing gpu card renderer"
assert 'pgpu = _addon_cmd("pineports-gpu")' in src
print("3. renderer + registration present in pineports — OK")

# 4. without nvidia-smi the CLI exits 1 with a stderr message (the card
#    shows it) — simulate by pointing PATH at an empty dir via a wrapper
env = dict(os.environ, PATH="/tmp/pineports-gpu-test-empty")
os.makedirs("/tmp/pineports-gpu-test-empty", exist_ok=True)
r3 = subprocess.run([sys.executable, cli], capture_output=True, text=True,
                    env=env)
assert r3.returncode == 1 and "nvidia-smi not found" in r3.stderr
print("4. missing-driver error path — OK")

print("ALL GPU ADD-ON CHECKS PASSED")
