#!/usr/bin/env python3
"""Dev bridge: lets a Claude Code session answer the app's translation requests.

The app (provider "Claude Code (dev bridge)") POSTs {"system": ..., "user": ...} to
http://localhost:8793/llm. Each request is written to queue/<id>.request.json; the
request waits until queue/<id>.answer.json appears (written by Claude Code), then
returns {"text": <that file's contents>}.

    python3 tools/claude_bridge.py            # serve on 127.0.0.1:8793
    python3 tools/claude_bridge.py --pending  # list unanswered requests

Wait for the next request (exits when one is unanswered):
    until python3 tools/claude_bridge.py --pending | grep -q request; do sleep 2; done

Several sessions (or subagents) can answer at once without taking the same request:
    python3 tools/claude_bridge.py --claim [--wait SECONDS]   # takes the oldest unclaimed request, prints its path
    python3 tools/claude_bridge.py --answer <request path> <answer file>   # hands the answer over
"""
import json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QUEUE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "queue")
PORT = 8793
TIMEOUT = 30 * 60  # seconds a request waits for an answer


def pending(unclaimed=False):
    names = sorted(os.listdir(QUEUE)) if os.path.isdir(QUEUE) else []
    return [n for n in names if n.endswith(".request.json")
            and n.replace(".request.json", ".answer.json") not in names
            and not (unclaimed and n.replace(".request.json", ".claim") in names)]


def claim(wait):
    """The oldest request no one has claimed yet, claimed (None if none came within `wait` seconds)."""
    deadline = time.time() + wait
    while True:
        # a claim nobody answered within 15 minutes is given up (the worker stopped)
        for n in os.listdir(QUEUE):
            p = os.path.join(QUEUE, n)
            if n.endswith(".claim") and time.time() - os.path.getmtime(p) > 15 * 60:
                os.remove(p)
        for n in pending(unclaimed=True):
            try:
                os.close(os.open(os.path.join(QUEUE, n.replace(".request.json", ".claim")), os.O_CREAT | os.O_EXCL))
                return os.path.join(QUEUE, n)
            except FileExistsError:
                continue
        if time.time() > deadline:
            return None
        time.sleep(2)


def answer(request, path):
    """Moves an answer into place in one step, so the server never reads half of it."""
    text = open(path, encoding="utf-8").read()
    ans = request.replace(".request.json", ".answer.json")
    with open(ans + ".tmp", "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(ans + ".tmp", ans)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/llm":
            return self.send_error(404)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        rid = time.strftime("%H%M%S-") + uuid.uuid4().hex[:6]
        req = os.path.join(QUEUE, rid + ".request.json")
        ans = os.path.join(QUEUE, rid + ".answer.json")
        with open(req, "w") as f:
            json.dump(body, f, ensure_ascii=False, indent=1)
        print(f"request {rid}: {len(body.get('user', ''))} chars", flush=True)
        deadline = time.time() + TIMEOUT
        while not os.path.exists(ans):
            if time.time() > deadline:
                os.remove(req)
                return self.send_error(504, "No answer from Claude Code")
            time.sleep(1)
        time.sleep(0.3)  # let the writer finish
        text = open(ans, encoding="utf-8").read()
        for p in (req, ans, req.replace(".request.json", ".claim")):
            if os.path.exists(p):
                os.remove(p)
        out = json.dumps({"text": text}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
        print(f"answered {rid}", flush=True)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    os.makedirs(QUEUE, exist_ok=True)
    if "--claim" in sys.argv:
        wait = int(sys.argv[sys.argv.index("--wait") + 1]) if "--wait" in sys.argv else 0
        print(claim(wait) or "none")
        sys.exit(0)
    if "--answer" in sys.argv:
        i = sys.argv.index("--answer")
        answer(sys.argv[i + 1], sys.argv[i + 2])
        print("answered")
        sys.exit(0)
    if "--pending" in sys.argv:
        for n in pending():
            print(os.path.join(QUEUE, n))
        sys.exit(0)
    print(f"Claude Code bridge on http://127.0.0.1:{PORT}/llm, queue {QUEUE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
