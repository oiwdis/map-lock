#!/bin/bash
# Merge disputed / non-quiz land into the parent country so shared borders dissolve.
# Somaliland→Somalia, Northern Cyprus→Cyprus, Hong Kong+Macao→China, Siachen Glacier→India.
# Tiny countries can lose geometry under aggressive precision; we restore them from the input.
set -euo pipefail
cd "$(dirname "$0")/.."
GEO=Sources/MapLock/Resources/countries.geojson
tmp="$(mktemp -d)"
cp "$GEO" "$tmp/in.geojson"
mapshaper -i "$tmp/in.geojson" \
  -each 'if (name === "Somaliland") {name = "Somalia"} else if (name === "Northern Cyprus") {name = "Cyprus"} else if (name === "Hong Kong" || name === "Macao") {name = "China"} else if (name === "Siachen Glacier") {name = "India"}' \
  -dissolve fields=name copy-fields=continent \
  -o "$tmp/out.geojson" force
python3 - "$tmp/in.geojson" "$tmp/out.geojson" "$GEO" <<'PY'
import json, copy, sys
src, out, dest = sys.argv[1:4]
before = {f["properties"]["name"]: f for f in json.load(open(src))["features"]}
data = json.load(open(out))
for f in data["features"]:
    if not f.get("geometry") and f["properties"]["name"] in before:
        f["geometry"] = copy.deepcopy(before[f["properties"]["name"]]["geometry"])
json.dump(data, open(dest, "w"))
print("Wrote", dest, "features", len(data["features"]))
PY
