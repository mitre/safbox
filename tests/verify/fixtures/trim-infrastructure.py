#!/usr/bin/env python3
"""Trim a real wrapper scan to its infrastructure controls for a fixture.
Only whole elements are dropped: STIG controls, group listings (their ids
are absolute paths on the scanning machine), each control's
source_location.ref (likewise), the platform target_id, and the STIG
profiles' inputs."""
import json, sys
# usage: trim-infrastructure.py <validate-results.json> <fixture.json>
src, dst = sys.argv[1], sys.argv[2]
h = json.load(open(src))
h["platform"].pop("target_id", None)
for p in h["profiles"]:
    p["controls"] = [c for c in p["controls"] if c["id"].startswith("safbox-")]
    for c in p["controls"]:
        c.get("source_location", {}).pop("ref", None)
    p["groups"] = []
    if p["name"] not in ("el10-infrastructure", "inspec-safbox"):
        p["attributes"] = []
json.dump(h, open(dst, "w"), indent=1, sort_keys=True)
open(dst, "a").write("\n")
print(dst, sum(len(p["controls"]) for p in h["profiles"]))
