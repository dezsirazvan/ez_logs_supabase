"""Stand-in for EZLogs' ingest endpoint during the tests.

Logs every POST body as one JSON line and answers with the status written in the
control file (default 202), so a test can play "down", "key revoked" or "rate limited".
Usage: python3 -I receiver.py <log.jsonl> <status-file> <port>
"""
import http.server
import json
import socketserver
import sys
import time

LOG, STATUS_FILE, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])


def current_status():
    try:
        with open(STATUS_FILE) as f:
            return int(f.read().strip() or 202)
    except (OSError, ValueError):
        return 202


class Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.1: curl (inside pg_net) sends large bodies with "Expect: 100-continue"; an
    # HTTP/1.0 server never answers it and reads a cut body.
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        # Read until the whole declared body is in: a socket read can return less.
        wanted = int(self.headers.get("content-length", 0))
        body = b""
        while len(body) < wanted:
            chunk = self.rfile.read1(wanted - len(body))
            if not chunk:
                break
            body += chunk
        status = current_status()
        with open(LOG, "a") as f:
            f.write(json.dumps({
                "at": time.time(),
                "status": status,
                "auth": self.headers.get("authorization", "")[:13],
                "body": json.loads(body),
            }) + "\n")
        reply = b'{"ok":true}'
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


Server(("0.0.0.0", PORT), Handler).serve_forever()
