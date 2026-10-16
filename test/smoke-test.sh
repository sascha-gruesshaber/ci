#!/usr/bin/env bash
# Smoke test for the selftest image. docker-image.yml runs it with IMAGE=<sha reference>
# before pushing. Checks that the target, the build arguments and the labels arrive.
set -euo pipefail

: "${IMAGE:?IMAGE is missing}"
: "${GITHUB_SHA:?GITHUB_SHA is missing}"

name="selftest-$$"
trap 'docker rm -f "$name" > /dev/null 2>&1 || true' EXIT
docker run -d --name "$name" -p 127.0.0.1::8080 "$IMAGE" > /dev/null
port=$(docker port "$name" 8080/tcp | head -n1 | sed 's/.*://')

body=""
for _ in $(seq 1 30); do
  body=$(curl -fsS "http://127.0.0.1:${port}/version.json" 2>/dev/null) && break
  sleep 1
done
echo "version.json: ${body}"

fail() { echo "::error::$1"; exit 1; }

grep -qF "\"revision\":\"${GITHUB_SHA}\"" <<< "$body" || fail "APP_REVISION missing or wrong target"
grep -Eq '"builtAt":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"' <<< "$body" || fail "APP_BUILT_AT is not an ISO timestamp"
grep -qF '"greeting":"hello"' <<< "$body" || fail "build-args do not arrive"

labels=$(docker image inspect "$IMAGE" --format '{{json .Config.Labels}}')
echo "Labels: ${labels}"
grep -qF "\"org.opencontainers.image.revision\":\"${GITHUB_SHA}\"" <<< "$labels" || fail "label revision missing"
grep -qF '"org.opencontainers.image.created":"' <<< "$labels" || fail "label created missing"
grep -qF '"org.opencontainers.image.source":"https://' <<< "$labels" || fail "label source missing"

echo "Smoke test passed"
