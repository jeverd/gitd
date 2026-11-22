"""Zero-dependency Python SDK for gitd (uses only the Python standard library)."""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Iterator


class GitdError(Exception):
    def __init__(self, status: int, code: str, message: str, body: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.body = body or {}


class ConflictError(GitdError):
    def __init__(self, code: str, message: str, body: dict[str, Any]) -> None:
        super().__init__(409, code, message, body)
        self.current_head: str | None = body.get("current_head") if isinstance(body.get("current_head"), str) else None
        self.conflicts: list[str] = list(body.get("conflicts", [])) if isinstance(body.get("conflicts"), list) else []


def _encode_path(path: str) -> str:
    return "/".join(urllib.parse.quote(seg, safe="") for seg in path.split("/"))


class GitdClient:
    def __init__(self, base_url: str, token: str, *, timeout: float = 30.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def with_token(self, token: str) -> GitdClient:
        """Return a new client targeting the same server with a different key/token."""
        return GitdClient(self.base_url, token, timeout=self.timeout)

    def _request(self, method: str, path: str, body: Any = None) -> bytes:
        headers = {"Authorization": f"Bearer {self.token}"}
        data: bytes | None = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(f"{self.base_url}{path}", data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            parsed: dict[str, Any] = {}
            try:
                parsed = json.loads(raw.decode("utf-8"))
            except Exception:
                pass
            err_obj = parsed.get("error") if isinstance(parsed.get("error"), dict) else {}
            code = str(err_obj.get("code", f"http_{exc.code}"))
            msg = str(err_obj.get("message", exc.reason))
            if exc.code == 409:
                raise ConflictError(code, msg, parsed) from None
            raise GitdError(exc.code, code, msg, parsed) from None

    def _json(self, method: str, path: str, body: Any = None) -> Any:
        raw = self._request(method, path, body)
        return json.loads(raw.decode("utf-8")) if raw else None

    def healthz(self) -> bool:
        try:
            with urllib.request.urlopen(f"{self.base_url}/healthz", timeout=self.timeout) as resp:
                return 200 <= resp.status < 300
        except urllib.error.URLError:
            return False

    # ---- Repos & Tokens ----

    def create_repo(self, name: str) -> dict[str, Any]:
        return self._json("POST", "/v1/repos", {"name": name})

    def list_repos(self) -> list[dict[str, Any]]:
        return self._json("GET", "/v1/repos")["repos"]

    def get_repo(self, name: str) -> dict[str, Any]:
        return self._json("GET", f"/v1/repos/{name}")

    def delete_repo(self, name: str) -> None:
        self._request("DELETE", f"/v1/repos/{name}")

    def create_token(
        self,
        repo: str,
        scopes: list[str],
        *,
        ttl_seconds: int | None = None,
        refs: list[str] | None = None,
        read_refs: list[str] | None = None,
        paths: list[str] | None = None,
        branch_ttl_seconds: int | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"repo": repo, "scopes": scopes}
        if ttl_seconds is not None:
            body["ttl_seconds"] = ttl_seconds
        if refs is not None:
            body["refs"] = refs
        if read_refs is not None:
            body["read_refs"] = read_refs
        if paths is not None:
            body["paths"] = paths
        if branch_ttl_seconds is not None:
            body["branch_ttl_seconds"] = branch_ttl_seconds
        return self._json("POST", "/v1/tokens", body)

    def revoke_token(self, jti: str) -> None:
        self._request("POST", f"/v1/tokens/{urllib.parse.quote(jti, safe='')}/revoke")

    # ---- Branches ----

    def list_branches(self, repo: str) -> list[dict[str, Any]]:
        return self._json("GET", f"/v1/repos/{repo}/branches")["branches"]

    def create_branch(
        self, repo: str, name: str, from_ref: str, *, ttl_seconds: int | None = None
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"name": name, "from": from_ref}
        if ttl_seconds is not None:
            body["ttl_seconds"] = ttl_seconds
        return self._json("POST", f"/v1/repos/{repo}/branches", body)

    def delete_branch(self, repo: str, name: str, *, expected: str | None = None) -> None:
        q = f"?expected={urllib.parse.quote(expected, safe='')}" if expected else ""
        self._request("DELETE", f"/v1/repos/{repo}/branches/{_encode_path(name)}{q}")

    def lock_branch(self, repo: str, name: str, *, reason: str = "") -> dict[str, Any]:
        return self._json("PUT", f"/v1/repos/{repo}/branches/{_encode_path(name)}/lock", {"reason": reason})

    def unlock_branch(self, repo: str, name: str) -> None:
        self._request("DELETE", f"/v1/repos/{repo}/branches/{_encode_path(name)}/lock")

    def create_rule(
        self,
        repo: str,
        pattern: str,
        *,
        allow_direct_push: bool = True,
        allow_force_push: bool = True,
        allow_delete: bool = True,
        required_merge_strategy: str | None = None,
        required_checks: list[str] | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "pattern": pattern,
            "allow_direct_push": allow_direct_push,
            "allow_force_push": allow_force_push,
            "allow_delete": allow_delete,
        }
        if required_merge_strategy is not None:
            body["required_merge_strategy"] = required_merge_strategy
        if required_checks is not None:
            body["required_checks"] = required_checks
        return self._json("POST", f"/v1/repos/{repo}/rules", body)

    def list_rules(self, repo: str) -> list[dict[str, Any]]:
        return self._json("GET", f"/v1/repos/{repo}/rules")["rules"]

    def delete_rule(self, repo: str, rule_id: int) -> None:
        self._request("DELETE", f"/v1/repos/{repo}/rules/{rule_id}")

    # ---- Files, Trees, History ----

    def read_file(self, repo: str, path: str, *, ref: str | None = None) -> bytes:
        q = f"?ref={urllib.parse.quote(ref, safe='')}" if ref else ""
        return self._request("GET", f"/v1/repos/{repo}/files/{_encode_path(path)}{q}")

    def read_text_file(self, repo: str, path: str, *, ref: str | None = None) -> str:
        return self.read_file(repo, path, ref=ref).decode("utf-8")

    def read_tree(self, repo: str, path: str | None = None, *, ref: str | None = None) -> dict[str, Any]:
        suffix = f"/{_encode_path(path)}" if path else ""
        q = f"?ref={urllib.parse.quote(ref, safe='')}" if ref else ""
        return self._json("GET", f"/v1/repos/{repo}/tree{suffix}{q}")

    def log(
        self, repo: str, *, ref: str | None = None, limit: int | None = None, path: str | None = None
    ) -> list[dict[str, Any]]:
        params: dict[str, str] = {}
        if ref is not None:
            params["ref"] = ref
        if limit is not None:
            params["limit"] = str(limit)
        if path is not None:
            params["path"] = path
        qs = urllib.parse.urlencode(params)
        return self._json("GET", f"/v1/repos/{repo}/log{f'?{qs}' if qs else ''}")["commits"]

    def get_commit(self, repo: str, sha: str) -> dict[str, Any]:
        return self._json("GET", f"/v1/repos/{repo}/commits/{urllib.parse.quote(sha, safe='')}")

    def post_check(
        self,
        repo: str,
        sha: str,
        *,
        name: str,
        status: str,
        summary: str | None = None,
        url: str | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"name": name, "status": status}
        if summary is not None:
            body["summary"] = summary
        if url is not None:
            body["url"] = url
        return self._json("POST", f"/v1/repos/{repo}/commits/{urllib.parse.quote(sha, safe='')}/checks", body)

    def list_checks(self, repo: str, sha: str) -> dict[str, Any]:
        return self._json("GET", f"/v1/repos/{repo}/commits/{urllib.parse.quote(sha, safe='')}/checks")

    # ---- Commits, Compare, Merge ----

    def commit(
        self,
        repo: str,
        *,
        branch: str,
        expected_head: str | None,
        message: str,
        changes: list[dict[str, Any]],
        from_ref: str | None = None,
        author: dict[str, str] | None = None,
        ttl_seconds: int | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "branch": branch,
            "expected_head": expected_head,
            "message": message,
            "changes": changes,
        }
        if from_ref is not None:
            body["from"] = from_ref
        if author is not None:
            body["author"] = author
        if ttl_seconds is not None:
            body["ttl_seconds"] = ttl_seconds
        return self._json("POST", f"/v1/repos/{repo}/commits", body)

    def commit_with_retry(
        self,
        repo: str,
        branch: str,
        build: Callable[[str | None], dict[str, Any]],
        *,
        max_attempts: int = 5,
        initial_head: str | None = ...,  # type: ignore[assignment]
    ) -> dict[str, Any]:
        """Commit to `branch` using CAS, retrying on 409 conflicts."""
        if initial_head is ...:
            branches = self.list_branches(repo)
            head = next((b["commit"] for b in branches if b["name"] == branch), None)
        else:
            head = initial_head
        for attempt in range(max_attempts):
            payload = build(head)
            try:
                return self.commit(repo, branch=branch, expected_head=head, **payload)
            except ConflictError as exc:
                if attempt + 1 < max_attempts:
                    head = exc.current_head
                    continue
                raise
        raise AssertionError("unreachable")

    def compare(self, repo: str, base: str, head: str) -> dict[str, Any]:
        return self._json("GET", f"/v1/repos/{repo}/compare/{_encode_path(base)}...{_encode_path(head)}")

    def merge(
        self,
        repo: str,
        *,
        base: str,
        head: str,
        strategy: str | None = None,
        dry_run: bool = False,
        delete_head: bool = False,
        expected_base_head: str | None = None,
        message: str | None = None,
        author: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"base": base, "head": head}
        if strategy is not None:
            body["strategy"] = strategy
        if dry_run:
            body["dry_run"] = True
        if delete_head:
            body["delete_head"] = True
        if expected_base_head is not None:
            body["expected_base_head"] = expected_base_head
        if message is not None:
            body["message"] = message
        if author is not None:
            body["author"] = author
        return self._json("POST", f"/v1/repos/{repo}/merges", body)

    def batch_merge(
        self,
        repo: str,
        *,
        base: str,
        heads: list[str],
        strategy: str | None = None,
        dry_run: bool = False,
        delete_heads: bool = False,
        expected_base_head: str | None = None,
        message: str | None = None,
        author: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"base": base, "heads": heads}
        if strategy is not None:
            body["strategy"] = strategy
        if dry_run:
            body["dry_run"] = True
        if delete_heads:
            body["delete_heads"] = True
        if expected_base_head is not None:
            body["expected_base_head"] = expected_base_head
        if message is not None:
            body["message"] = message
        if author is not None:
            body["author"] = author
        return self._json("POST", f"/v1/repos/{repo}/merges/batch", body)

    def check_merge_conflicts(
        self,
        repo: str,
        *,
        base: str,
        heads: list[str],
        include_file_overlaps: bool = False,
    ) -> dict[str, Any]:
        return self._json(
            "POST",
            f"/v1/repos/{repo}/merges/check",
            {"base": base, "heads": heads, "include_file_overlaps": include_file_overlaps},
        )

    def plan_wave_merge(
        self,
        repo: str,
        *,
        base: str,
        heads: list[str],
        include_file_overlaps: bool = True,
    ) -> dict[str, Any]:
        return self.check_merge_conflicts(
            repo, base=base, heads=heads, include_file_overlaps=include_file_overlaps
        )

    def wait_for_checks(
        self,
        repo: str,
        shas: list[str],
        *,
        required_checks: list[str] | None = None,
        timeout: float = 60.0,
    ) -> dict[str, dict[str, Any]]:
        required = required_checks or []
        results: dict[str, dict[str, Any]] = {}

        def _is_passed(res: dict[str, Any]) -> bool:
            if not required:
                return res.get("rollup") == "passed"
            by_name = {c["name"]: c["status"] for c in res.get("checks", [])}
            return all(by_name.get(name) == "passed" for name in required)

        def _is_failed(res: dict[str, Any]) -> bool:
            if not required:
                return res.get("rollup") == "failed"
            by_name = {c["name"]: c["status"] for c in res.get("checks", [])}
            return any(by_name.get(name) == "failed" for name in required)

        hist = self.list_events(repo, limit=1).get("events", [])
        after_id = hist[-1]["id"] if hist else 0

        pending: set[str] = set()
        for sha in dict.fromkeys(shas):
            res = self.list_checks(repo, sha)
            results[sha] = res
            if _is_failed(res):
                raise RuntimeError(f"checks failed on {sha[:10]}")
            if not _is_passed(res):
                pending.add(sha)
        if not pending:
            return results

        for ev in self.stream_events(repo, after=after_id, kind="check_updated", timeout=timeout):
            sha = ev.get("new", "")
            if sha not in pending:
                continue
            res = self.list_checks(repo, sha)
            results[sha] = res
            if _is_failed(res):
                raise RuntimeError(f"checks failed on {sha[:10]}")
            if _is_passed(res):
                pending.remove(sha)
                if not pending:
                    return results
        if pending:
            raise TimeoutError(f"timed out waiting for checks on {sorted(pending)}")
        return results

    def integrate_wave(
        self,
        repo: str,
        *,
        base: str,
        heads: list[str],
        strategy: str = "merge",
        delete_heads: bool = True,
        required_checks: list[str] | None = None,
        timeout: float = 60.0,
        resolve_cluster: Callable[[dict[str, Any]], str | None] | None = None,
    ) -> dict[str, Any]:
        if required_checks:
            by_name = {b["name"]: b["commit"] for b in self.list_branches(repo)}
            shas = [by_name[h] for h in heads if h in by_name]
            if shas:
                self.wait_for_checks(repo, shas, required_checks=required_checks, timeout=timeout)

        plan = self.plan_wave_merge(repo, base=base, heads=heads)
        batch_merged: list[str] = []
        cluster_merged: list[str] = []
        deleted_heads: list[str] = []
        unresolved_clusters: list[dict[str, Any]] = []
        latest_sha: str | None = plan.get("base_sha")

        if plan.get("clean_heads"):
            res = self.batch_merge(
                repo,
                base=base,
                heads=plan["clean_heads"],
                strategy=strategy,
                delete_heads=delete_heads,
            )
            latest_sha = res["sha"]
            batch_merged.extend(res.get("merged_heads", []))
            deleted_heads.extend(res.get("deleted_heads", []))

        for cluster in plan.get("conflict_clusters", []):
            if resolve_cluster is None:
                unresolved_clusters.append(cluster)
                continue
            resolved_branch = resolve_cluster(cluster)
            if not resolved_branch:
                unresolved_clusters.append(cluster)
                continue
            if required_checks:
                by_name = {b["name"]: b["commit"] for b in self.list_branches(repo)}
                if resolved_branch in by_name:
                    self.wait_for_checks(
                        repo, [by_name[resolved_branch]], required_checks=required_checks, timeout=timeout
                    )
            res = self.merge(
                repo,
                base=base,
                head=resolved_branch,
                strategy=strategy,
                delete_head=delete_heads,
            )
            latest_sha = res["sha"]
            cluster_merged.append(resolved_branch)
            if res.get("head_deleted"):
                deleted_heads.append(resolved_branch)

        return {
            "base": base,
            "sha": latest_sha,
            "batch_merged": batch_merged,
            "cluster_merged": cluster_merged,
            "deleted_heads": deleted_heads,
            "unresolved_clusters": unresolved_clusters,
            "blocked_heads": plan.get("blocked_heads", []),
        }

    # ---- Grep, Archive, Sync ----

    def grep(
        self,
        repo: str,
        query: str,
        *,
        ref: str | None = None,
        path: str | None = None,
        fixed: bool = False,
        ignore_case: bool = False,
        limit: int | None = None,
    ) -> dict[str, Any]:
        params: dict[str, str] = {"q": query}
        if ref is not None:
            params["ref"] = ref
        if path is not None:
            params["path"] = path
        if fixed:
            params["fixed"] = "1"
        if ignore_case:
            params["ignore_case"] = "1"
        if limit is not None:
            params["limit"] = str(limit)
        return self._json("GET", f"/v1/repos/{repo}/grep?{urllib.parse.urlencode(params)}")

    def archive(
        self,
        repo: str,
        *,
        ref: str | None = None,
        format: str = "tar.gz",
        path: str | None = None,
    ) -> bytes:
        params: dict[str, str] = {"format": format}
        if ref is not None:
            params["ref"] = ref
        if path is not None:
            params["path"] = path
        return self._request("GET", f"/v1/repos/{repo}/archive?{urllib.parse.urlencode(params)}")

    def sync(
        self,
        repo: str,
        *,
        direction: str,
        url: str,
        branch: str,
        remote_branch: str | None = None,
        token: str | None = None,
        username: str | None = None,
        force: bool = False,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"direction": direction, "url": url, "branch": branch, "force": force}
        if remote_branch is not None:
            body["remote_branch"] = remote_branch
        if token is not None:
            body["token"] = token
        if username is not None:
            body["username"] = username
        return self._json("POST", f"/v1/repos/{repo}/sync", body)

    # ---- Webhooks ----

    def create_webhook(self, repo: str, url: str) -> dict[str, Any]:
        return self._json("POST", f"/v1/repos/{repo}/webhooks", {"url": url})

    def list_webhooks(self, repo: str) -> list[dict[str, Any]]:
        return self._json("GET", f"/v1/repos/{repo}/webhooks")["webhooks"]

    def delete_webhook(self, repo: str, webhook_id: int) -> None:
        self._request("DELETE", f"/v1/repos/{repo}/webhooks/{webhook_id}")

    def list_webhook_deliveries(self, repo: str, *, limit: int | None = None) -> list[dict[str, Any]]:
        q = f"?limit={limit}" if limit is not None else ""
        return self._json("GET", f"/v1/repos/{repo}/webhooks/deliveries{q}")["deliveries"]

    # ---- Quotas, Stats & Maintenance ----

    def get_quotas(self, repo: str) -> dict[str, Any]:
        return self._json("GET", f"/v1/repos/{repo}/quotas")

    def set_quotas(
        self, repo: str, *, max_branches: int = 0, max_repo_bytes: int = 0
    ) -> dict[str, Any]:
        return self._json(
            "PUT",
            f"/v1/repos/{repo}/quotas",
            {"max_branches": max_branches, "max_repo_bytes": max_repo_bytes},
        )

    def get_stats(self, repo: str) -> dict[str, Any]:
        return self._json("GET", f"/v1/repos/{repo}/stats")

    def gc(self, repo: str, *, prune_seconds: int | None = None) -> dict[str, Any]:
        body = {"prune_seconds": prune_seconds} if prune_seconds is not None else None
        return self._json("POST", f"/v1/repos/{repo}/gc", body)

    # ---- Events & Live SSE Stream ----

    def list_events(
        self,
        repo: str,
        *,
        after: int | None = None,
        kind: str | None = None,
        ref: str | None = None,
        limit: int | None = None,
    ) -> dict[str, Any]:
        params: dict[str, str] = {}
        if after is not None:
            params["after"] = str(after)
        if kind is not None:
            params["kind"] = kind
        if ref is not None:
            params["ref"] = ref
        if limit is not None:
            params["limit"] = str(limit)
        qs = urllib.parse.urlencode(params)
        return self._json("GET", f"/v1/repos/{repo}/events{f'?{qs}' if qs else ''}")

    def stream_events(
        self,
        repo: str,
        *,
        after: int | None = None,
        kind: str | None = None,
        ref: str | None = None,
        timeout: float = 30.0,
    ) -> Iterator[dict[str, Any]]:
        params: dict[str, str] = {"stream": "1"}
        if after is not None:
            params["after"] = str(after)
        if kind is not None:
            params["kind"] = kind
        if ref is not None:
            params["ref"] = ref
        req = urllib.request.Request(
            f"{self.base_url}/v1/repos/{repo}/events?{urllib.parse.urlencode(params)}",
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "text/event-stream",
            },
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data_lines: list[str] = []
                while True:
                    raw = resp.readline()
                    if not raw:
                        break
                    line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                    if line == "":
                        if data_lines:
                            payload = "\n".join(data_lines)
                            data_lines.clear()
                            yield json.loads(payload)
                    elif line.startswith("data:"):
                        data_lines.append(line[5:].lstrip())
        except urllib.error.HTTPError as exc:
            raw_err = exc.read()
            parsed: dict[str, Any] = {}
            try:
                parsed = json.loads(raw_err.decode("utf-8"))
            except Exception:
                pass
            err_obj = parsed.get("error") if isinstance(parsed.get("error"), dict) else {}
            raise GitdError(
                exc.code,
                str(err_obj.get("code", f"http_{exc.code}")),
                str(err_obj.get("message", exc.reason)),
                parsed,
            ) from None
