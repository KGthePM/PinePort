#!/usr/bin/env python3
"""offline checks for the pineports-gpu add-on (Linux + Windows)"""
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from unittest import mock

REPO = os.path.dirname(os.path.abspath(__file__))
QUERY = ("index,name,utilization.gpu,memory.used,memory.total,"
         "temperature.gpu,power.draw,power.limit,fan.speed")

tmpdir = tempfile.mkdtemp(prefix="pineports-gpu-test-")

# 1. the CLI parses mocked nvidia-smi output, mapping [N/A] -> null.
# The mock is a bash shim on POSIX and a .bat shim on Windows (shutil.which
# only matches PATHEXT there, and the CLI's Windows fallbacks would find the
# real driver otherwise).
if os.name == "nt":
    # cmd splits batch args on = , ; so %1 is "--query-gpu" and %2 is
    # "index"; matching those two tokens still proves the CLI passed the
    # query flag and field list.
    smi_shim = os.path.join(tmpdir, "nvidia-smi.bat")
    with open(smi_shim, "w", newline="\r\n") as f:
        f.write("""@echo off
if not "%~1"=="--query-gpu" goto bad
if not "%~2"=="index" goto bad
echo 0, NVIDIA GeForce RTX 4070, 34, 5120, 12288, 61, 143.5, 200, 55
echo 1, NVIDIA GeForce RTX 3060, 0, 990, 12288, 38, [N/A], 170, [N/A]
exit /b 0
:bad
echo unexpected args: %* 1>&2
exit /b 1
""")
else:
    smi_shim = os.path.join(tmpdir, "nvidia-smi")
    with open(smi_shim, "w") as f:
        f.write(f"""#!/bin/bash
if [[ "$1" == "--query-gpu={QUERY}" && "$2" == "--format=csv,noheader,nounits" ]]; then
  echo "0, NVIDIA GeForce RTX 4070, 34, 5120, 12288, 61, 143.5, 200, 55"
  echo "1, NVIDIA GeForce RTX 3060, 0, 990, 12288, 38, [N/A], 170, [N/A]"
else
  echo "unexpected args: $@" >&2; exit 1
fi
""")
    os.chmod(smi_shim, 0o755)
os.environ["PATH"] = tmpdir + os.pathsep + os.environ["PATH"]

cli = os.path.join(REPO, "pineports-gpu")
r = subprocess.run([sys.executable, cli], capture_output=True, text=True)
assert r.returncode == 0, r.stderr
d = json.loads(r.stdout)
g = d["gpus"]
assert g[0]["name"] == "NVIDIA GeForce RTX 4070"
assert g[0]["power_draw"] == 143.5 and g[0]["fan"] == 55
assert g[1]["power_draw"] is None and g[1]["fan"] is None, "[N/A] must map to null"
assert g[1]["util"] == 0.0, "a real 0 reading must not become null"
assert isinstance(d["updated"], float)
r2 = subprocess.run([sys.executable, cli, "--cached"], capture_output=True, text=True)
assert json.loads(r2.stdout)["gpus"] == g, "--cached must match live output"
print("1. CLI parse + [N/A]->null + --cached parity — OK")

# 2. the probe finds pineports-gpu (installed, or via the Windows bundled
#    fallback) and registers it with the right args/timeouts
loader = SourceFileLoader("pineports", os.path.join(REPO, "pineports"))
spec = importlib.util.spec_from_loader("pineports", loader)
pp = importlib.util.module_from_spec(spec)
loader.exec_module(pp)
assert "gpu" in pp.ADDONS, "gpu add-on not registered"
a = pp.ADDONS["gpu"]
assert a["cached"] == ["--cached"] and a["live"] == []
assert a["timeout"] == (10, 10)
print("2. ADDONS registration — OK:", a)

# 3. PAGE carries the gpu stats-bar chip and the registration
src = open(os.path.join(REPO, "pineports")).read()
assert "function gpuChip(" in src, "missing gpu stats-bar chip"
assert "gpu:(box,d)=>" not in src, "gpu card renderer should be gone"
assert "loadGpu();" in src, "chip not wired into the poll loop"
assert 'pgpu = _addon_cmd("pineports-gpu")' in src
print("3. stats-bar chip + registration present in pineports — OK")

# 4. without nvidia-smi the CLI reports an empty list (benign card:
#    "no NVIDIA GPUs found"). PATH scrubbing alone can't hide the driver on
#    Windows (the CLI also probes System32 and the NVSMI folder), so patch
#    both lookups in-process.
loader = SourceFileLoader("pineports_gpu_bare", cli)
spec = importlib.util.spec_from_loader("pineports_gpu_bare", loader)
bare = importlib.util.module_from_spec(spec)
loader.exec_module(bare)
buf = io.StringIO()
with mock.patch.object(bare.shutil, "which", return_value=None), \
     mock.patch.object(bare, "WIN_FALLBACKS",
                       [os.path.join(tmpdir, "absent", "nvidia-smi.exe")]), \
     contextlib.redirect_stdout(buf):
    bare.main()
d3 = json.loads(buf.getvalue())
assert d3["gpus"] == [] and isinstance(d3["updated"], float)
print("4. missing-driver empty-list path — OK")

# 5. every <script> block of the dashboard page must compile as JavaScript.
# Needs node (not present on all boxes); skipped there.
node = shutil.which("node")
if node:
    checker = ("const vm=require('vm');const src=require('fs').readFileSync(0,'utf8');"
               "try{new vm.Script(src)}catch(e){console.error(e.message);process.exit(1)}")
    for i, block in enumerate(re.findall(r"<script>(.*?)</script>", pp.PAGE, re.S)):
        r = subprocess.run([node, "-e", checker], input=block.encode(),
                           capture_output=True)
        assert r.returncode == 0, f"page script {i} does not compile: {r.stderr.decode()}"
    print("5. dashboard page scripts compile (node) — OK")
else:
    print("5. node not found — JS compile check skipped")

print("ALL GPU ADD-ON CHECKS PASSED")
