import io
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

from gitd import ConflictError, GitdClient, GitdError


class GitdSdkTest(unittest.TestCase):
    def setUp(self) -> None:
        self._proc: subprocess.Popen[bytes] | None = None
        self._tmp: str | None = None
        if os.environ.get("GITD_URL") and os.environ.get("GITD_KEY"):
            self.base_url = os.environ["GITD_URL"]
            self.key = os.environ["GITD_KEY"]
            return
        bin_path = os.environ.get("GITD_BIN", str(Path(__file__).resolve().parents[2] / "zig-out/bin/gitd"))
        self._tmp = tempfile.mkdtemp(prefix="gitd-py-sdk-")
        data_dir = os.path.join(self._tmp, "data")
        self.key = subprocess.check_output([bin_path, "admin", "create-key", "--data", data_dir], text=True).strip()
        log_path = os.path.join(self._tmp, "server.log")
        self._log_file = open(log_path, "wb")
        self._proc = subprocess.Popen(
            [bin_path, "serve", "--data", data_dir, "--listen", "127.0.0.1:0"],
            stdout=subprocess.DEVNULL,
            stderr=self._log_file,
        )
        port = None
        for _ in range(100):
            text = Path(log_path).read_text(errors="ignore")
            m = re.search(r"listening on 127\.0\.0\.1:(\d+),", text)
            if m:
                port = m.group(1)
                break
            time.sleep(0.05)
        if not port:
            raise RuntimeError("gitd did not start")
        self.base_url = f"http://127.0.0.1:{port}"

    def tearDown(self) -> None:
        if self._proc is not None:
            self._proc.terminate()
            self._proc.wait(timeout=5)
            self._log_file.close()
        if self._tmp is not None:
            shutil.rmtree(self._tmp, ignore_errors=True)

    def test_end_to_end(self) -> None:
        admin = GitdClient(self.base_url, self.key)
        self.assertTrue(admin.healthz())

        suffix = str(int(time.time() * 1000))
        repo = f"sdk/py-{suffix}"
        mirror = f"sdk/py-mirror-{suffix}"
        admin.create_repo(repo)
        admin.create_repo(mirror)

        init = admin.commit(
            repo,
            branch="main",
            expected_head=None,
            message="Initial commit",
            changes=[
                {"path": "README.md", "content": "# Hello Python SDK\n"},
                {"path": "app.py", "content": "GREETING = 'hello from py'\n"},
            ],
        )
        self.assertIsNone(init["parent"])

        tok = admin.create_token(
            repo,
            ["git:read", "git:write"],
            refs=["refs/heads/agent/py/*"],
            ttl_seconds=300,
        )["token"]
        agent = admin.with_token(tok)

        self.assertEqual(agent.read_text_file(repo, "README.md"), "# Hello Python SDK\n")
        tree = agent.read_tree(repo)
        self.assertEqual([e["name"] for e in tree["entries"]], ["README.md", "app.py"])

        with self.assertRaises(GitdError) as ctx:
            agent.commit(
                repo,
                branch="main",
                expected_head=init["sha"],
                message="blocked",
                changes=[{"path": "bad.txt", "content": "x"}],
            )
        self.assertEqual(ctx.exception.status, 403)

        first = agent.commit(
            repo,
            branch="agent/py/work",
            expected_head=None,
            from_ref="main",
            message="Agent 1",
            changes=[{"path": "app.py", "content": "GREETING = 'v1'\n"}],
        )
        raced = agent.commit(
            repo,
            branch="agent/py/work",
            expected_head=first["sha"],
            message="Concurrent",
            changes=[{"path": "notes.txt", "content": "raced\n"}],
        )

        attempts = 0

        def build(head: str | None) -> dict:
            nonlocal attempts
            attempts += 1
            return {
                "message": f"Retry {attempts}",
                "changes": [{"path": "app.py", "content": f"GREETING = 'v2-{(head or '')[:7]}'\n"}],
            }

        retried = agent.commit_with_retry(repo, "agent/py/work", build, initial_head=first["sha"])
        self.assertEqual(attempts, 2)
        self.assertEqual(retried["parent"], raced["sha"])

        # Surgical edit commit via commit_with_retry
        patched = agent.commit_with_retry(
            repo,
            "agent/py/work",
            lambda _: {
                "message": "Surgical edit",
                "changes": [{"path": "app.py", "edits": [{"old": "GREETING", "new": "MSG"}]}],
            },
        )
        self.assertIn("MSG = ", agent.read_text_file(repo, "app.py", ref=patched["sha"]))
        agent.commit(
            repo,
            branch="agent/py/work",
            expected_head=patched["sha"],
            message="Restore",
            changes=[{"path": "app.py", "edits": [{"old": "MSG", "new": "GREETING"}]}],
        )

        # Grep & Archive
        grep_res = agent.grep(repo, "GREETING", ref="agent/py/work")
        self.assertEqual(len(grep_res["matches"]), 1)
        self.assertEqual(grep_res["matches"][0]["path"], "app.py")

        tar_bytes = agent.archive(repo, ref="agent/py/work", format="tar.gz")
        with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz") as tf:
            self.assertIn("app.py", tf.getnames())

        # Compare & Merge (including dry_run & conflict radar)
        dry_ok = agent.merge(repo, base="main", head="agent/py/work", dry_run=True)
        self.assertTrue(dry_ok["dry_run"])
        self.assertTrue(dry_ok["mergeable"])
        self.assertEqual(dry_ok["result"], "fast_forward")

        diff = admin.compare(repo, "main", "agent/py/work")
        self.assertEqual(diff["ahead"], 5)
        merged = admin.merge(repo, base="main", head="agent/py/work")
        self.assertEqual(merged["result"], "fast_forward")

        admin.commit(
            repo,
            branch="agent/py/c1",
            expected_head=None,
            from_ref="main",
            message="c1",
            changes=[{"path": "README.md", "content": "# c1\n"}],
        )
        admin.commit(
            repo,
            branch="agent/py/c2",
            expected_head=None,
            from_ref="main",
            message="c2",
            changes=[{"path": "README.md", "content": "# c2\n"}],
        )
        radar = agent.check_merge_conflicts(
            repo, base="main", heads=["agent/py/c1", "agent/py/c2"], include_file_overlaps=True
        )
        self.assertTrue(all(b["mergeable"] for b in radar["branches"]))
        self.assertEqual(len(radar["pair_conflicts"]), 1)
        self.assertEqual(radar["pair_conflicts"][0]["conflicts"], ["README.md"])
        self.assertEqual(len(radar["file_overlaps"]), 1)

        # Branch lock visibility + protection rules
        admin.lock_branch(repo, "main", reason="freeze")
        branches = admin.list_branches(repo)
        main_b = next(b for b in branches if b["name"] == "main")
        self.assertTrue(main_b["locked"])
        self.assertEqual(main_b["lock_reason"], "freeze")
        admin.unlock_branch(repo, "main")
        rule = admin.create_rule(
            repo,
            "refs/heads/main",
            allow_direct_push=False,
            allow_force_push=False,
            allow_delete=False,
            required_merge_strategy="squash",
            required_checks=["tests"],
        )
        self.assertEqual(rule["required_merge_strategy"], "squash")
        self.assertEqual(rule["required_checks"], ["tests"])
        self.assertEqual(len(admin.list_rules(repo)), 1)

        chk_tok = admin.create_token(repo, ["git:read", "checks:write"])["token"]
        checker = admin.with_token(chk_tok)
        c1_sha = next(b["commit"] for b in admin.list_branches(repo) if b["name"] == "agent/py/c1")
        dry_blocked = agent.merge(repo, base="main", head="agent/py/c1", strategy="squash", dry_run=True)
        self.assertFalse(dry_blocked["mergeable"])
        self.assertEqual(dry_blocked["blocked_by"], "missing_required_check")
        self.assertEqual(dry_blocked["missing_checks"], ["tests"])
        checker.post_check(repo, c1_sha, name="tests", status="passed", summary="all green")
        chk_list = agent.list_checks(repo, c1_sha)
        self.assertEqual(chk_list["rollup"], "passed")
        self.assertEqual(chk_list["checks"][0]["name"], "tests")
        admin.delete_rule(repo, rule["id"])

        # Sync fetch into mirror
        up_tok = admin.create_token(repo, ["git:read", "git:write"])["token"]
        fetched = admin.sync(
            mirror,
            direction="fetch",
            url=f"{self.base_url}/{repo}.git",
            branch="main",
            token=up_tok,
        )
        self.assertEqual(fetched["new_sha"], merged["sha"])

        # Quotas, stats & GC
        quotas = admin.set_quotas(repo, max_branches=10, max_repo_bytes=5_000_000)
        self.assertEqual(quotas["effective_max_branches"], 10)
        stats = admin.get_stats(repo)
        self.assertGreater(stats["branches"], 0)
        self.assertGreater(stats["disk_bytes"], 0)
        gc_res = admin.gc(repo, prune_seconds=0)
        self.assertGreater(gc_res["after_bytes"], 0)

        admin.delete_repo(mirror)
        admin.delete_repo(repo)


if __name__ == "__main__":
    unittest.main()
