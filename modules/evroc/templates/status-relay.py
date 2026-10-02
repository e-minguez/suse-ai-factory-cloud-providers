#!/usr/bin/env python3
# Build-status relay on the jumphost. GET /zones/<zone> serves the last status
# a zone published; PUT /zones/<zone> publishes one, accepted only from inside
# PUSH_CIDR (the VPC) so the operator-facing side stays read-only.
# Python 3.6-compatible: Leap 15.6's python3 has no ThreadingHTTPServer and
# no --directory.
import ipaddress, os, re, sys, tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

ROOT = os.environ.get("STATUS_DIR", "/var/lib/image-factory/zones")
PORT = int(os.environ.get("STATUS_PORT", "8080"))
PUSH_NETS = [ipaddress.ip_network(c) for c in os.environ["PUSH_CIDR"].split()]
ZONES = set(os.environ["ZONES"].split())
# A status line is one short line.
MAX_BODY = 4096
PATH_RE = re.compile(r"^/zones/([a-z0-9-]+)$")


class Handler(BaseHTTPRequestHandler):
    def _target(self):
        m = PATH_RE.match(self.path)
        if not m or m.group(1) not in ZONES:
            self.send_error(404)
            return None
        name = m.group(1)
        return name, MAX_BODY

    def _reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        target = self._target()
        if target is None:
            return
        try:
            with open(os.path.join(ROOT, target[0]), "rb") as f:
                self._reply(200, f.read())
        except FileNotFoundError:
            self.send_error(404)

    def do_PUT(self):
        target = self._target()
        if target is None:
            return
        name, max_body = target
        if not any(ipaddress.ip_address(self.client_address[0]) in n for n in PUSH_NETS):
            self.send_error(403)
            return
        # No chunked uploads: curl sends Content-Length for `-T <file>`, and
        # only a stdin upload (`-T -`) would arrive chunked.
        if "Content-Length" not in self.headers:
            self.send_error(411)
            return
        length = int(self.headers["Content-Length"])
        if length <= 0 or length > max_body:
            self.send_error(413)
            return
        body = self.rfile.read(length)
        # Rename, so a GET never sees a half-written status.
        fd, tmp = tempfile.mkstemp(dir=ROOT, prefix=".tmp-")
        with os.fdopen(fd, "wb") as f:
            f.write(body)
        os.replace(tmp, os.path.join(ROOT, name))
        self._reply(204)


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    os.makedirs(ROOT, exist_ok=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
