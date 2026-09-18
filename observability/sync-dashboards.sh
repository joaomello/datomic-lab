#!/usr/bin/env bash
# Pulls dashboards from the running Grafana back into the provisioning JSON
# files. Grafana's file provisioner is one-way (disk -> Grafana) and the
# dashboards volume is mounted read-only, so UI edits only ever land in
# Grafana's own sqlite db. Run this after clicking Save in the UI to
# persist those edits into the files this repo actually tracks.
set -euo pipefail

cd "$(dirname "$0")"

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
DASHBOARDS_DIR="grafana/dashboards"

for file in "$DASHBOARDS_DIR"/*.json; do
  uid=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['uid'])" "$file")

  echo "Syncing $file (uid=$uid) ..."
  curl -sf "$GRAFANA_URL/api/dashboards/uid/$uid" \
    | python3 -c "
import json, sys
resp = json.load(sys.stdin)
dashboard = resp['dashboard']
dashboard.pop('id', None)
print(json.dumps(dashboard, indent=2, ensure_ascii=False))
" > "$file.tmp"

  mv "$file.tmp" "$file"
done

echo "Done. Review the diff before committing:"
echo "  git -C .. diff -- observability/grafana/dashboards"
