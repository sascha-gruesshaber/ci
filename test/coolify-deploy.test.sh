#!/usr/bin/env bash
# Tests the script from .github/workflows/coolify-deploy.yml against test/dummy-coolify.py.
# Runs locally and in this repository's CI: bash test/coolify-deploy.test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT

# Exactly the `run` block that runs on GitHub. GitHub starts it with `bash -e`, so the
# test does too (see run_case).
python3 - > "$work/deploy.sh" <<'EOF'
import yaml
wf = yaml.safe_load(open(".github/workflows/coolify-deploy.yml"))
steps = wf["jobs"]["deploy"]["steps"]
print(next(s["run"] for s in steps if s.get("name") == "Trigger and verify"))
EOF

revision=$(printf 'selftest' | sha1sum | cut -c1-40)
failures=0
server=""

start_server() { # <delay>
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  TOKEN=secret NEW_REVISION="$revision" DELAY="$1" python3 test/dummy-coolify.py "$port" &
  server=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:${port}/ok" && return 0
    sleep 0.1
  done
  echo "Dummy server does not start"; exit 1
}

# run_case <name> <expected exit code> <expected output> [VAR=value …]
run_case() {
  local name=$1 want_code=$2 want_text=$3; shift 3
  local base="http://127.0.0.1:${port}"
  local code=0
  env -i PATH="$PATH" HOME="$HOME" \
    GITHUB_SHA="$revision" GITHUB_STEP_SUMMARY="$work/summary" \
    COOLIFY_URL="$base" COOLIFY_API_TOKEN=secret WAIT_MINUTES=10 \
    UUIDS="app1" REVISION_URLS="" URLS="" POLL_INTERVAL=1 WAIT_SECONDS=10 \
    "${@//@BASE@/$base}" \
    bash -e "$work/deploy.sh" > "$work/out" 2>&1 || code=$?
  if [ "$code" = "$want_code" ] && grep -qF -- "$want_text" "$work/out"; then
    echo "ok    ${name}"
  else
    echo "FAIL  ${name}: exit ${code} instead of ${want_code}, or '${want_text}' missing. Output:"
    sed 's/^/    /' "$work/out"
    failures=$((failures + 1))
  fi
  rm -f "$work/summary"
}

start_server 2
run_case "new revision arrives after 2 s" 0 "✅ http://127.0.0.1:${port}/version-spaces" \
  UUIDS="app1 app2" \
  REVISION_URLS=$'@BASE@/version\n@BASE@/version-spaces' \
  URLS="@BASE@/ok"

start_server 0
run_case "UUIDs one per line" 0 "Triggering app2" UUIDS=$'app1\napp2\n' REVISION_URLS="@BASE@/version"
run_case "without URLs done after triggering" 0 "Done." UUIDS="app1"
run_case "empty UUID" 1 "No Coolify UUID given" UUIDS="  "
run_case "wrong token" 1 "rejected" COOLIFY_API_TOKEN=wrong
run_case "one UUID rejected, the other still tried" 1 "Triggering app3" \
  UUIDS="missing-app2 app3"
run_case "rejected UUID is reported" 1 "rejected the deployment of missing-app2" UUIDS="missing-app2 app3"
run_case "URL never answers with 2xx" 1 "HTTP 503" URLS="@BASE@/broken" WAIT_SECONDS=2
# curl fails (here: connection refused; in production it was a timeout, exit 28).
# That is an answer like any other and must not end the waiting.
run_case "unreachable URL keeps being polled" 1 "does not answer with 2xx after 2 s" \
  URLS="http://127.0.0.1:1/" WAIT_SECONDS=2
run_case "unreachable revision URL keeps being polled" 1 "does not report revision" \
  REVISION_URLS="http://127.0.0.1:1/" WAIT_SECONDS=2

start_server 600
run_case "old revision keeps running" 1 "\"revision\":\"0000000000" \
  REVISION_URLS="@BASE@/version" WAIT_SECONDS=2

if [ "$failures" -ne 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "All cases passed"
