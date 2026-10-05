#!/usr/bin/env python3
"""offline checks for the pineports easy-wins edits"""
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import sys

loader = SourceFileLoader("pineports", "/home/kg/PinePort/pineports")
spec = importlib.util.spec_from_loader("pineports", loader)
pp = importlib.util.module_from_spec(spec)
loader.exec_module(pp)

fail = 0

# 1. gather() entries carry a "new" list
g = pp.gather()
assert all(isinstance(e.get("new"), list) for e in g), "missing 'new' key"
print(f"1. gather() OK — {len(g)} services, all with 'new' list")

# 2. a fresh unknown port (below the ephemeral cutoff) gets badged
seen = json.load(open(pp.SEEN_FILE))
fresh = 12345
while str(fresh) in seen:
    fresh += 1
badged = pp.badge_ports([fresh], pp.load_labels())
assert fresh in badged, "fresh port not badged"
print(f"2. fresh port {fresh} badged (first sighting)")

# 3. labeled ports never badged
labels = pp.load_labels()
if labels:
    lp = next(iter(labels))
    seen[str(lp)] = pp.time.time()  # pretend just seen
    json.dump(seen, open(pp.SEEN_FILE, "w"))
    assert lp not in pp.badge_ports([lp], labels), "labeled port badged"
    print(f"3. labeled port :{lp} ({labels[lp]}) not badged — OK")

# 4. ephemeral high ports never badged
eph = 40000
pp.SEEN_FILE  # noqa
seen = json.load(open(pp.SEEN_FILE))
seen[str(eph)] = pp.time.time()
json.dump(seen, open(pp.SEEN_FILE, "w"))
assert eph not in pp.badge_ports([eph], {}), "ephemeral port badged"
print("4. ephemeral port :40000 not badged — OK")

# 5. addons registry includes docker helper when installed
print(f"5. ADDONS found: {sorted(pp.ADDONS)}")

# 6. PAGE carries the badge CSS + docker renderer + threading server class
src = open("/home/kg/PinePort/pineports").read()
for needle in ('class="badge">new', "docker:(box,d)=>", "ThreadingHTTPServer(("):
    assert needle in src, f"missing: {needle}"
print("6. PAGE + server edits present — OK")

print("ALL CHECKS PASSED")
