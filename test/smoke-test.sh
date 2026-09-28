#!/usr/bin/env bash
# Rauchtest für das Selbsttest-Image. docker-image.yml ruft ihn mit IMAGE=<sha-Referenz>
# auf, bevor gepusht wird. Prüft, dass Target, Build-Argumente und Labels ankommen.
set -euo pipefail

: "${IMAGE:?IMAGE fehlt}"
: "${GITHUB_SHA:?GITHUB_SHA fehlt}"

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

grep -qF "\"revision\":\"${GITHUB_SHA}\"" <<< "$body" || fail "APP_REVISION fehlt oder falsches Target"
grep -Eq '"builtAt":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"' <<< "$body" || fail "APP_BUILT_AT ist keine ISO-Zeit"
grep -qF '"gruss":"hallo"' <<< "$body" || fail "build-args kommen nicht an"

labels=$(docker image inspect "$IMAGE" --format '{{json .Config.Labels}}')
echo "Labels: ${labels}"
grep -qF "\"org.opencontainers.image.revision\":\"${GITHUB_SHA}\"" <<< "$labels" || fail "Label revision fehlt"
grep -qF '"org.opencontainers.image.created":"' <<< "$labels" || fail "Label created fehlt"
grep -qF '"org.opencontainers.image.source":"https://' <<< "$labels" || fail "Label source fehlt"

echo "Rauchtest bestanden"
