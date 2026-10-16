"""Dummy for Coolify and a deployed app, used by test/coolify-deploy.test.sh.

POST /api/v1/deploy?uuid=…  like Coolify: 200 with a valid token, 401 without, 404 for
                            UUIDs starting with "missing". GET: 405, as since 4.3.2.
GET  /version               reports the old revision until DELAY seconds have passed
                            since the first deployment, then NEW_REVISION.
GET  /version-spaces        the same with spaces around the colon.
GET  /ok                    200
GET  /broken                503

Usage: python3 dummy-coolify.py <port>, controlled by TOKEN, NEW_REVISION, DELAY.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = os.environ.get("TOKEN", "secret")
NEW_REVISION = os.environ["NEW_REVISION"]
DELAY = float(os.environ.get("DELAY", "0"))
OLD_REVISION = "0" * 40

deployed_at = None


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        global deployed_at
        url = urlparse(self.path)
        if url.path != "/api/v1/deploy":
            return self.send(404, '{"message":"Not found."}')
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.send(401, '{"message":"Unauthenticated."}')
        uuid = parse_qs(url.query).get("uuid", [""])[0]
        if uuid.startswith("missing"):
            return self.send(404, '{"message":"Resource not found."}')
        if deployed_at is None:
            deployed_at = time.monotonic()
        self.send(200, json.dumps({"deployments": [{"resource_uuid": uuid}]}))

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/version", "/version-spaces"):
            live = deployed_at is not None and time.monotonic() - deployed_at >= DELAY
            revision = NEW_REVISION if live else OLD_REVISION
            if path == "/version":
                return self.send(200, f'{{"status":"ok","revision":"{revision}"}}')
            return self.send(200, f'{{ "status": "ok", "revision" : "{revision}" }}')
        if path == "/ok":
            return self.send(200, '{"status":"ok"}')
        if path == "/api/v1/deploy":
            return self.send(405, '{"message":"Method not allowed."}')
        if path == "/broken":
            return self.send(503, "Bad Gateway")
        self.send(404, "{}")

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
