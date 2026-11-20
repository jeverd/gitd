"""A webhook endpoint for tests.

    python3 webhook_receiver.py LOG_FILE PORT_FILE

Appends each delivery to LOG_FILE as one JSON line (path, headers, body)
and writes its port to PORT_FILE. The path picks the behavior:
  /ok           answer 200
  /fail/N       answer 500 to the first N requests on that path, then 200
  /down         always answer 500
  /hang         never answer (until the client gives up)
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_path, port_path = sys.argv[1], sys.argv[2]
lock = threading.Lock()
seen = {}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length).decode()
        with lock:
            with open(log_path, "a") as f:
                f.write(json.dumps({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body}) + "\n")
            seen[self.path] = seen.get(self.path, 0) + 1
            count = seen[self.path]
        if self.path == "/hang":
            time.sleep(30)
            return
        code = 200
        if self.path == "/down":
            code = 500
        elif self.path.startswith("/fail/") and count <= int(self.path.split("/")[2]):
            code = 500
        self.send_response(code)
        self.send_header("content-length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
with open(port_path, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
