#!/usr/bin/env python3
"""Trim a real CINC Auditor result for a fixture of the on-box exercise
profiles. Only whole elements are dropped: the platform target_id, group
listings and each control's source_location.ref (their ids and refs are
paths on the machine that ran the scan). Used for
tests/verify/fixtures/fips-exercise.json (a scripts/validate.sh run of
verify/el10-fips-exercise) and verify/el10-fips-exercise/files/
saf-cli-input.json (the CINC Auditor exercise's own result on the box)."""
import json, sys
# usage: trim-onbox.py <results.json> <fixture.json>
src, dst = sys.argv[1], sys.argv[2]
h = json.load(open(src))
h["platform"].pop("target_id", None)
for p in h["profiles"]:
    p["groups"] = []
    for c in p["controls"]:
        c.get("source_location", {}).pop("ref", None)
json.dump(h, open(dst, "w"), indent=1, sort_keys=True)
open(dst, "a").write("\n")
print(dst, sum(len(p["controls"]) for p in h["profiles"]))
