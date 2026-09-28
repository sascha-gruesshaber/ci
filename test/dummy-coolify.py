"""Dummy für Coolify und eine ausgelieferte App, für test/coolify-deploy.test.sh.

POST /api/v1/deploy?uuid=…  wie Coolify: 200 bei gültigem Token, 401 ohne, 404 für
                            UUIDs, die mit "fehlt" beginnen. GET: 405 wie seit 4.3.2.
GET  /version               meldet die alte Revision, bis DELAY Sekunden nach dem
                            ersten Deployment vergangen sind, danach NEW_REVISION.
GET  /version-spaces        dasselbe mit Leerzeichen um den Doppelpunkt.
GET  /ok                    200
GET  /kaputt                503

Aufruf: python3 dummy-coolify.py <port>, gesteuert über TOKEN, NEW_REVISION, DELAY.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = os.environ.get("TOKEN", "geheim")
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
        if uuid.startswith("fehlt"):
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
        if path == "/kaputt":
            return self.send(503, "Bad Gateway")
        self.send(404, "{}")

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
