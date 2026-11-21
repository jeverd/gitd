"""Comprehensive gitd benchmark suite (Benchmarks 1, 2, 3, and 5).

Usage:
    python3 tests/bench/suite.py --gitd-bin ./zig-out/bin/gitd --mode quick
    python3 tests/bench/suite.py --base http://127.0.0.1:8080 --key "$KEY" --mode full --oss-repos
"""

from __future__ import annotations

import argparse
import http.server
import io
import json
import os
import re
import shutil
import socketserver
import statistics
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.parse
import uuid
from pathlib import Path
from typing import Any

BENCH_DIR = Path(__file__).resolve().parent
if str(BENCH_DIR) not in sys.path:
    sys.path.insert(0, str(BENCH_DIR))

import common  # noqa: E402

OSS_REPO_SPECS = {
    "small": {"name": "ripgrep", "url": "https://github.com/BurntSushi/ripgrep.git"},
    "medium": {"name": "redis", "url": "https://github.com/redis/redis.git"},
    "large": {"name": "zig", "url": "https://github.com/ziglang/zig.git"},
}


# ---- Managed gitd process ----


class ManagedGitd:
    """Starts and tears down a local gitd server for benchmarking."""

    def __init__(self, bin_path: str, data_dir: str | None = None) -> None:
        self.bin_path = os.path.abspath(bin_path)
        self._owns_temp = data_dir is None
        self.work_dir = tempfile.mkdtemp(prefix="gitd-bench-srv-")
        self.data_dir = os.path.abspath(data_dir) if data_dir else os.path.join(self.work_dir, "data")
        os.makedirs(self.data_dir, exist_ok=True)
        self.log_path = os.path.join(self.work_dir, "server.log")
        self.proc: subprocess.Popen[str] | None = None
        self.log_file: Any = None
        self.base_url: str = ""
        self.admin_key: str = ""
        self.rss_mon: common.RssMonitor | None = None

    def start(self) -> None:
        key_res = subprocess.run(
            [self.bin_path, "admin", "create-key", "--data", self.data_dir],
            capture_output=True,
            text=True,
            check=True,
        )
        self.admin_key = key_res.stdout.strip().splitlines()[-1].strip()
        if not self.admin_key.startswith("gitd_k_"):
            raise RuntimeError(f"unexpected admin key output: {key_res.stdout!r}")

        self.log_file = open(self.log_path, "w+", encoding="utf-8", errors="replace")
        env = {
            **os.environ,
            "GITD_IDLE_TIMEOUT_SECONDS": "60",
            "GITD_HEAD_TIMEOUT_SECONDS": "15",
        }
        self.proc = subprocess.Popen(
            [self.bin_path, "serve", "--data", self.data_dir, "--listen", "127.0.0.1:0"],
            stdout=self.log_file,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )

        port: int | None = None
        deadline = time.monotonic() + 15.0
        pat = re.compile(r"listening on 127\.0\.0\.1:(\d+)")
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"gitd exited prematurely with {self.proc.returncode}:\n{self.read_log()}")
            text = self.read_log()
            m = pat.search(text)
            if m:
                port = int(m.group(1))
                break
            time.sleep(0.05)
        if port is None:
            raise RuntimeError(f"gitd failed to bind a port:\n{self.read_log()}")
        self.base_url = f"http://127.0.0.1:{port}"

        client = common.KeepAliveClient(self.base_url, no_keepalive=True)
        try:
            for _ in range(40):
                try:
                    code, _, _, _ = client.request_raw("GET", "/healthz")
                    if code == 200:
                        break
                except Exception:
                    time.sleep(0.05)
            else:
                raise RuntimeError(f"gitd /healthz did not become ready:\n{self.read_log()}")
        finally:
            client.close_all()

        self.rss_mon = common.RssMonitor(self.proc.pid)
        self.rss_mon.start()

    def read_log(self) -> str:
        try:
            with open(self.log_path, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def stop(self) -> tuple[dict[str, Any], list[str]]:
        rss_stats: dict[str, Any] = {"idle_mib": None, "peak_mib": None, "samples": 0}
        if self.rss_mon is not None:
            rss_stats = self.rss_mon.stop()
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None

        issues: list[str] = []
        log_text = self.read_log()
        for line in log_text.splitlines():
            low = line.lower()
            if "panic" in low or "leaked" in low or low.startswith("error:") or "error(" in low:
                issues.append(line)
        if self.proc is not None and self.proc.returncode not in (0, None):
            issues.append(f"server exited with code {self.proc.returncode}")

        shutil.rmtree(self.work_dir, ignore_errors=True)
        return rss_stats, issues


# ---- Fixture builders ----


def _blob_payload(file_idx: int, commit_idx: int, target: bool = False) -> bytes:
    lines = [
        f'"""Synthetic module {file_idx} rev {commit_idx}."""',
        "",
        "def compute_checksum(items: list[int]) -> int:",
        f"    acc = {file_idx + 17}",
        "    for idx, val in enumerate(items):",
        f"        acc = (acc * 31 + val + idx + {commit_idx}) & 0xFFFFFFFF",
        "    return acc",
        "",
    ]
    for j in range(14):
        lines.append(f"CONST_{file_idx}_{j} = {(file_idx * 13 + j * 7 + commit_idx) % 9973}")
    if target:
        lines.append("")
        lines.append('MARKER = "BENCH_TARGET_SYMBOL_42"')
        lines.append("def target_entry(x: int) -> int:")
        lines.append("    return compute_checksum([x, 42])")
    lines.append("")
    return "\n".join(lines).encode("utf-8")


def build_synthetic_repo(
    dest_dir: str,
    num_files: int,
    num_commits: int,
    *,
    subdir_name: str = "packages/core",
    needle: str = "BENCH_TARGET_SYMBOL_42",
) -> dict[str, Any]:
    """Create a packed git repo quickly using `git fast-import`."""
    os.makedirs(dest_dir, exist_ok=True)
    subprocess.run(
        ["git", "init", "-q", "--initial-branch=main", dest_dir],
        env=common.GIT_ENV,
        check=True,
    )
    target_path = f"{subdir_name}/src/target.py"

    other_count = max(1, num_files - 1)
    file_paths: list[str] = []
    for i in range(other_count):
        if i < max(4, min(20, other_count // 4)):
            file_paths.append(f"{subdir_name}/src/mod_{i:04d}.py")
        else:
            pkg = i % 16
            file_paths.append(f"packages/pkg_{pkg:02d}/src/mod_{i:04d}.py")

    stream = io.BytesIO()
    mark = 1

    def write_blob(data: bytes) -> int:
        nonlocal mark
        m = mark
        mark += 1
        stream.write(f"blob\nmark :{m}\ndata {len(data)}\n".encode("utf-8"))
        stream.write(data)
        stream.write(b"\n")
        return m

    base_ts = 1700000000
    initial_marks: list[tuple[str, int]] = []
    target_mark = write_blob(_blob_payload(0, 0, target=True))
    initial_marks.append((target_path, target_mark))
    for i, path in enumerate(file_paths):
        initial_marks.append((path, write_blob(_blob_payload(i + 1, 0, target=False))))

    msg0 = b"Initial import\n"
    c0_mark = mark
    mark += 1
    stream.write(
        (
            f"commit refs/heads/main\n"
            f"mark :{c0_mark}\n"
            f"author bench <bench@example.com> {base_ts} +0000\n"
            f"committer bench <bench@example.com> {base_ts} +0000\n"
            f"data {len(msg0)}\n"
        ).encode("utf-8")
    )
    stream.write(msg0)
    stream.write(b"\n")
    for path, bm in initial_marks:
        stream.write(f"M 100644 :{bm} {path}\n".encode("utf-8"))
    stream.write(b"\n")

    prev_commit = c0_mark
    for c_idx in range(1, num_commits):
        p1 = file_paths[(c_idx * 3) % len(file_paths)]
        p2 = file_paths[(c_idx * 3 + 1) % len(file_paths)]
        b1 = write_blob(_blob_payload((c_idx * 3) % len(file_paths) + 1, c_idx))
        b2 = write_blob(_blob_payload((c_idx * 3 + 1) % len(file_paths) + 1, c_idx))
        cm = mark
        mark += 1
        ts = base_ts + c_idx
        msg = f"Synthetic commit {c_idx}\n".encode("utf-8")
        stream.write(
            (
                f"commit refs/heads/main\n"
                f"mark :{cm}\n"
                f"author bench <bench@example.com> {ts} +0000\n"
                f"committer bench <bench@example.com> {ts} +0000\n"
                f"data {len(msg)}\n"
            ).encode("utf-8")
        )
        stream.write(msg)
        stream.write(f"\nfrom :{prev_commit}\n".encode("utf-8"))
        stream.write(f"M 100644 :{b1} {p1}\n".encode("utf-8"))
        if p2 != p1:
            stream.write(f"M 100644 :{b2} {p2}\n".encode("utf-8"))
        stream.write(b"\n")
        prev_commit = cm

    proc = subprocess.run(
        ["git", "-C", dest_dir, "fast-import", "--quiet"],
        input=stream.getvalue(),
        env=common.GIT_ENV,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git fast-import failed: {proc.stderr.decode(errors='replace')}")
    subprocess.run(["git", "-C", dest_dir, "gc", "-q"], env=common.GIT_ENV, check=True)
    return {
        "path": dest_dir,
        "target_path": target_path,
        "needle": needle,
        "subdir": subdir_name,
        "files": len(file_paths) + 1,
        "commits": num_commits,
        "source": "synthetic",
    }


def _find_oss_target_and_subdir(repo_dir: str) -> tuple[str, str, str, int, int]:
    """Select a real UTF-8 source file, unique identifier needle, and subdir from HEAD."""
    ls_out = subprocess.check_output(
        ["git", "-C", repo_dir, "ls-tree", "-r", "-l", "-z", "HEAD"],
        env=common.GIT_ENV,
    )
    entries: list[tuple[int, str]] = []
    dir_sizes: dict[str, int] = {}
    dir_counts: dict[str, int] = {}
    exts = (".rs", ".c", ".h", ".zig", ".py", ".go", ".ts", ".js", ".md")
    for rec in ls_out.split(b"\x00"):
        if not rec:
            continue
        meta, _, path_b = rec.partition(b"\t")
        parts = meta.decode("utf-8", errors="replace").split()
        if len(parts) < 4 or parts[1] != "blob":
            continue
        size = int(parts[3]) if parts[3].isdigit() else 0
        path = path_b.decode("utf-8", errors="replace")
        entries.append((size, path))
        segs = path.split("/")
        if len(segs) >= 2:
            top = segs[0]
            dir_sizes[top] = dir_sizes.get(top, 0) + size
            dir_counts[top] = dir_counts.get(top, 0) + 1
        if len(segs) >= 3:
            sub2 = f"{segs[0]}/{segs[1]}"
            dir_sizes[sub2] = dir_sizes.get(sub2, 0) + size
            dir_counts[sub2] = dir_counts.get(sub2, 0) + 1

    candidates = [
        (size, path)
        for size, path in entries
        if 2000 <= size <= 20000 and path.endswith(exts) and "/" in path
    ]
    candidates.sort(key=lambda x: (abs(x[0] - 6000), x[1]))

    target_path = ""
    needle = ""
    id_pat = re.compile(r"\b([A-Za-z][A-Za-z0-9_]{12,36})\b")
    for _, path in candidates[:60]:
        blob = subprocess.check_output(
            ["git", "-C", repo_dir, "show", f"HEAD:{path}"],
            env=common.GIT_ENV,
        )
        if b"\x00" in blob:
            continue
        text = blob.decode("utf-8", errors="replace")
        seen_tokens: list[str] = []
        for m in id_pat.finditer(text):
            tok = m.group(1)
            if tok not in seen_tokens:
                seen_tokens.append(tok)
            if len(seen_tokens) >= 12:
                break
        for tok in seen_tokens:
            g = subprocess.run(
                ["git", "-C", repo_dir, "grep", "-F", "-I", "-l", tok, "HEAD"],
                env=common.GIT_ENV,
                capture_output=True,
                text=True,
            )
            matched_files = [ln for ln in g.stdout.splitlines() if ln.strip()]
            if 1 <= len(matched_files) <= 15:
                target_path = path
                needle = tok
                break
        if target_path:
            break

    if not target_path:
        raise RuntimeError(f"could not pick target file and needle in {repo_dir}")

    subdir_candidates = [
        (dir_sizes[d], dir_counts[d], d)
        for d in dir_sizes
        if 50 * 1024 <= dir_sizes[d] <= 12 * 1024 * 1024 and dir_counts[d] >= 5
    ]
    if subdir_candidates:
        subdir_candidates.sort(key=lambda x: abs(x[0] - 1024 * 1024))
        subdir = subdir_candidates[0][2]
    else:
        subdir = target_path.rsplit("/", 1)[0]

    commits = int(
        subprocess.check_output(
            ["git", "-C", repo_dir, "rev-list", "--count", "HEAD"],
            env=common.GIT_ENV,
            text=True,
        ).strip()
    )
    return target_path, needle, subdir, len(entries), commits


def prepare_oss_repo(size_key: str, cache_dir: str) -> dict[str, Any]:
    spec = OSS_REPO_SPECS[size_key]
    dest = os.path.join(cache_dir, spec["name"])
    os.makedirs(cache_dir, exist_ok=True)
    if not os.path.exists(os.path.join(dest, "HEAD")):
        print(f"[b1] cloning OSS fixture {spec['name']} into {dest}...", flush=True)
        subprocess.run(
            ["git", "clone", "--bare", "--quiet", "--single-branch", spec["url"], dest],
            env=common.GIT_ENV,
            check=True,
            timeout=600,
        )
    target_path, needle, subdir, files, commits = _find_oss_target_and_subdir(dest)
    return {
        "path": dest,
        "target_path": target_path,
        "needle": needle,
        "subdir": subdir,
        "files": files,
        "commits": commits,
        "source": f"oss:{spec['name']}",
    }


def create_repo_and_token(
    client: common.KeepAliveClient,
    repo_name: str,
    *,
    scopes: list[str] | None = None,
    ttl_seconds: int = 3600,
    refs: list[str] | None = None,
    read_refs: list[str] | None = None,
    paths: list[str] | None = None,
    branch_ttl_seconds: int | None = None,
) -> str:
    code, out, _ = client.request_json("POST", "/v1/repos", body={"name": repo_name})
    if code != 201:
        raise RuntimeError(f"POST /v1/repos {repo_name} failed ({code}): {out}")
    return mint_token(
        client,
        repo_name,
        scopes=scopes or ["git:read", "git:write"],
        ttl_seconds=ttl_seconds,
        refs=refs,
        read_refs=read_refs,
        paths=paths,
        branch_ttl_seconds=branch_ttl_seconds,
    )


def mint_token(
    client: common.KeepAliveClient,
    repo_name: str,
    *,
    scopes: list[str],
    ttl_seconds: int = 3600,
    refs: list[str] | None = None,
    read_refs: list[str] | None = None,
    paths: list[str] | None = None,
    branch_ttl_seconds: int | None = None,
) -> str:
    tok, _ = mint_token_timed(
        client,
        repo_name,
        scopes=scopes,
        ttl_seconds=ttl_seconds,
        refs=refs,
        read_refs=read_refs,
        paths=paths,
        branch_ttl_seconds=branch_ttl_seconds,
    )
    return tok


def mint_token_timed(
    client: common.KeepAliveClient,
    repo_name: str,
    *,
    scopes: list[str],
    ttl_seconds: int = 3600,
    refs: list[str] | None = None,
    read_refs: list[str] | None = None,
    paths: list[str] | None = None,
    branch_ttl_seconds: int | None = None,
) -> tuple[str, float]:
    payload: dict[str, Any] = {
        "repo": repo_name,
        "scopes": scopes,
        "ttl_seconds": ttl_seconds,
    }
    if refs is not None:
        payload["refs"] = refs
    if read_refs is not None:
        payload["read_refs"] = read_refs
    if paths is not None:
        payload["paths"] = paths
    if branch_ttl_seconds is not None:
        payload["branch_ttl_seconds"] = branch_ttl_seconds
    code, out, ms = client.request_json("POST", "/v1/tokens", body=payload)
    if code != 201:
        raise RuntimeError(f"POST /v1/tokens failed ({code}): {out}")
    return out["token"], ms


def push_seed_to_gitd(base_url: str, token: str, repo_name: str, local_repo: str) -> None:
    remote_url = base_url.replace("://", f"://t:{token}@", 1) + f"/{repo_name}.git"
    res = subprocess.run(
        [
            "git",
            "-c",
            "http.postBuffer=524288000",
            "-C",
            local_repo,
            "push",
            "-q",
            remote_url,
            "HEAD:refs/heads/main",
        ],
        env=common.GIT_ENV,
        capture_output=True,
        text=True,
        timeout=600,
    )
    if res.returncode != 0:
        raise RuntimeError(f"seed push failed for {repo_name}: {res.stderr}")


def delete_repo_best_effort(client: common.KeepAliveClient, repo_name: str) -> None:
    try:
        client.request_raw("DELETE", f"/v1/repos/{repo_name}")
    except Exception:
        pass


def delete_branch_best_effort(client: common.KeepAliveClient, repo_name: str, branch: str) -> None:
    try:
        enc = "/".join(urllib.parse.quote(seg, safe="") for seg in branch.split("/"))
        client.request_raw("DELETE", f"/v1/repos/{repo_name}/branches/{enc}")
    except Exception:
        pass


# ---- Benchmark 1: Zero-Clone API Loop vs git clone -> edit -> push ----


def run_b1(
    admin: common.KeepAliveClient,
    base_url: str,
    *,
    mode: str,
    oss_repos: bool,
    oss_cache: str,
) -> dict[str, Any]:
    if mode == "quick":
        synth_sizes = {"small": (100, 20), "medium": (1500, 100), "large": (5000, 200)}
        counts = {"warmup": 2, "api": 8, "shallow": 3, "full": 2, "archive": 4}
    else:
        synth_sizes = {"small": (150, 100), "medium": (4000, 500), "large": (15000, 1000)}
        counts = {"warmup": 3, "api": 30, "shallow": 12, "full": 8, "archive": 10}

    results: list[dict[str, Any]] = []
    archive_results: list[dict[str, Any]] = []

    with tempfile.TemporaryDirectory(prefix="gitd-b1-fixtures-") as fix_tmp:
        for size_key in ("small", "medium", "large"):
            fixture: dict[str, Any] | None = None
            if oss_repos:
                try:
                    fixture = prepare_oss_repo(size_key, oss_cache)
                except Exception as exc:
                    print(f"[b1] warning: OSS fixture {size_key} unavailable ({exc}); falling back to synthetic", flush=True)
            if fixture is None:
                n_files, n_commits = synth_sizes[size_key]
                fixture = build_synthetic_repo(os.path.join(fix_tmp, size_key), n_files, n_commits)

            repo_name = f"bench/b1-{size_key}-{uuid.uuid4().hex[:8]}"
            print(
                f"[b1] {size_key} ({fixture['source']}, {fixture['files']} files, {fixture['commits']} commits)...",
                flush=True,
            )
            token = create_repo_and_token(admin, repo_name)
            push_seed_to_gitd(base_url, token, repo_name, fixture["path"])

            agent = common.KeepAliveClient(base_url, token)
            remote_url = base_url.replace("://", f"://t:{token}@", 1) + f"/{repo_name}.git"
            target_path = fixture["target_path"]
            enc_target = "/".join(urllib.parse.quote(seg, safe="") for seg in target_path.split("/"))
            q_needle = urllib.parse.quote(fixture["needle"], safe="")
            subdir = fixture["subdir"]

            api_total_ms: list[float] = []
            api_grep_ms: list[float] = []
            api_read_ms: list[float] = []
            api_commit_ms: list[float] = []

            total_api_iters = counts["warmup"] + counts["api"]
            for i in range(total_api_iters):
                branch = f"bench/api/{i}"
                t0 = time.perf_counter()
                c1, grep_res, g_ms = agent.request_json(
                    "GET", f"/v1/repos/{repo_name}/grep?q={q_needle}&ref=main&fixed=1&limit=50"
                )
                if c1 != 200 or not grep_res.get("matches"):
                    raise RuntimeError(f"b1 grep failed ({c1}): {grep_res}")
                c2, _, raw_file, r_ms = agent.request_raw(
                    "GET", f"/v1/repos/{repo_name}/files/{enc_target}?ref=main"
                )
                if c2 != 200:
                    raise RuntimeError(f"b1 file read failed ({c2})")
                updated_content = raw_file.decode("utf-8", errors="replace") + f"\n# bench api edit {i}\n"
                c3, _, cm_ms = agent.request_json(
                    "POST",
                    f"/v1/repos/{repo_name}/commits",
                    body={
                        "branch": branch,
                        "expected_head": None,
                        "from": "main",
                        "message": f"bench api edit {i}",
                        "changes": [{"path": target_path, "content": updated_content}],
                    },
                )
                if c3 != 201:
                    raise RuntimeError(f"b1 api commit failed ({c3})")
                total_ms = (time.perf_counter() - t0) * 1000.0
                delete_branch_best_effort(agent, repo_name, branch)
                if i >= counts["warmup"]:
                    api_total_ms.append(total_ms)
                    api_grep_ms.append(g_ms)
                    api_read_ms.append(r_ms)
                    api_commit_ms.append(cm_ms)

            def run_git_loop(depth_one: bool, iters: int) -> tuple[list[float], list[float], list[float], list[int]]:
                totals: list[float] = []
                clones: list[float] = []
                pushes: list[float] = []
                disks: list[int] = []
                for idx in range(iters):
                    branch = f"bench/{'shallow' if depth_one else 'full'}/{idx}"
                    with tempfile.TemporaryDirectory(prefix="gitd-b1-work-") as work:
                        clone_dir = os.path.join(work, "repo")
                        clone_cmd = ["git", "clone", "-q"]
                        if depth_one:
                            clone_cmd.extend(["--depth=1"])
                        clone_cmd.extend([remote_url, clone_dir])

                        t0 = time.perf_counter()
                        tc0 = time.perf_counter()
                        r_clone = subprocess.run(clone_cmd, env=common.GIT_ENV, capture_output=True, text=True)
                        if r_clone.returncode != 0:
                            raise RuntimeError(f"git clone failed: {r_clone.stderr}")
                        clone_ms = (time.perf_counter() - tc0) * 1000.0

                        r_grep = subprocess.run(
                            ["git", "-C", clone_dir, "grep", "-F", "-n", fixture["needle"]],
                            env=common.GIT_ENV,
                            capture_output=True,
                            text=True,
                        )
                        if r_grep.returncode != 0:
                            raise RuntimeError(f"git grep failed: {r_grep.stderr}")

                        fpath = os.path.join(clone_dir, target_path)
                        with open(fpath, "a", encoding="utf-8") as fh:
                            fh.write(f"\n# bench git edit {idx}\n")

                        subprocess.run(
                            ["git", "-C", clone_dir, "checkout", "-q", "-b", branch],
                            env=common.GIT_ENV,
                            check=True,
                        )
                        subprocess.run(
                            ["git", "-C", clone_dir, "add", target_path],
                            env=common.GIT_ENV,
                            check=True,
                        )
                        subprocess.run(
                            ["git", *common.GIT_ID, "-C", clone_dir, "commit", "-q", "-m", f"bench edit {idx}"],
                            env=common.GIT_ENV,
                            check=True,
                        )
                        tp0 = time.perf_counter()
                        r_push = subprocess.run(
                            ["git", "-C", clone_dir, "push", "-q", "origin", f"HEAD:refs/heads/{branch}"],
                            env=common.GIT_ENV,
                            capture_output=True,
                            text=True,
                        )
                        if r_push.returncode != 0:
                            raise RuntimeError(f"git push failed: {r_push.stderr}")
                        push_ms = (time.perf_counter() - tp0) * 1000.0
                        total_ms = (time.perf_counter() - t0) * 1000.0
                        disks.append(common.dir_size_bytes(clone_dir))
                        totals.append(total_ms)
                        clones.append(clone_ms)
                        pushes.append(push_ms)
                    delete_branch_best_effort(agent, repo_name, branch)
                return totals, clones, pushes, disks

            sh_tot, sh_clone, sh_push, sh_disks = run_git_loop(True, counts["shallow"])
            fu_tot, fu_clone, fu_push, fu_disks = run_git_loop(False, counts["full"])

            api_sum = common.summarize(api_total_ms)
            sh_sum = common.summarize(sh_tot)
            fu_sum = common.summarize(fu_tot)
            results.append(
                {
                    "size": size_key,
                    "source": fixture["source"],
                    "files": fixture["files"],
                    "commits": fixture["commits"],
                    "target_path": target_path,
                    "api_total_ms": api_sum,
                    "api_grep_ms": common.summarize(api_grep_ms),
                    "api_read_ms": common.summarize(api_read_ms),
                    "api_commit_ms": common.summarize(api_commit_ms),
                    "shallow_total_ms": sh_sum,
                    "shallow_clone_ms": common.summarize(sh_clone),
                    "shallow_push_ms": common.summarize(sh_push),
                    "shallow_disk_bytes": int(statistics.median(sh_disks)),
                    "full_total_ms": fu_sum,
                    "full_clone_ms": common.summarize(fu_clone),
                    "full_push_ms": common.summarize(fu_push),
                    "full_disk_bytes": int(statistics.median(fu_disks)),
                    "speedup_vs_shallow_p50": round(sh_sum["p50"] / max(0.01, api_sum["p50"]), 1),
                    "speedup_vs_full_p50": round(fu_sum["p50"] / max(0.01, api_sum["p50"]), 1),
                }
            )

            if size_key in ("medium", "large"):
                arch_ms: list[float] = []
                arch_wire_bytes: list[int] = []
                arch_disk_bytes: list[int] = []
                enc_sub = urllib.parse.quote(subdir, safe="")
                for _ in range(counts["archive"]):
                    with tempfile.TemporaryDirectory(prefix="gitd-b1-arch-") as tmp_arch:
                        t0 = time.perf_counter()
                        code, _, raw, _ = agent.request_raw(
                            "GET", f"/v1/repos/{repo_name}/archive?ref=main&format=tar.gz&path={enc_sub}"
                        )
                        if code != 200:
                            raise RuntimeError(f"archive failed ({code})")
                        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
                            if sys.version_info >= (3, 12):
                                tf.extractall(tmp_arch, filter="data")
                            else:
                                tf.extractall(tmp_arch)
                        elapsed = (time.perf_counter() - t0) * 1000.0
                        arch_ms.append(elapsed)
                        arch_wire_bytes.append(len(raw))
                        arch_disk_bytes.append(common.dir_size_bytes(tmp_arch))
                archive_results.append(
                    {
                        "size": size_key,
                        "subdir": subdir,
                        "archive_extract_ms": common.summarize(arch_ms),
                        "archive_wire_bytes": int(statistics.median(arch_wire_bytes)),
                        "archive_disk_bytes": int(statistics.median(arch_disk_bytes)),
                        "shallow_clone_ms": common.summarize(sh_clone),
                        "shallow_disk_bytes": int(statistics.median(sh_disks)),
                    }
                )

            agent.close_all()
            delete_repo_best_effort(admin, repo_name)

    return {"edit_loop": results, "subdir_archive": archive_results}


# ---- Benchmark 2: Multi-Agent Fan-Out & Fan-In ----


def run_b2(
    admin: common.KeepAliveClient,
    base_url: str,
    *,
    mode: str,
    rss_mon: common.RssMonitor | None,
) -> dict[str, Any]:
    if mode == "quick":
        agent_counts = [1, 8, 16]
        commits_per_agent = 5
    else:
        agent_counts = [1, 8, 16, 32, 64]
        commits_per_agent = 15

    out: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="gitd-b2-seed-") as tmp:
        seed_repo = build_synthetic_repo(os.path.join(tmp, "seed"), 500, 30)
        file_payload = ("# agent work line\n" * 170)[:3072]

        for n_agents in agent_counts:
            print(f"[b2] N={n_agents} agents x {commits_per_agent} commits...", flush=True)
            repo_name = f"bench/b2-n{n_agents}-{uuid.uuid4().hex[:8]}"
            admin_tok = create_repo_and_token(admin, repo_name)
            push_seed_to_gitd(base_url, admin_tok, repo_name, seed_repo["path"])

            agent_tokens: list[str] = []
            mint_lat: list[float] = []
            for i in range(n_agents):
                tok, ms = mint_token_timed(
                    admin,
                    repo_name,
                    scopes=["git:read", "git:write"],
                    refs=[f"refs/heads/agent/{i}/*"],
                    read_refs=["refs/heads/main", f"refs/heads/agent/{i}/*"],
                    branch_ttl_seconds=300,
                )
                agent_tokens.append(tok)
                mint_lat.append(ms)

            # Free all localhost sockets before launching up to 64 parallel agents.
            admin.close_all()
            time.sleep(0.2)

            barrier = threading.Barrier(n_agents)
            commit_lats: list[float] = []
            errors: list[str] = []
            lock = threading.Lock()

            def worker(idx: int, tok: str) -> None:
                client = common.KeepAliveClient(base_url, tok)
                try:
                    barrier.wait(timeout=30.0)
                    tip: str | None = None
                    for step in range(commits_per_agent):
                        body: dict[str, Any] = {
                            "branch": f"agent/{idx}/work",
                            "expected_head": tip,
                            "message": f"agent {idx} step {step}",
                            "changes": [{"path": f"agent/{idx}/work.py", "content": f"# step {step}\n{file_payload}"}],
                        }
                        if tip is None:
                            body["from"] = "main"
                        code, resp, ms = client.request_json(
                            "POST", f"/v1/repos/{repo_name}/commits", body=body
                        )
                        if code != 201:
                            with lock:
                                errors.append(f"agent {idx} step {step}: HTTP {code} {resp}")
                            return
                        tip = resp["sha"]
                        with lock:
                            commit_lats.append(ms)
                except Exception as exc:
                    with lock:
                        errors.append(f"agent {idx} exc: {exc}")
                finally:
                    client.close_all()

            threads = [
                threading.Thread(target=worker, args=(i, agent_tokens[i])) for i in range(n_agents)
            ]
            t_start = time.perf_counter()
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            wall_s = time.perf_counter() - t_start
            if errors:
                raise RuntimeError(f"b2 N={n_agents} failed: {errors[:3]}")
            if rss_mon is not None:
                rss_mon.sample_now()

            time.sleep(0.05)
            compare_lats: list[float] = []
            for i in range(n_agents):
                code, _, ms = admin.request_json(
                    "GET", f"/v1/repos/{repo_name}/compare/main...agent/{i}/work"
                )
                if code != 200:
                    raise RuntimeError(f"compare failed ({code}) for agent/{i}/work")
                compare_lats.append(ms)

            code, merge_resp, merge_ms = admin.request_json(
                "POST",
                f"/v1/repos/{repo_name}/merges",
                body={"base": "main", "head": "agent/0/work", "strategy": "merge"},
            )
            if code not in (200, 201):
                raise RuntimeError(f"merge failed ({code}): {merge_resp}")

            out.append(
                {
                    "agents": n_agents,
                    "commits_per_agent": commits_per_agent,
                    "total_commits": n_agents * commits_per_agent,
                    "wall_s": round(wall_s, 3),
                    "commits_per_sec": round((n_agents * commits_per_agent) / max(0.001, wall_s), 1),
                    "token_mint_ms": common.summarize(mint_lat),
                    "commit_ms": common.summarize(commit_lats),
                    "compare_ms": common.summarize(compare_lats),
                    "merge_ms": round(merge_ms, 2),
                    "peak_rss_mib": rss_mon.peak_mib if rss_mon else None,
                }
            )
            delete_repo_best_effort(admin, repo_name)

    reap_count = max(agent_counts)
    reap_ttl = 2
    print(f"[b2] reaper burst: {reap_count} ephemeral branches (ttl={reap_ttl}s)...", flush=True)
    reap_repo = f"bench/b2-reap-{uuid.uuid4().hex[:8]}"
    create_repo_and_token(admin, reap_repo)
    c_seed, seed_out, _ = admin.request_json(
        "POST",
        f"/v1/repos/{reap_repo}/commits",
        body={
            "branch": "main",
            "expected_head": None,
            "message": "seed main",
            "changes": [{"path": "README.md", "content": "reaper bench\n"}],
        },
    )
    if c_seed != 201:
        raise RuntimeError(f"b2 reaper seed failed ({c_seed}): {seed_out}")

    for i in range(reap_count):
        c_br, br_out, _ = admin.request_json(
            "POST",
            f"/v1/repos/{reap_repo}/branches",
            body={"name": f"ephem/{i}", "from": "main", "ttl_seconds": reap_ttl},
        )
        if c_br != 201:
            raise RuntimeError(f"b2 create branch ephem/{i} failed ({c_br}): {br_out}")

    ttl_due = time.perf_counter() + reap_ttl
    reap_deadline = ttl_due + 30.0
    drain_after_ttl_s: float | None = None
    while time.perf_counter() < reap_deadline:
        code, b_out, _ = admin.request_json("GET", f"/v1/repos/{reap_repo}/branches")
        if code == 200:
            names = [b["name"] for b in b_out.get("branches", [])]
            if names == ["main"]:
                drain_after_ttl_s = round(max(0.0, time.perf_counter() - ttl_due), 2)
                break
        time.sleep(0.15)
    delete_repo_best_effort(admin, reap_repo)
    if drain_after_ttl_s is None:
        raise RuntimeError(f"b2 reaper did not drain {reap_count} branches within timeout")

    reaper_stats = {
        "branches": reap_count,
        "ttl_seconds": reap_ttl,
        "drain_after_ttl_s": drain_after_ttl_s,
    }
    return {"sweep": out, "reaper": reaper_stats}


# ---- Benchmark 3: CAS Contention Storm on main ----


def run_b3(admin: common.KeepAliveClient, base_url: str, *, mode: str) -> list[dict[str, Any]]:
    if mode == "quick":
        agent_counts = [8, 16]
        commits_per_agent = 3
    else:
        agent_counts = [8, 16, 32]
        commits_per_agent = 5

    out: list[dict[str, Any]] = []
    for n_agents in agent_counts:
        print(f"[b3] N={n_agents} agents racing on main ({commits_per_agent} commits each)...", flush=True)
        repo_name = f"bench/b3-n{n_agents}-{uuid.uuid4().hex[:8]}"
        tok = create_repo_and_token(admin, repo_name)
        code, init_out, _ = admin.request_json(
            "POST",
            f"/v1/repos/{repo_name}/commits",
            body={
                "branch": "main",
                "expected_head": None,
                "message": "seed main",
                "changes": [{"path": "README.md", "content": "CAS bench\n"}],
            },
        )
        if code != 201:
            raise RuntimeError(f"b3 seed failed ({code}): {init_out}")
        initial_head = init_out["sha"]

        admin.close_all()
        time.sleep(0.05)

        barrier = threading.Barrier(n_agents)
        win_ms: list[float] = []
        conflict_ms: list[float] = []
        retries_per_commit: list[int] = []
        expected_files: dict[str, bytes] = {}
        errors: list[str] = []
        lock = threading.Lock()

        def racer(idx: int) -> None:
            client = common.KeepAliveClient(base_url, tok)
            try:
                barrier.wait(timeout=30.0)
                head = initial_head
                for step in range(commits_per_agent):
                    path = f"results/a{idx:02d}-s{step:02d}.txt"
                    content_str = f"agent={idx} step={step}\n"
                    retries = 0
                    while True:
                        c, resp, ms = client.request_json(
                            "POST",
                            f"/v1/repos/{repo_name}/commits",
                            body={
                                "branch": "main",
                                "expected_head": head,
                                "message": f"race a{idx} s{step}",
                                "changes": [{"path": path, "content": content_str}],
                            },
                        )
                        if c == 201:
                            with lock:
                                win_ms.append(ms)
                                retries_per_commit.append(retries)
                                expected_files[path] = content_str.encode("utf-8")
                            head = resp["sha"]
                            break
                        if c == 409:
                            err_code = (resp.get("error") or {}).get("code")
                            cur_head = resp.get("current_head")
                            if err_code != "stale_head" or not isinstance(cur_head, str):
                                with lock:
                                    errors.append(f"unexpected 409 payload: {resp}")
                                return
                            with lock:
                                conflict_ms.append(ms)
                            retries += 1
                            head = cur_head
                            continue
                        with lock:
                            errors.append(f"agent {idx} step {step}: HTTP {c} {resp}")
                        return
            except Exception as exc:
                with lock:
                    errors.append(f"agent {idx} exc: {exc}")
            finally:
                client.close_all()

        threads = [threading.Thread(target=racer, args=(i,)) for i in range(n_agents)]
        t_start = time.perf_counter()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        wall_s = time.perf_counter() - t_start
        if errors:
            raise RuntimeError(f"b3 N={n_agents} failed: {errors[:3]}")

        time.sleep(0.05)
        expected_total = n_agents * commits_per_agent
        c_log, log_out, _ = admin.request_json(
            "GET", f"/v1/repos/{repo_name}/log?ref=main&limit=500"
        )
        if c_log != 200:
            raise RuntimeError(f"b3 log check failed ({c_log})")
        landed_commits = len(log_out.get("commits", [])) - 1

        c_arch, _, tar_bytes, _ = admin.request_raw(
            "GET", f"/v1/repos/{repo_name}/archive?ref=main&format=tar&path=results"
        )
        if c_arch != 200:
            raise RuntimeError(f"b3 archive check failed ({c_arch})")
        found_files: dict[str, bytes] = {}
        with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
            for member in tf.getmembers():
                if member.isfile():
                    fobj = tf.extractfile(member)
                    if fobj is not None:
                        found_files[member.name] = fobj.read()

        lost_updates = sum(1 for p in expected_files if p not in found_files)
        corrupted = sum(1 for p, b in expected_files.items() if found_files.get(p) != b)
        if landed_commits != expected_total or lost_updates != 0 or corrupted != 0:
            raise RuntimeError(
                f"b3 integrity failure: expected={expected_total}, landed={landed_commits}, "
                f"lost={lost_updates}, corrupted={corrupted}"
            )

        out.append(
            {
                "agents": n_agents,
                "commits_per_agent": commits_per_agent,
                "expected_commits": expected_total,
                "verified_commits": landed_commits,
                "lost_updates": lost_updates,
                "corrupted_files": corrupted,
                "total_conflicts": len(conflict_ms),
                "win_ms": common.summarize(win_ms),
                "conflict_ms": common.summarize(conflict_ms),
                "retries": common.summarize([float(r) for r in retries_per_commit]),
                "wall_s": round(wall_s, 3),
                "landed_commits_per_sec": round(expected_total / max(0.001, wall_s), 1),
            }
        )
        delete_repo_best_effort(admin, repo_name)

    return out


# ---- Benchmark 5: Smart HTTP Proxy Overhead, Guardrails & Multi-File Curve ----


class BareGitHttpServer:
    """Minimal HTTP/1.1 wrapper around `git http-backend` for baseline timing."""

    def __init__(self, project_root: str) -> None:
        self.project_root = project_root
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self.port: int = 0

    def start(self) -> str:
        root = self.project_root

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                return

            def _read_body(self) -> bytes:
                te = (self.headers.get("Transfer-Encoding") or "").lower()
                if "chunked" in te:
                    chunks = bytearray()
                    while True:
                        line = self.rfile.readline()
                        if not line:
                            break
                        size = int(line.split(b";", 1)[0].strip(), 16)
                        if size == 0:
                            while True:
                                trailer = self.rfile.readline()
                                if trailer in (b"\r\n", b"\n", b""):
                                    break
                            break
                        chunks.extend(self.rfile.read(size))
                        self.rfile.read(2)
                    return bytes(chunks)
                cl = int(self.headers.get("Content-Length") or "0")
                return self.rfile.read(cl) if cl > 0 else b""

            def _handle_cgi(self) -> None:
                parsed = urllib.parse.urlsplit(self.path)
                body = self._read_body()
                env = {
                    **common.GIT_ENV,
                    "GIT_PROJECT_ROOT": root,
                    "GIT_HTTP_EXPORT_ALL": "1",
                    "PATH_INFO": parsed.path,
                    "QUERY_STRING": parsed.query,
                    "REQUEST_METHOD": self.command,
                    "REMOTE_USER": "bench",
                }
                if self.headers.get("Content-Type"):
                    env["CONTENT_TYPE"] = self.headers["Content-Type"]
                if self.headers.get("Content-Encoding"):
                    env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
                if self.headers.get("Git-Protocol"):
                    env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
                if self.command == "POST":
                    env["CONTENT_LENGTH"] = str(len(body))

                proc = subprocess.run(
                    ["git", "http-backend"],
                    input=body,
                    env=env,
                    capture_output=True,
                )
                raw = proc.stdout
                sep = raw.find(b"\r\n\r\n")
                sep_len = 4
                if sep == -1:
                    sep = raw.find(b"\n\n")
                    sep_len = 2
                if sep == -1:
                    self.send_response(500)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                head_bytes = raw[:sep].decode("latin1")
                resp_body = raw[sep + sep_len :]
                status = 200
                out_headers: list[tuple[str, str]] = []
                for line in head_bytes.splitlines():
                    if ":" not in line:
                        continue
                    k, v = line.split(":", 1)
                    k = k.strip()
                    v = v.strip()
                    if k.lower() == "status":
                        status = int(v.split()[0])
                    else:
                        out_headers.append((k, v))
                self.send_response(status)
                for k, v in out_headers:
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(resp_body)))
                self.end_headers()
                self.wfile.write(resp_body)

            def do_GET(self) -> None:
                self._handle_cgi()

            def do_POST(self) -> None:
                self._handle_cgi()

        class _Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        self._httpd = _Server(("127.0.0.1", 0), Handler)
        self.port = int(self._httpd.server_address[1])
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return f"http://127.0.0.1:{self.port}"

    def stop(self) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None


def _make_payload_text(size_bytes: int, salt: int) -> str:
    # Mix deterministic pseudo-random hex words so git pack compression cannot collapse it to 0 bytes.
    chunks: list[str] = []
    state = (salt + 1) * 0x9E3779B97F4A7C15
    written = 0
    while written < size_bytes:
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        line = f"{state:016x}-{(state >> 17) ^ salt:016x}\n"
        chunks.append(line)
        written += len(line)
    return "".join(chunks)[:size_bytes]


def run_b5(admin: common.KeepAliveClient, base_url: str, *, mode: str) -> dict[str, Any]:
    if mode == "quick":
        clone_iters = 3
        push_iters = 3
        acl_iters = 10
        reject_iters = 3
        multifile_iters = 3
        revoked_count = 30
    else:
        clone_iters = 10
        push_iters = 10
        acl_iters = 40
        reject_iters = 10
        multifile_iters = 10
        revoked_count = 100

    # ---- 5a: Smart HTTP proxy overhead ----
    with tempfile.TemporaryDirectory(prefix="gitd-b5a-") as tmp:
        seed_repo = build_synthetic_repo(os.path.join(tmp, "seed"), 400, 30)
        bare_root = os.path.join(tmp, "bare_root")
        os.makedirs(bare_root, exist_ok=True)
        bare_repo = os.path.join(bare_root, "bare.git")
        subprocess.run(
            ["git", "clone", "--bare", "-q", seed_repo["path"], bare_repo],
            env=common.GIT_ENV,
            check=True,
        )
        subprocess.run(
            ["git", "-C", bare_repo, "config", "http.receivepack", "true"],
            env=common.GIT_ENV,
            check=True,
        )
        subprocess.run(
            ["git", "-C", bare_repo, "config", "http.uploadpack", "true"],
            env=common.GIT_ENV,
            check=True,
        )

        bare_srv = BareGitHttpServer(bare_root)
        bare_base = bare_srv.start()
        bare_url = f"{bare_base}/bare.git"

        repo_name = f"bench/b5a-{uuid.uuid4().hex[:8]}"
        tok = create_repo_and_token(admin, repo_name)
        push_seed_to_gitd(base_url, tok, repo_name, seed_repo["path"])
        gitd_url = base_url.replace("://", f"://t:{tok}@", 1) + f"/{repo_name}.git"

        try:
            def time_clones(url: str) -> list[float]:
                lats: list[float] = []
                for idx in range(clone_iters):
                    with tempfile.TemporaryDirectory(prefix="gitd-b5-cl-") as ctmp:
                        t0 = time.perf_counter()
                        r = subprocess.run(
                            ["git", "clone", "-q", url, os.path.join(ctmp, f"c{idx}")],
                            env=common.GIT_ENV,
                            capture_output=True,
                            text=True,
                        )
                        if r.returncode != 0:
                            raise RuntimeError(f"clone {url} failed: {r.stderr}")
                        lats.append((time.perf_counter() - t0) * 1000.0)
                return lats

            gitd_clone_ms = time_clones(gitd_url)
            bare_clone_ms = time_clones(bare_url)

            def time_pushes(url: str, size_bytes: int, prefix: str) -> list[float]:
                lats: list[float] = []
                with tempfile.TemporaryDirectory(prefix="gitd-b5-ps-") as ptmp:
                    cdir = os.path.join(ptmp, "work")
                    subprocess.run(
                        ["git", "clone", "-q", url, cdir],
                        env=common.GIT_ENV,
                        check=True,
                    )
                    for idx in range(push_iters):
                        blob_path = os.path.join(cdir, "payload.dat")
                        with open(blob_path, "w", encoding="utf-8") as f:
                            f.write(_make_payload_text(size_bytes, idx + size_bytes))
                        subprocess.run(["git", "-C", cdir, "add", "payload.dat"], env=common.GIT_ENV, check=True)
                        subprocess.run(
                            ["git", *common.GIT_ID, "-C", cdir, "commit", "-q", "-m", f"push {size_bytes} #{idx}"],
                            env=common.GIT_ENV,
                            check=True,
                        )
                        t0 = time.perf_counter()
                        r = subprocess.run(
                            [
                                "git",
                                "-c",
                                "http.postBuffer=52428800",
                                "-C",
                                cdir,
                                "push",
                                "-q",
                                "origin",
                                f"HEAD:refs/heads/{prefix}-{idx}",
                            ],
                            env=common.GIT_ENV,
                            capture_output=True,
                            text=True,
                        )
                        if r.returncode != 0:
                            raise RuntimeError(f"push {url} failed: {r.stderr}")
                        lats.append((time.perf_counter() - t0) * 1000.0)
                return lats

            push_rows: list[dict[str, Any]] = []
            for label, sz in (("10 KiB", 10 * 1024), ("250 KiB", 250 * 1024), ("2 MiB", 2 * 1024 * 1024)):
                g_ms = time_pushes(gitd_url, sz, f"g-{sz}")
                b_ms = time_pushes(bare_url, sz, f"b-{sz}")
                gs = common.summarize(g_ms)
                bs = common.summarize(b_ms)
                push_rows.append(
                    {
                        "payload": label,
                        "payload_bytes": sz,
                        "gitd_ms": gs,
                        "bare_ms": bs,
                        "overhead_p50_ms": round(gs["p50"] - bs["p50"], 2),
                    }
                )
        finally:
            bare_srv.stop()
            delete_repo_best_effort(admin, repo_name)

        g_cl = common.summarize(gitd_clone_ms)
        b_cl = common.summarize(bare_clone_ms)
        proxy_overhead = {
            "clone": {
                "gitd_ms": g_cl,
                "bare_ms": b_cl,
                "overhead_p50_ms": round(g_cl["p50"] - b_cl["p50"], 2),
            },
            "pushes": push_rows,
        }

    # ---- 5b: Pre-write rejection & scoping overhead ----
    with tempfile.TemporaryDirectory(prefix="gitd-b5b-") as tmp:
        seed_repo = build_synthetic_repo(os.path.join(tmp, "seed"), 200, 15, subdir_name="src")
        repo_name = f"bench/b5b-{uuid.uuid4().hex[:8]}"
        admin_tok = create_repo_and_token(admin, repo_name)
        push_seed_to_gitd(base_url, admin_tok, repo_name, seed_repo["path"])

        c_lock, _, _ = admin.request_json(
            "PUT",
            f"/v1/repos/{repo_name}/branches/main/lock",
            body={"reason": "bench lock"},
        )
        if c_lock != 200:
            raise RuntimeError(f"branch lock failed ({c_lock})")

        for _ in range(revoked_count):
            c_t, t_out, _ = admin.request_json(
                "POST",
                "/v1/tokens",
                body={"repo": repo_name, "scopes": ["git:read"], "ttl_seconds": 600},
            )
            if c_t != 201:
                raise RuntimeError(f"mint for revoke failed ({c_t})")
            c_r, _, _, _ = admin.request_raw("POST", f"/v1/tokens/{t_out['jti']}/revoke")
            if c_r != 204:
                raise RuntimeError(f"revoke failed ({c_r})")

        scoped_api_tok = mint_token(
            admin,
            repo_name,
            scopes=["git:read", "git:write"],
            refs=["refs/heads/agent/1/*"],
            read_refs=["refs/heads/main", "refs/heads/agent/1/*"],
            paths=["src/*", "README.md"],
        )
        scoped_git_tok = mint_token(
            admin,
            repo_name,
            scopes=["git:read", "git:write"],
            refs=["refs/heads/agent/1/*"],
            read_refs=["refs/heads/main", "refs/heads/agent/1/*"],
        )

        scoped_client = common.KeepAliveClient(base_url, scoped_api_tok)
        enc_target = "/".join(urllib.parse.quote(s, safe="") for s in seed_repo["target_path"].split("/"))
        q_needle = urllib.parse.quote(seed_repo["needle"], safe="")

        def measure_api_op(client: common.KeepAliveClient, branch_prefix: str) -> dict[str, Any]:
            read_ms: list[float] = []
            grep_ms: list[float] = []
            commit_ms: list[float] = []
            tip: str | None = None
            for i in range(acl_iters):
                c1, _, _, m1 = client.request_raw(
                    "GET", f"/v1/repos/{repo_name}/files/{enc_target}?ref=main"
                )
                if c1 != 200:
                    raise RuntimeError(f"5b file read failed ({c1})")
                read_ms.append(m1)

                c2, _, m2 = client.request_json(
                    "GET", f"/v1/repos/{repo_name}/grep?q={q_needle}&ref=main&fixed=1"
                )
                if c2 != 200:
                    raise RuntimeError(f"5b grep failed ({c2})")
                grep_ms.append(m2)

                body: dict[str, Any] = {
                    "branch": f"agent/1/{branch_prefix}",
                    "expected_head": tip,
                    "message": f"acl {i}",
                    "changes": [{"path": "src/bench_edit.py", "content": f"x = {i}\n"}],
                }
                if tip is None:
                    body["from"] = "main"
                c3, out3, m3 = client.request_json(
                    "POST", f"/v1/repos/{repo_name}/commits", body=body
                )
                if c3 != 201:
                    raise RuntimeError(f"5b commit failed ({c3}): {out3}")
                tip = out3["sha"]
                commit_ms.append(m3)
            return {
                "read_file_ms": common.summarize(read_ms),
                "grep_ms": common.summarize(grep_ms),
                "commit_ms": common.summarize(commit_ms),
            }

        admin_ops = measure_api_op(admin, "admin")
        scoped_ops = measure_api_op(scoped_client, "scoped")
        scoped_client.close_all()

        # Unauthorized 5 MiB push to main must be rejected before git modifies refs.
        _, br_before, _ = admin.request_json("GET", f"/v1/repos/{repo_name}/branches")
        main_before = [b["commit"] for b in br_before["branches"] if b["name"] == "main"][0]
        scoped_git_url = base_url.replace("://", f"://t:{scoped_git_tok}@", 1) + f"/{repo_name}.git"
        reject_ms: list[float] = []
        with tempfile.TemporaryDirectory(prefix="gitd-b5-rej-") as rtmp:
            rdir = os.path.join(rtmp, "work")
            subprocess.run(["git", "clone", "-q", scoped_git_url, rdir], env=common.GIT_ENV, check=True)
            with open(os.path.join(rdir, "big_5mb.dat"), "w", encoding="utf-8") as f:
                f.write(_make_payload_text(5 * 1024 * 1024, 99))
            subprocess.run(["git", "-C", rdir, "add", "big_5mb.dat"], env=common.GIT_ENV, check=True)
            subprocess.run(
                ["git", *common.GIT_ID, "-C", rdir, "commit", "-q", "-m", "unauthorized 5MiB push"],
                env=common.GIT_ENV,
                check=True,
            )
            for _ in range(reject_iters):
                t0 = time.perf_counter()
                r = subprocess.run(
                    [
                        "git",
                        "-c",
                        "http.postBuffer=52428800",
                        "-C",
                        rdir,
                        "push",
                        "-q",
                        "origin",
                        "HEAD:refs/heads/main",
                    ],
                    env=common.GIT_ENV,
                    capture_output=True,
                    text=True,
                )
                elapsed = (time.perf_counter() - t0) * 1000.0
                if r.returncode == 0:
                    raise RuntimeError("unauthorized push to main unexpectedly succeeded")
                reject_ms.append(elapsed)

        _, br_after, _ = admin.request_json("GET", f"/v1/repos/{repo_name}/branches")
        main_after = [b["commit"] for b in br_after["branches"] if b["name"] == "main"][0]
        if main_before != main_after:
            raise RuntimeError("main moved after rejected push")

        guardrails = {
            "revoked_tokens_seeded": revoked_count,
            "admin_key_ms": admin_ops,
            "scoped_token_ms": scoped_ops,
            "rejected_5mib_push_ms": common.summarize(reject_ms),
            "main_unchanged": True,
        }
        delete_repo_best_effort(admin, repo_name)

    # ---- 5c: Multi-file commit scaling (1 -> 100 files) ----
    repo_name = f"bench/b5c-{uuid.uuid4().hex[:8]}"
    create_repo_and_token(admin, repo_name)
    file_blob = ("# multi-file commit payload\n" * 80)[:2048]
    multifile_rows: list[dict[str, Any]] = []
    tip: str | None = None
    for n_files in (1, 5, 20, 50, 100):
        lats: list[float] = []
        for idx in range(multifile_iters):
            changes = [
                {"path": f"batch/f_{k:03d}.txt", "content": f"batch={n_files} iter={idx} idx={k}\n{file_blob}"}
                for k in range(n_files)
            ]
            body: dict[str, Any] = {
                "branch": "main",
                "expected_head": tip,
                "message": f"commit {n_files} files #{idx}",
                "changes": changes,
            }
            c, out_c, ms = admin.request_json(
                "POST", f"/v1/repos/{repo_name}/commits", body=body
            )
            if c != 201:
                raise RuntimeError(f"5c {n_files}-file commit failed ({c}): {out_c}")
            tip = out_c["sha"]
            lats.append(ms)
        st = common.summarize(lats)
        multifile_rows.append(
            {
                "files": n_files,
                "commit_ms": st,
                "ms_per_file_p50": round(st["p50"] / n_files, 2),
            }
        )
    delete_repo_best_effort(admin, repo_name)

    return {
        "proxy_overhead": proxy_overhead,
        "guardrails": guardrails,
        "multifile_commits": multifile_rows,
    }


# ---- Markdown rendering ----


def render_markdown(report: dict[str, Any]) -> str:
    sysinfo = report["sysinfo"]
    parts: list[str] = ["# gitd Benchmark Report", ""]
    parts.append(
        f"- **Mode:** `{report['mode']}`  "
        f"**Timestamp:** {sysinfo['timestamp_utc']}  "
        f"**OS:** `{sysinfo['os']} ({sysinfo['arch']})`  "
        f"**CPU:** {sysinfo['cpu_model']} ({sysinfo['cpu_count']} vCPU)  "
        f"**RAM:** {sysinfo['ram_gib']} GiB  "
        f"**git:** {sysinfo['git_version']}"
    )
    if sysinfo.get("disk_fs"):
        parts.append(f"- **Disk / FS:** `{sysinfo['disk_fs']}`")
    if sysinfo.get("gitd_bin_bytes"):
        parts.append(f"- **gitd binary size:** {common.format_bytes(sysinfo['gitd_bin_bytes'])}")
    rss = report.get("rss") or {}
    if rss.get("idle_mib") is not None:
        parts.append(f"- **gitd RSS:** idle `{rss['idle_mib']} MiB`, peak `{rss['peak_mib']} MiB`")
    parts.append("")

    if "b1_zero_clone" in report:
        b1 = report["b1_zero_clone"]
        parts.extend(["## 1. Zero-Clone API Loop vs. `git clone` -> Edit -> `git push`", ""])
        rows = []
        for r in b1["edit_loop"]:
            rows.append(
                [
                    f"{r['size']} ({r['source']}, {r['files']} files)",
                    common.format_ms(r["api_total_ms"]["p50"]),
                    common.format_ms(r["api_total_ms"]["p95"]),
                    common.format_ms(r["shallow_total_ms"]["p50"]),
                    common.format_ms(r["full_total_ms"]["p50"]),
                    f"{r['speedup_vs_shallow_p50']}x / {r['speedup_vs_full_p50']}x",
                    f"0 B / {common.format_bytes(r['shallow_disk_bytes'])}",
                ]
            )
        parts.append(
            common.markdown_table(
                ["Repo Size", "API p50", "API p95", "Shallow p50", "Full p50", "Speedup (vs Shallow / Full)", "Disk (API / Shallow)"],
                rows,
            )
        )
        parts.append("")
        if b1.get("subdir_archive"):
            parts.extend(["### Subdirectory Archive (`GET /archive?path=...`) vs. Shallow Clone", ""])
            arows = []
            for a in b1["subdir_archive"]:
                arows.append(
                    [
                        f"{a['size']} (`{a['subdir']}`)",
                        common.format_ms(a["archive_extract_ms"]["p50"]),
                        common.format_bytes(a["archive_wire_bytes"]),
                        common.format_ms(a["shallow_clone_ms"]["p50"]),
                        common.format_bytes(a["shallow_disk_bytes"]),
                    ]
                )
            parts.append(
                common.markdown_table(
                    ["Repo / Subdir", "Archive+Extract p50", "Archive Wire", "Shallow Clone p50", "Shallow Disk"],
                    arows,
                )
            )
            parts.append("")

    if "b2_fanout_fanin" in report:
        b2 = report["b2_fanout_fanin"]
        parts.extend(["## 2. Multi-Agent Fan-Out & Fan-In Concurrency Scaling", ""])
        rows = []
        for r in b2["sweep"]:
            rss_s = f"{r['peak_rss_mib']} MiB" if r["peak_rss_mib"] is not None else "-"
            rows.append(
                [
                    r["agents"],
                    r["total_commits"],
                    f"{r['commits_per_sec']}/s",
                    common.format_ms(r["commit_ms"]["p50"]),
                    common.format_ms(r["commit_ms"]["p95"]),
                    common.format_ms(r["commit_ms"]["p99"]),
                    common.format_ms(r["compare_ms"]["p50"]),
                    common.format_ms(r["merge_ms"]),
                    rss_s,
                ]
            )
        parts.append(
            common.markdown_table(
                ["Agents", "Commits", "Throughput", "Commit p50", "Commit p95", "Commit p99", "Compare p50", "Merge", "Peak RSS"],
                rows,
            )
        )
        reaper = b2["reaper"]
        parts.append("")
        parts.append(
            f"Branch expiry reaper: drained **{reaper['branches']}** expired branches in "
            f"**{reaper['drain_after_ttl_s']} s** after {reaper['ttl_seconds']}s TTL."
        )
        parts.append("")

    if "b3_cas_race" in report:
        parts.extend(["## 3. CAS Contention Storm on `main`", ""])
        rows = []
        for r in report["b3_cas_race"]:
            rows.append(
                [
                    r["agents"],
                    f"{r['verified_commits']}/{r['expected_commits']}",
                    r["lost_updates"],
                    r["total_conflicts"],
                    common.format_ms(r["win_ms"]["p50"]),
                    common.format_ms(r["conflict_ms"]["p50"]) if r["total_conflicts"] else "-",
                    f"{r['retries']['p50']} / {int(r['retries']['max'])}",
                    f"{r['landed_commits_per_sec']}/s",
                ]
            )
        parts.append(
            common.markdown_table(
                ["Agents", "Verified Commits", "Lost Updates", "409 Conflicts", "201 p50", "409 p50", "Retries (p50/max)", "Landed Rate"],
                rows,
            )
        )
        parts.append("")

    if "b5_proxy_guardrails_limits" in report:
        b5 = report["b5_proxy_guardrails_limits"]
        parts.extend(["## 5. Smart HTTP Overhead, Guardrails & Multi-File Curve", ""])
        p_rows = [
            [
                "git clone",
                common.format_ms(b5["proxy_overhead"]["clone"]["gitd_ms"]["p50"]),
                common.format_ms(b5["proxy_overhead"]["clone"]["bare_ms"]["p50"]),
                f"{b5['proxy_overhead']['clone']['overhead_p50_ms']:+.1f} ms",
            ]
        ]
        for pr in b5["proxy_overhead"]["pushes"]:
            p_rows.append(
                [
                    f"git push ({pr['payload']})",
                    common.format_ms(pr["gitd_ms"]["p50"]),
                    common.format_ms(pr["bare_ms"]["p50"]),
                    f"{pr['overhead_p50_ms']:+.1f} ms",
                ]
            )
        parts.append(common.markdown_table(["Git Op", "gitd p50", "Bare http-backend p50", "Delta"], p_rows))
        parts.append("")

        g = b5["guardrails"]
        g_rows = [
            [
                "read_file",
                common.format_ms(g["admin_key_ms"]["read_file_ms"]["p50"]),
                common.format_ms(g["scoped_token_ms"]["read_file_ms"]["p50"]),
            ],
            [
                "grep",
                common.format_ms(g["admin_key_ms"]["grep_ms"]["p50"]),
                common.format_ms(g["scoped_token_ms"]["grep_ms"]["p50"]),
            ],
            [
                "commit",
                common.format_ms(g["admin_key_ms"]["commit_ms"]["p50"]),
                common.format_ms(g["scoped_token_ms"]["commit_ms"]["p50"]),
            ],
        ]
        parts.append(
            f"Scoped token check (`refs` + `read_refs` + `paths` + branch lock + {g['revoked_tokens_seeded']} revoked tokens) "
            f"and unauthorized 5 MiB `git push` rejection p50 = **{common.format_ms(g['rejected_5mib_push_ms']['p50'])}** "
            f"(p95 = {common.format_ms(g['rejected_5mib_push_ms']['p95'])}, main unchanged: `{g['main_unchanged']}`):"
        )
        parts.append("")
        parts.append(common.markdown_table(["Operation", "Admin Key p50", "Scoped Token p50"], g_rows))
        parts.append("")

        m_rows = [
            [
                mr["files"],
                common.format_ms(mr["commit_ms"]["p50"]),
                common.format_ms(mr["commit_ms"]["p95"]),
                common.format_ms(mr["ms_per_file_p50"]),
            ]
            for mr in b5["multifile_commits"]
        ]
        parts.append("### Multi-File Commit Curve (`POST /commits`)",)
        parts.append("")
        parts.append(common.markdown_table(["Files in Commit", "p50", "p95", "ms / file"], m_rows))
        parts.append("")

    parts.append(f"**Server log issues:** {report.get('server_log_issues', 0)}")
    parts.append("")
    return "\n".join(parts)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Run gitd benchmark suite (Benchmarks 1, 2, 3, 5)")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--gitd-bin", help="Path to gitd binary to launch and manage")
    src.add_argument("--base", help="Base URL of an already-running gitd instance")
    ap.add_argument("--key", help="Admin key (required with --base)")
    ap.add_argument("--data-dir", help="Data directory for self-managed gitd (default: temp dir)")
    ap.add_argument("--server-pid", type=int, help="Optional PID of external gitd for RSS tracking")
    ap.add_argument("--mode", choices=("quick", "full"), default="quick")
    ap.add_argument("--only", default="b1,b2,b3,b5", help="Comma-separated benchmarks (b1,b2,b3,b5)")
    ap.add_argument("--oss-repos", action="store_true", help="Use pinned OSS repos for B1")
    ap.add_argument("--oss-cache", default="/tmp/gitd-bench-oss", help="Cache directory for OSS clones")
    ap.add_argument("--out-dir", help="Directory to write results.json and results.md")
    args = ap.parse_args(argv)
    if args.base and not args.key:
        ap.error("--key is required when using --base")
    return args


def main() -> None:
    args = parse_args()
    selected = {x.strip().lower() for x in args.only.split(",") if x.strip()}
    unknown = selected - {"b1", "b2", "b3", "b5"}
    if unknown:
        raise SystemExit(f"unknown benchmark selector(s): {sorted(unknown)}")

    managed: ManagedGitd | None = None
    ext_rss: common.RssMonitor | None = None
    admin: common.KeepAliveClient | None = None
    server_issues: list[str] = []
    rss_summary: dict[str, Any] = {"idle_mib": None, "peak_mib": None, "samples": 0}

    try:
        if args.gitd_bin:
            managed = ManagedGitd(args.gitd_bin, args.data_dir)
            managed.start()
            base_url = managed.base_url
            admin_key = managed.admin_key
            rss_mon = managed.rss_mon
            data_dir = managed.data_dir
        else:
            base_url = args.base.rstrip("/")
            admin_key = args.key
            data_dir = args.data_dir
            if args.server_pid:
                ext_rss = common.RssMonitor(args.server_pid)
                ext_rss.start()
            rss_mon = ext_rss

        admin = common.KeepAliveClient(base_url, admin_key)
        sysinfo = common.collect_sysinfo(gitd_bin=args.gitd_bin, data_dir=data_dir)
        report: dict[str, Any] = {
            "mode": args.mode,
            "sysinfo": sysinfo,
        }

        if "b1" in selected:
            print("[suite] running B1: zero-clone API loop vs clone/push...", flush=True)
            report["b1_zero_clone"] = run_b1(
                admin,
                base_url,
                mode=args.mode,
                oss_repos=args.oss_repos,
                oss_cache=args.oss_cache,
            )
        if "b2" in selected:
            print("[suite] running B2: multi-agent fan-out/fan-in...", flush=True)
            report["b2_fanout_fanin"] = run_b2(admin, base_url, mode=args.mode, rss_mon=rss_mon)
        if "b3" in selected:
            print("[suite] running B3: CAS contention storm...", flush=True)
            report["b3_cas_race"] = run_b3(admin, base_url, mode=args.mode)
        if "b5" in selected:
            print("[suite] running B5: proxy overhead, guardrails & multi-file curve...", flush=True)
            report["b5_proxy_guardrails_limits"] = run_b5(admin, base_url, mode=args.mode)

    finally:
        if admin is not None:
            admin.close_all()
        if managed is not None:
            rss_summary, server_issues = managed.stop()
        elif ext_rss is not None:
            rss_summary = ext_rss.stop()

    report["rss"] = rss_summary
    report["server_log_issues"] = len(server_issues)
    if server_issues:
        report["server_issue_samples"] = server_issues[:10]

    md = render_markdown(report)
    if args.out_dir:
        os.makedirs(args.out_dir, exist_ok=True)
        with open(os.path.join(args.out_dir, "results.json"), "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
            f.write("\n")
        with open(os.path.join(args.out_dir, "results.md"), "w", encoding="utf-8") as f:
            f.write(md)

    print()
    print(md)
    if server_issues:
        raise SystemExit(f"server logged {len(server_issues)} issue(s): {server_issues[:3]}")


if __name__ == "__main__":
    main()
