"""A speed check for a running gitd: how long the calls an agent harness makes take.

    python3 tests/bench/bench.py BASE_URL ADMIN_KEY [--agents 16] [--commits 25]

Makes a fresh repo, then times: commits through the API one at a time, many agents
committing to their own branches at once, a clone, a push, a compare, and a merge.
Prints p50/p95/max per call and the commits per second when the agents run at once.
"""

import argparse
import json
import os
import statistics
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid

GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}
GIT_ID = ["-c", "user.name=bench", "-c", "user.email=bench@example.com", "-c", "init.defaultBranch=main"]


def call(base, key, method, path, body=None):
    req = urllib.request.Request(base + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def timed(fn):
    start = time.perf_counter()
    out = fn()
    return (time.perf_counter() - start) * 1000, out


def report(name, ms):
    ms = sorted(ms)
    p95 = ms[min(len(ms) - 1, int(len(ms) * 0.95))]
    print(f"{name:<34} n={len(ms):<4} p50={statistics.median(ms):7.1f}ms  p95={p95:7.1f}ms  max={ms[-1]:7.1f}ms")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("key")
    ap.add_argument("--agents", type=int, default=16)
    ap.add_argument("--commits", type=int, default=25)
    a = ap.parse_args()
    repo = f"bench/r{uuid.uuid4().hex[:8]}"
    ms, (code, _) = timed(lambda: call(a.base, a.key, "POST", "/v1/repos", {"name": repo}))
    assert code == 201, code
    report("create repo", [ms])

    head = None
    seq = []
    for i in range(50):
        body = {"branch": "main", "expected_head": head, "message": f"c{i}",
                "changes": [{"path": f"src/f{i % 10}.txt", "content": f"v{i}\n" * 50}]}
        ms, (code, out) = timed(lambda: call(a.base, a.key, "POST", f"/v1/repos/{repo}/commits", body))
        assert code == 201, (code, out)
        head = out["sha"]
        seq.append(ms)
    report("commit (one at a time)", seq)

    lat, errors, lock = [], [], threading.Lock()

    def agent(n):
        tip = None
        for i in range(a.commits):
            body = {"branch": f"agent/{n}", "expected_head": tip, "from": "main" if tip is None else None,
                    "message": f"agent {n} step {i}", "changes": [{"path": f"agent{n}/step.txt", "content": f"{i}\n"}]}
            if body["from"] is None:
                del body["from"]
            ms, (code, out) = timed(lambda: call(a.base, a.key, "POST", f"/v1/repos/{repo}/commits", body))
            with lock:
                if code != 201:
                    errors.append((code, out))
                    return
                lat.append(ms)
            tip = out["sha"]

    threads = [threading.Thread(target=agent, args=(n,)) for n in range(a.agents)]
    start = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - start
    assert not errors, errors[:3]
    report(f"commit ({a.agents} agents at once)", lat)
    print(f"{'':<34} {len(lat) / wall:.0f} commits/s over {wall:.1f}s")

    code, out = call(a.base, a.key, "POST", "/v1/tokens", {"repo": repo, "scopes": ["git:read", "git:write"], "ttl_seconds": 600})
    url = a.base.replace("://", f"://t:{out['token']}@") + f"/{repo}.git"
    with tempfile.TemporaryDirectory() as tmp:
        clones = []
        for i in range(5):
            ms, r = timed(lambda: subprocess.run(["git", "clone", "-q", url, f"{tmp}/c{i}"], env=GIT_ENV, capture_output=True))
            assert r.returncode == 0, r.stderr
            clones.append(ms)
        report("git clone", clones)
        pushes = []
        for i in range(10):
            subprocess.run(["git", *GIT_ID, "-C", f"{tmp}/c0", "commit", "-q", "--allow-empty", "-m", f"p{i}"], env=GIT_ENV, check=True)
            ms, r = timed(lambda: subprocess.run(["git", "-C", f"{tmp}/c0", "push", "-q", "origin", "HEAD:refs/heads/pushed"], env=GIT_ENV, capture_output=True))
            assert r.returncode == 0, r.stderr
            pushes.append(ms)
        report("git push (one commit)", pushes)

    cmp = [timed(lambda: call(a.base, a.key, "GET", f"/v1/repos/{repo}/compare/main...agent/{n}"))[0] for n in range(a.agents)]
    report("compare", cmp)
    merges = []
    for n in range(a.agents):
        ms, (code, out) = timed(lambda: call(a.base, a.key, "POST", f"/v1/repos/{repo}/merges",
                                             {"base": "main", "head": f"agent/{n}", "strategy": "merge"}))
        assert code in (200, 201), (code, out)
        merges.append(ms)
    report("merge (no conflicts)", merges)


if __name__ == "__main__":
    main()
