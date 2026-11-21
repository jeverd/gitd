"""Benchmark 4: Compare gitd against Gitea and Forgejo in Docker containers.

Runs each target one at a time under identical CPU/RAM limits on SQLite,
measuring image size, cold start, idle/peak RSS, ephemeral provisioning
(repos + tokens), and sequential/concurrent API commits.
"""

from __future__ import annotations

import argparse
import base64
import json
import secrets
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

BENCH_DIR = Path(__file__).resolve().parent
if str(BENCH_DIR) not in sys.path:
    sys.path.insert(0, str(BENCH_DIR))

import common  # noqa: E402


def _docker_cmd(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["docker", *args], capture_output=True, text=True, check=check)


def _parse_mem_mib(usage_str: str) -> float | None:
    first = usage_str.split("/", 1)[0].strip()
    if not first:
        return None
    for suffix, mult in (("GiB", 1024.0), ("MiB", 1.0), ("KiB", 1.0 / 1024.0), ("GB", 1000.0), ("MB", 1.0), ("B", 1.0 / (1024.0 * 1024.0))):
        if first.endswith(suffix):
            num = first[: -len(suffix)].strip()
            try:
                return round(float(num) * mult, 2)
            except ValueError:
                return None
    return None


class ContainerRssSampler:
    def __init__(self, container_name: str, interval_s: float = 0.5) -> None:
        self.container_name = container_name
        self.interval_s = interval_s
        self.peak_mib: float = 0.0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def sample_once(self) -> float | None:
        res = _docker_cmd(
            ["stats", "--no-stream", "--format", "{{.MemUsage}}", self.container_name],
            check=False,
        )
        if res.returncode != 0:
            return None
        mib = _parse_mem_mib(res.stdout.strip())
        if mib is not None and mib > self.peak_mib:
            self.peak_mib = mib
        return mib

    def start(self) -> None:
        self.sample_once()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while not self._stop.wait(self.interval_s):
            self.sample_once()

    def stop(self) -> float:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=3.0)
        self.sample_once()
        return self.peak_mib


def _image_size_bytes(image: str) -> int:
    inspect = _docker_cmd(["image", "inspect", "--format", "{{.Size}}", image], check=False)
    if inspect.returncode != 0:
        print(f"[forges] pulling image {image}...", flush=True)
        _docker_cmd(["pull", image], check=True)
        inspect = _docker_cmd(["image", "inspect", "--format", "{{.Size}}", image], check=True)
    return int(inspect.stdout.strip())


def _wait_health(base_url: str, path: str, deadline_s: float = 90.0) -> float:
    client = common.KeepAliveClient(base_url, no_keepalive=True, timeout=2.0)
    t0 = time.perf_counter()
    try:
        while time.perf_counter() - t0 < deadline_s:
            try:
                code, _, _, _ = client.request_raw("GET", path)
                if code == 200:
                    return (time.perf_counter() - t0) * 1000.0
            except Exception:
                pass
            time.sleep(0.01)
    finally:
        client.close_all()
    raise RuntimeError(f"container at {base_url}{path} did not become healthy within {deadline_s}s")


def _cleanup_container_and_volume(cname: str, vol_name: str) -> None:
    _docker_cmd(["rm", "-f", cname], check=False)
    _docker_cmd(["volume", "rm", "-f", vol_name], check=False)


def _run_gitd_target(image: str, *, cpus: str, memory: str, mode: str) -> dict[str, Any]:
    cold_runs = 1 if mode == "quick" else 3
    prov_count = 20 if mode == "quick" else 100
    seq_commits = 10 if mode == "quick" else 30
    conc_agents = 8 if mode == "quick" else 16
    conc_commits = 3 if mode == "quick" else 10

    img_bytes = _image_size_bytes(image)
    cold_ms: list[float] = []
    cid_prefix = f"gitd-cmp-{secrets.token_hex(4)}"

    def start_one(idx: int) -> tuple[str, str, str, str]:
        vol_name = f"{cid_prefix}-vol-{idx}"
        _docker_cmd(["volume", "create", vol_name])
        port = common.pick_free_port()
        admin_key = f"gitd_k_{secrets.token_hex(32)}"
        cname = f"{cid_prefix}-{idx}"
        base = f"http://127.0.0.1:{port}"
        try:
            t0 = time.perf_counter()
            _docker_cmd(
                [
                    "run",
                    "-d",
                    "--name",
                    cname,
                    f"--cpus={cpus}",
                    f"--memory={memory}",
                    "-p",
                    f"127.0.0.1:{port}:8080",
                    "-e",
                    f"GITD_ADMIN_KEY={admin_key}",
                    "-v",
                    f"{vol_name}:/data",
                    image,
                ]
            )
            _wait_health(base, "/healthz")
            cold_ms.append((time.perf_counter() - t0) * 1000.0)
        except Exception:
            _cleanup_container_and_volume(cname, vol_name)
            raise
        return cname, vol_name, base, admin_key

    for i in range(cold_runs - 1):
        cname, vol_name, _, _ = start_one(i)
        _cleanup_container_and_volume(cname, vol_name)

    cname, vol_name, base, admin_key = start_one(cold_runs - 1)
    sampler = ContainerRssSampler(cname)
    client = common.KeepAliveClient(base, admin_key)
    try:
        time.sleep(2.0)
        idle_mib = sampler.sample_once()
        sampler.start()

        repo_ms: list[float] = []
        tok_ms: list[float] = []
        t_prov = time.perf_counter()
        for i in range(prov_count):
            rname = f"bench/p{i:03d}"
            c1, out1, m1 = client.request_json("POST", "/v1/repos", body={"name": rname})
            if c1 != 201:
                raise RuntimeError(f"gitd create repo {rname} failed ({c1}): {out1}")
            repo_ms.append(m1)
            c2, out2, m2 = client.request_json(
                "POST",
                "/v1/tokens",
                body={
                    "repo": rname,
                    "scopes": ["git:read", "git:write"],
                    "refs": ["refs/heads/agent/*"],
                },
            )
            if c2 != 201:
                raise RuntimeError(f"gitd create token failed ({c2}): {out2}")
            tok_ms.append(m2)
        prov_wall_s = time.perf_counter() - t_prov

        work_repo = "bench/commits"
        client.request_json("POST", "/v1/repos", body={"name": work_repo})
        c_seed, seed_out, _ = client.request_json(
            "POST",
            f"/v1/repos/{work_repo}/commits",
            body={
                "branch": "main",
                "expected_head": None,
                "message": "seed",
                "changes": [{"path": "README.md", "content": "# seed\n"}],
            },
        )
        if c_seed != 201:
            raise RuntimeError(f"gitd seed failed ({c_seed}): {seed_out}")

        seq_ms: list[float] = []
        head = seed_out["sha"]
        for i in range(seq_commits):
            c, out, ms = client.request_json(
                "POST",
                f"/v1/repos/{work_repo}/commits",
                body={
                    "branch": "main",
                    "expected_head": head,
                    "message": f"seq {i}",
                    "changes": [{"path": "notes.txt", "content": f"seq {i}\n"}],
                },
            )
            if c != 201:
                raise RuntimeError(f"gitd seq commit failed ({c}): {out}")
            head = out["sha"]
            seq_ms.append(ms)

        client.close_all()
        barrier = threading.Barrier(conc_agents)
        conc_ms: list[float] = []
        errs: list[str] = []
        lock = threading.Lock()

        def worker(idx: int) -> None:
            wc = common.KeepAliveClient(base, admin_key)
            try:
                barrier.wait(timeout=30.0)
                tip: str | None = None
                for step in range(conc_commits):
                    body: dict[str, Any] = {
                        "branch": f"agent/{idx}",
                        "expected_head": tip,
                        "message": f"a{idx} s{step}",
                        "changes": [{"path": f"agent_{idx}.txt", "content": f"step {step}\n"}],
                    }
                    if tip is None:
                        body["from"] = "main"
                    c, out, ms = wc.request_json("POST", f"/v1/repos/{work_repo}/commits", body=body)
                    if c != 201:
                        with lock:
                            errs.append(f"a{idx} s{step}: {c} {out}")
                        return
                    tip = out["sha"]
                    with lock:
                        conc_ms.append(ms)
            finally:
                wc.close_all()

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(conc_agents)]
        t_conc = time.perf_counter()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        conc_wall_s = time.perf_counter() - t_conc
        if errs:
            raise RuntimeError(f"gitd concurrent commit errors: {errs[:3]}")
        peak_mib = sampler.stop()
    finally:
        client.close_all()
        _cleanup_container_and_volume(cname, vol_name)

    return {
        "target": "gitd",
        "image": image,
        "image_bytes": img_bytes,
        "cold_start_ms": common.summarize(cold_ms),
        "idle_rss_mib": idle_mib,
        "peak_rss_mib": peak_mib,
        "provision_count": prov_count,
        "provision_wall_s": round(prov_wall_s, 3),
        "repo_create_ms": common.summarize(repo_ms),
        "token_mint_ms": common.summarize(tok_ms),
        "seq_commit_ms": common.summarize(seq_ms),
        "conc_commit_ms": common.summarize(conc_ms),
        "conc_succeeded": len(conc_ms),
        "conc_errors": len(errs),
        "conc_commits_per_sec": round(len(conc_ms) / max(0.001, conc_wall_s), 1),
    }


def _run_gitea_like_target(
    kind: str, image: str, *, cpus: str, memory: str, mode: str
) -> dict[str, Any]:
    cold_runs = 1 if mode == "quick" else 3
    prov_count = 20 if mode == "quick" else 100
    seq_commits = 10 if mode == "quick" else 30
    conc_agents = 8 if mode == "quick" else 16
    conc_commits = 3 if mode == "quick" else 10

    cli_bin = "forgejo" if kind == "forgejo" else "gitea"
    env_prefix = "FORGEJO" if kind == "forgejo" else "GITEA"
    img_bytes = _image_size_bytes(image)
    cold_ms: list[float] = []
    cid_prefix = f"{kind}-cmp-{secrets.token_hex(4)}"

    def start_one(idx: int) -> tuple[str, str, str, str]:
        vol_name = f"{cid_prefix}-vol-{idx}"
        _docker_cmd(["volume", "create", vol_name])
        port = common.pick_free_port()
        cname = f"{cid_prefix}-{idx}"
        secret_key = secrets.token_hex(32)
        internal_tok = secrets.token_hex(32)
        base = f"http://127.0.0.1:{port}"
        envs = [
            f"{env_prefix}__database__DB_TYPE=sqlite3",
            f"{env_prefix}__database__PATH=/var/lib/gitea/data/gitea.db",
            f"{env_prefix}__database__SQLITE_JOURNAL_MODE=WAL",
            f"{env_prefix}__database__SQLITE_TIMEOUT=5000",
            f"{env_prefix}__security__INSTALL_LOCK=true",
            f"{env_prefix}__security__SECRET_KEY={secret_key}",
            f"{env_prefix}__security__INTERNAL_TOKEN={internal_tok}",
            f"{env_prefix}__server__HTTP_PORT=3000",
            f"{env_prefix}__server__ROOT_URL={base}/",
            f"{env_prefix}__service__DISABLE_REGISTRATION=true",
            f"{env_prefix}__log__LEVEL=Warn",
            # Mirror Gitea env prefix as well for Forgejo compatibility.
            "GITEA__database__DB_TYPE=sqlite3",
            "GITEA__database__PATH=/var/lib/gitea/data/gitea.db",
            "GITEA__database__SQLITE_JOURNAL_MODE=WAL",
            "GITEA__database__SQLITE_TIMEOUT=5000",
            "GITEA__security__INSTALL_LOCK=true",
            f"GITEA__security__SECRET_KEY={secret_key}",
            f"GITEA__security__INTERNAL_TOKEN={internal_tok}",
            "GITEA__server__HTTP_PORT=3000",
            f"GITEA__server__ROOT_URL={base}/",
            "GITEA__service__DISABLE_REGISTRATION=true",
            "GITEA__log__LEVEL=Warn",
        ]
        cmd = [
            "run",
            "-d",
            "--name",
            cname,
            f"--cpus={cpus}",
            f"--memory={memory}",
            "-p",
            f"127.0.0.1:{port}:3000",
            "-v",
            f"{vol_name}:/var/lib/gitea",
        ]
        for ev in envs:
            cmd.extend(["-e", ev])
        cmd.append(image)

        try:
            t0 = time.perf_counter()
            _docker_cmd(cmd)
            _wait_health(base, "/api/v1/version")
            cold_ms.append((time.perf_counter() - t0) * 1000.0)
        except Exception:
            _cleanup_container_and_volume(cname, vol_name)
            raise
        return cname, vol_name, base, cli_bin

    for i in range(cold_runs - 1):
        cname, vol_name, _, _ = start_one(i)
        _cleanup_container_and_volume(cname, vol_name)

    cname, vol_name, base, bin_name = start_one(cold_runs - 1)
    sampler = ContainerRssSampler(cname)
    password = secrets.token_urlsafe(16)
    basic_hdr = "Basic " + base64.b64encode(f"bench:{password}".encode()).decode("ascii")
    client: common.KeepAliveClient | None = None
    try:
        # Bootstrap admin user and API token outside timed sections.
        res = _docker_cmd(
            [
                "exec",
                cname,
                bin_name,
                "admin",
                "user",
                "create",
                "--username",
                "bench",
                "--password",
                password,
                "--email",
                "bench@example.com",
                "--admin",
                "--must-change-password=false",
            ],
            check=False,
        )
        if res.returncode != 0 and bin_name != "gitea":
            _docker_cmd(
                [
                    "exec",
                    cname,
                    "gitea",
                    "admin",
                    "user",
                    "create",
                    "--username",
                    "bench",
                    "--password",
                    password,
                    "--email",
                    "bench@example.com",
                    "--admin",
                    "--must-change-password=false",
                ]
            )
        elif res.returncode != 0:
            raise RuntimeError(f"{kind} admin create failed: {res.stderr}")

        boot_client = common.KeepAliveClient(base)
        c_tok, tok_out, _ = boot_client.request_json(
            "POST",
            "/api/v1/users/bench/tokens",
            body={"name": "admin-boot", "scopes": ["all"]},
            headers={"Authorization": basic_hdr},
        )
        boot_client.close_all()
        if c_tok != 201:
            raise RuntimeError(f"{kind} bootstrap token failed ({c_tok}): {tok_out}")
        api_token = tok_out["sha1"]
        client = common.KeepAliveClient(base)
        # Gitea/Forgejo accept `Authorization: token <sha1>` or `Bearer <sha1>`; use `token` for universal support.
        auth_hdr = {"Authorization": f"token {api_token}"}

        time.sleep(2.0)
        idle_mib = sampler.sample_once()
        sampler.start()

        repo_ms: list[float] = []
        tok_ms: list[float] = []
        t_prov = time.perf_counter()
        for i in range(prov_count):
            rname = f"p{i:03d}"
            c1, out1, m1 = client.request_json(
                "POST",
                "/api/v1/user/repos",
                body={"name": rname, "auto_init": False, "default_branch": "main"},
                headers=auth_hdr,
            )
            if c1 != 201:
                raise RuntimeError(f"{kind} create repo failed ({c1}): {out1}")
            repo_ms.append(m1)
            c2, out2, m2 = client.request_json(
                "POST",
                "/api/v1/users/bench/tokens",
                body={"name": f"tok-{i}", "scopes": ["write:repository", "read:user"]},
                headers={"Authorization": basic_hdr},
            )
            if c2 != 201:
                raise RuntimeError(f"{kind} create token failed ({c2}): {out2}")
            tok_ms.append(m2)
        prov_wall_s = time.perf_counter() - t_prov

        work_repo = "commits-bench"
        c_init, init_out, _ = client.request_json(
            "POST",
            "/api/v1/user/repos",
            body={"name": work_repo, "auto_init": True, "default_branch": "main"},
            headers=auth_hdr,
        )
        if c_init != 201:
            raise RuntimeError(f"{kind} seed repo failed ({c_init}): {init_out}")

        seq_ms: list[float] = []
        blob_sha: str | None = None
        for i in range(seq_commits):
            b64 = base64.b64encode(f"seq {i}\n".encode()).decode("ascii")
            if blob_sha is None:
                c, out, ms = client.request_json(
                    "POST",
                    f"/api/v1/repos/bench/{work_repo}/contents/notes.txt",
                    body={"branch": "main", "content": b64, "message": f"seq {i}"},
                    headers=auth_hdr,
                )
                if c != 201:
                    raise RuntimeError(f"{kind} seq create failed ({c}): {out}")
            else:
                c, out, ms = client.request_json(
                    "PUT",
                    f"/api/v1/repos/bench/{work_repo}/contents/notes.txt",
                    body={"branch": "main", "content": b64, "message": f"seq {i}", "sha": blob_sha},
                    headers=auth_hdr,
                )
                if c != 200:
                    raise RuntimeError(f"{kind} seq update failed ({c}): {out}")
            blob_sha = out["content"]["sha"]
            seq_ms.append(ms)

        client.close_all()
        barrier = threading.Barrier(conc_agents)
        conc_ms: list[float] = []
        errs: list[str] = []
        lock = threading.Lock()

        def worker(idx: int) -> None:
            wc = common.KeepAliveClient(base)
            try:
                barrier.wait(timeout=30.0)
                sha: str | None = None
                for step in range(conc_commits):
                    b64 = base64.b64encode(f"step {step}\n".encode()).decode("ascii")
                    if sha is None:
                        c, out, ms = wc.request_json(
                            "POST",
                            f"/api/v1/repos/bench/{work_repo}/contents/agent_{idx}.txt",
                            body={
                                "branch": "main",
                                "new_branch": f"agent/{idx}",
                                "content": b64,
                                "message": f"a{idx} s{step}",
                            },
                            headers=auth_hdr,
                        )
                        if c != 201:
                            with lock:
                                errs.append(f"a{idx} s{step}: {c} {out}")
                            break
                    else:
                        c, out, ms = wc.request_json(
                            "PUT",
                            f"/api/v1/repos/bench/{work_repo}/contents/agent_{idx}.txt",
                            body={
                                "branch": f"agent/{idx}",
                                "content": b64,
                                "message": f"a{idx} s{step}",
                                "sha": sha,
                            },
                            headers=auth_hdr,
                        )
                        if c != 200:
                            with lock:
                                errs.append(f"a{idx} s{step}: {c} {out}")
                            break
                    sha = out["content"]["sha"]
                    with lock:
                        conc_ms.append(ms)
            except Exception as exc:
                with lock:
                    errs.append(f"a{idx}: {exc}")
            finally:
                wc.close_all()

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(conc_agents)]
        t_conc = time.perf_counter()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        conc_wall_s = time.perf_counter() - t_conc
        peak_mib = sampler.stop()
    finally:
        if client is not None:
            client.close_all()
        _cleanup_container_and_volume(cname, vol_name)

    return {
        "target": kind,
        "image": image,
        "image_bytes": img_bytes,
        "cold_start_ms": common.summarize(cold_ms),
        "idle_rss_mib": idle_mib,
        "peak_rss_mib": peak_mib,
        "provision_count": prov_count,
        "provision_wall_s": round(prov_wall_s, 3),
        "repo_create_ms": common.summarize(repo_ms),
        "token_mint_ms": common.summarize(tok_ms),
        "seq_commit_ms": common.summarize(seq_ms),
        "conc_commit_ms": common.summarize(conc_ms),
        "conc_succeeded": len(conc_ms),
        "conc_errors": len(errs),
        "conc_error_samples": errs[:5],
        "conc_commits_per_sec": round(len(conc_ms) / max(0.001, conc_wall_s), 1),
    }


def render_markdown(report: dict[str, Any]) -> str:
    sysinfo = report["sysinfo"]
    parts = [
        "# Forge Comparison: gitd vs. Gitea & Forgejo",
        "",
        f"- **Mode:** `{report['mode']}`  **Container Limits:** `--cpus={report['cpus']} --memory={report['memory']}`  "
        f"**Host:** `{sysinfo['os']} ({sysinfo['arch']})` {sysinfo['cpu_count']} vCPU",
        "",
        "> **Scope note:** Gitea and Forgejo are full human Git forges (web UI, PRs, issues, SQLite ORM) and issue user-level PATs; "
        "`gitd` is a purpose-built minimal git storage server for agents and mints repo+ref-scoped HMAC-SHA256 tokens.",
        "",
    ]
    rows = []
    for r in report["results"]:
        conc_cell = f"{common.format_ms(r['conc_commit_ms']['p50'])} ({r['conc_commits_per_sec']}/s)"
        if r.get("conc_errors", 0):
            conc_cell += f", {r['conc_errors']} err"
        rows.append(
            [
                r["target"],
                common.format_bytes(r["image_bytes"]),
                common.format_ms(r["cold_start_ms"]["p50"]),
                f"{r['idle_rss_mib']} MiB" if r["idle_rss_mib"] is not None else "-",
                f"{r['peak_rss_mib']} MiB" if r["peak_rss_mib"] is not None else "-",
                f"{r['provision_wall_s']} s ({r['provision_count']}x)",
                common.format_ms(r["repo_create_ms"]["p50"]),
                common.format_ms(r["token_mint_ms"]["p50"]),
                common.format_ms(r["seq_commit_ms"]["p50"]),
                conc_cell,
            ]
        )
    parts.append(
        common.markdown_table(
            [
                "Target",
                "Image Size",
                "Cold Start p50",
                "Idle RSS",
                "Peak RSS",
                "Provision Repos+Tokens",
                "Create Repo p50",
                "Mint Token p50",
                "Seq Commit p50",
                "Conc Commit p50 (Rate)",
            ],
            rows,
        )
    )
    parts.append("")
    return "\n".join(parts)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Benchmark gitd vs Gitea and Forgejo in Docker")
    ap.add_argument("--targets", default="gitd,gitea,forgejo", help="Comma-separated: gitd,gitea,forgejo")
    ap.add_argument("--gitd-image", default="gitd:bench")
    ap.add_argument("--gitea-image", default="gitea/gitea:1.22-rootless")
    ap.add_argument("--forgejo-image", default="codeberg.org/forgejo/forgejo:9-rootless")
    ap.add_argument("--cpus", default="4")
    ap.add_argument("--memory", default="4g")
    ap.add_argument("--mode", choices=("quick", "full"), default="quick")
    ap.add_argument("--out-dir", help="Directory to write results.json and results.md")
    return ap.parse_args(argv)


def main() -> None:
    args = parse_args()
    targets = [t.strip().lower() for t in args.targets.split(",") if t.strip()]
    for t in targets:
        if t not in ("gitd", "gitea", "forgejo"):
            raise SystemExit(f"unknown target: {t}")

    results: list[dict[str, Any]] = []
    for target in targets:
        print(f"[forges] benchmarking {target}...", flush=True)
        if target == "gitd":
            results.append(_run_gitd_target(args.gitd_image, cpus=args.cpus, memory=args.memory, mode=args.mode))
        elif target == "gitea":
            results.append(_run_gitea_like_target("gitea", args.gitea_image, cpus=args.cpus, memory=args.memory, mode=args.mode))
        else:
            results.append(_run_gitea_like_target("forgejo", args.forgejo_image, cpus=args.cpus, memory=args.memory, mode=args.mode))

    report = {
        "mode": args.mode,
        "cpus": args.cpus,
        "memory": args.memory,
        "sysinfo": common.collect_sysinfo(),
        "results": results,
    }
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


if __name__ == "__main__":
    main()
