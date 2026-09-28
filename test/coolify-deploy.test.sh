#!/usr/bin/env bash
# Prüft das Skript aus .github/workflows/coolify-deploy.yml gegen test/dummy-coolify.py.
# Läuft lokal und in der CI dieses Repos: bash test/coolify-deploy.test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT

# Genau der `run`-Block, der auch in GitHub läuft. GitHub startet ihn mit `bash -e`, der
# Test deshalb auch (siehe run_case).
python3 - > "$work/deploy.sh" <<'EOF'
import yaml
wf = yaml.safe_load(open(".github/workflows/coolify-deploy.yml"))
steps = wf["jobs"]["deploy"]["steps"]
print(next(s["run"] for s in steps if s.get("name") == "Anstoßen und prüfen"))
EOF

revision=$(printf 'selftest' | sha1sum | cut -c1-40)
failures=0
server=""

start_server() { # <delay>
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  TOKEN=geheim NEW_REVISION="$revision" DELAY="$1" python3 test/dummy-coolify.py "$port" &
  server=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:${port}/ok" && return 0
    sleep 0.1
  done
  echo "Dummy-Server startet nicht"; exit 1
}

# run_case <name> <erwarteter Exit-Code> <erwartete Ausgabe> [VAR=wert …]
run_case() {
  local name=$1 want_code=$2 want_text=$3; shift 3
  local base="http://127.0.0.1:${port}"
  local code=0
  env -i PATH="$PATH" HOME="$HOME" \
    GITHUB_SHA="$revision" GITHUB_STEP_SUMMARY="$work/summary" \
    COOLIFY_URL="$base" COOLIFY_API_TOKEN=geheim WAIT_MINUTES=10 \
    UUIDS="app1" REVISION_URLS="" URLS="" POLL_INTERVAL=1 WAIT_SECONDS=10 \
    "${@//@BASE@/$base}" \
    bash -e "$work/deploy.sh" > "$work/out" 2>&1 || code=$?
  if [ "$code" = "$want_code" ] && grep -qF -- "$want_text" "$work/out"; then
    echo "ok    ${name}"
  else
    echo "FEHLER ${name}: Exit ${code} statt ${want_code} oder '${want_text}' fehlt. Ausgabe:"
    sed 's/^/    /' "$work/out"
    failures=$((failures + 1))
  fi
  rm -f "$work/summary"
}

start_server 2
run_case "neue Revision kommt nach 2 s" 0 "✅ http://127.0.0.1:${port}/version-spaces" \
  UUIDS="app1 app2" \
  REVISION_URLS=$'@BASE@/version\n@BASE@/version-spaces' \
  URLS="@BASE@/ok"

start_server 0
run_case "UUIDs zeilenweise" 0 "Stoße app2 an" UUIDS=$'app1\napp2\n' REVISION_URLS="@BASE@/version"
run_case "ohne URLs fertig nach dem Anstoßen" 0 "Fertig." UUIDS="app1"
run_case "leere UUID" 1 "Keine Coolify-UUID übergeben" UUIDS="  "
run_case "falscher Token" 1 "abgelehnt" COOLIFY_API_TOKEN=falsch
run_case "eine UUID abgelehnt, die andere trotzdem versucht" 1 "Stoße app3 an" \
  UUIDS="fehlt-app2 app3"
run_case "abgelehnte UUID wird gemeldet" 1 "fehlt-app2 abgelehnt" UUIDS="fehlt-app2 app3"
run_case "URL antwortet nie mit 2xx" 1 "HTTP 503" URLS="@BASE@/kaputt" WAIT_SECONDS=2
# curl scheitert (hier: Verbindung abgelehnt, in PuckHub war es ein Timeout, Exit 28).
# Das ist eine Antwort wie jede andere und darf das Warten nicht beenden.
run_case "nicht erreichbare URL wird weiter abgefragt" 1 "antwortet nach 2 s nicht mit 2xx" \
  URLS="http://127.0.0.1:1/" WAIT_SECONDS=2
run_case "nicht erreichbare Revisions-URL wird weiter abgefragt" 1 "meldet nach 2 s nicht die Revision" \
  REVISION_URLS="http://127.0.0.1:1/" WAIT_SECONDS=2

start_server 600
run_case "alte Revision läuft weiter" 1 "\"revision\":\"0000000000" \
  REVISION_URLS="@BASE@/version" WAIT_SECONDS=2

if [ "$failures" -ne 0 ]; then
  echo "${failures} Fall/Fälle fehlgeschlagen"
  exit 1
fi
echo "Alle Fälle bestanden"
