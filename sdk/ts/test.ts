import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { ConflictError, GitdClient, GitdError } from "./index.ts";

async function startServer(): Promise<{ baseUrl: string; key: string; stop: () => Promise<void> }> {
  if (process.env.GITD_URL && process.env.GITD_KEY) {
    return { baseUrl: process.env.GITD_URL, key: process.env.GITD_KEY, stop: async () => {} };
  }
  const bin = process.env.GITD_BIN ?? path.resolve(import.meta.dirname, "../../zig-out/bin/gitd");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "gitd-ts-sdk-"));
  const dataDir = path.join(tmp, "data");
  const key = execFileSync(bin, ["admin", "create-key", "--data", dataDir], { encoding: "utf8" }).trim();
  const child = spawn(bin, ["serve", "--data", dataDir, "--listen", "127.0.0.1:0"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const port = await new Promise<string>((resolve, reject) => {
    let logs = "";
    const timer = setTimeout(() => reject(new Error(`gitd did not start:\n${logs}`)), 5000);
    child.stderr.on("data", (chunk: Buffer) => {
      logs += chunk.toString("utf8");
      const m = logs.match(/listening on 127\.0\.0\.1:(\d+),/);
      if (m) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`gitd exited ${code}:\n${logs}`));
    });
  });
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    key,
    stop: async () => {
      child.kill("SIGTERM");
      await new Promise<void>((resolve) => child.once("exit", () => resolve()));
      fs.rmSync(tmp, { recursive: true, force: true });
    },
  };
}

test("TypeScript SDK end-to-end", async () => {
  const srv = await startServer();
  try {
    const admin = new GitdClient({ baseUrl: srv.baseUrl, token: srv.key });
    assert.equal(await admin.healthz(), true);

    const repoName = `sdk/ts-${Date.now()}`;
    const mirrorName = `sdk/ts-mirror-${Date.now()}`;
    await admin.createRepo(repoName);
    await admin.createRepo(mirrorName);

    const init = await admin.commit(repoName, {
      branch: "main",
      expected_head: null,
      message: "Initial commit",
      changes: [
        { path: "README.md", content: "# Hello gitd\n" },
        { path: "src/app.ts", content: "export const greeting = 'hello world';\n" },
      ],
    });
    assert.equal(init.parent, null);

    // Scoped agent token
    const { token } = await admin.createToken({
      repo: repoName,
      scopes: ["git:read", "git:write"],
      refs: ["refs/heads/agent/ts/*"],
      ttl_seconds: 300,
    });
    const agent = admin.withToken(token);

    assert.equal(await agent.readTextFile(repoName, "README.md"), "# Hello gitd\n");
    const tree = await agent.readTree(repoName);
    assert.deepEqual(
      tree.entries.map((e) => e.name),
      ["README.md", "src"],
    );

    // Scoped token blocked on main
    await assert.rejects(
      () =>
        agent.commit(repoName, {
          branch: "main",
          expected_head: init.sha,
          message: "nope",
          changes: [{ path: "x.txt", content: "x" }],
        }),
      (err: unknown) => err instanceof GitdError && err.status === 403,
    );

    // Create branch + commitWithRetry recovering from a 409 conflict
    const first = await agent.commit(repoName, {
      branch: "agent/ts/work",
      expected_head: null,
      from: "main",
      message: "Agent step 1",
      changes: [{ path: "src/app.ts", content: "export const greeting = 'v1';\n" }],
    });

    // Advance branch behind the caller's back to force a 409 on attempt 1
    const raced = await agent.commit(repoName, {
      branch: "agent/ts/work",
      expected_head: first.sha,
      message: "Concurrent commit",
      changes: [{ path: "notes.txt", content: "raced\n" }],
    });

    let attempts = 0;
    const retried = await agent.commitWithRetry(
      repoName,
      "agent/ts/work",
      (head) => {
        attempts++;
        return {
          message: `Retry commit (attempt ${attempts})`,
          changes: [{ path: "src/app.ts", content: `export const greeting = 'v2-${head?.slice(0, 7)}';\n` }],
        };
      },
      { initialHead: first.sha },
    );
    assert.equal(attempts, 2);
    assert.equal(retried.parent, raced.sha);

    // Grep & Archive
    const grepRes = await agent.grep(repoName, "greeting", { ref: "agent/ts/work" });
    assert.equal(grepRes.matches.length, 1);
    assert.equal(grepRes.matches[0].path, "src/app.ts");

    const archiveBytes = await agent.archive(repoName, { ref: "agent/ts/work", format: "tar.gz" });
    assert.ok(archiveBytes.byteLength > 20);
    assert.equal(archiveBytes[0], 0x1f); // gzip magic
    assert.equal(archiveBytes[1], 0x8b);

    // Compare & Merge (including dry_run & conflict radar)
    const dryOk = await agent.mergeDryRun(repoName, { base: "main", head: "agent/ts/work" });
    assert.equal(dryOk.dry_run, true);
    assert.equal(dryOk.mergeable, true);
    assert.equal(dryOk.result, "fast_forward");

    const diff = await admin.compare(repoName, "main", "agent/ts/work");
    assert.equal(diff.ahead, 3);
    const merged = await admin.merge(repoName, { base: "main", head: "agent/ts/work" });
    assert.equal(merged.result, "fast_forward");

    await admin.commit(repoName, {
      branch: "agent/ts/c1",
      expected_head: null,
      from: "main",
      message: "Edit README c1",
      changes: [{ path: "README.md", content: "# C1\n" }],
    });
    await admin.commit(repoName, {
      branch: "agent/ts/c2",
      expected_head: null,
      from: "main",
      message: "Edit README c2",
      changes: [{ path: "README.md", content: "# C2\n" }],
    });
    const radar = await agent.checkMergeConflicts(repoName, {
      base: "main",
      heads: ["agent/ts/c1", "agent/ts/c2"],
      include_file_overlaps: true,
    });
    assert.equal(radar.branches.every((b) => b.mergeable), true);
    assert.equal(radar.pair_conflicts.length, 1);
    assert.deepEqual(radar.pair_conflicts[0].conflicts, ["README.md"]);
    assert.equal(radar.file_overlaps.length, 1);

    // Branch lock visibility + protection rules
    await admin.lockBranch(repoName, "main", "freeze");
    const lockedList = await admin.listBranches(repoName);
    const mainEntry = lockedList.find((b) => b.name === "main");
    assert.equal(mainEntry?.locked, true);
    assert.equal(mainEntry?.lock_reason, "freeze");
    await admin.unlockBranch(repoName, "main");
    const rule = await admin.createRule(repoName, {
      pattern: "refs/heads/main",
      allow_direct_push: false,
      allow_force_push: false,
      allow_delete: false,
      required_merge_strategy: "squash",
      required_checks: ["tests"],
    });
    assert.equal(rule.required_merge_strategy, "squash");
    assert.deepEqual(rule.required_checks, ["tests"]);
    assert.equal((await admin.listRules(repoName)).length, 1);

    const { token: chkToken } = await admin.createToken({
      repo: repoName,
      scopes: ["git:read", "checks:write"],
    });
    const checker = admin.withToken(chkToken);
    const c1Info = (await admin.listBranches(repoName)).find((b) => b.name === "agent/ts/c1")!;
    const dryBlocked = await agent.mergeDryRun(repoName, { base: "main", head: "agent/ts/c1", strategy: "squash" });
    assert.equal(dryBlocked.mergeable, false);
    assert.equal(dryBlocked.blocked_by, "missing_required_check");
    assert.deepEqual(dryBlocked.missing_checks, ["tests"]);
    await checker.postCheck(repoName, c1Info.commit, { name: "tests", status: "passed", summary: "all green" });
    const chkList = await agent.listChecks(repoName, c1Info.commit);
    assert.equal(chkList.rollup, "passed");
    assert.equal(chkList.checks[0].name, "tests");
    await admin.deleteRule(repoName, rule.id);

    // Upstream sync (fetch from repoName into mirrorName)
    const { token: upToken } = await admin.createToken({
      repo: repoName,
      scopes: ["git:read", "git:write"],
    });
    const fetched = await admin.sync(mirrorName, {
      direction: "fetch",
      url: `${srv.baseUrl}/${repoName}.git`,
      branch: "main",
      token: upToken,
    });
    assert.equal(fetched.direction, "fetch");
    assert.equal(fetched.new_sha, merged.sha);

    // Quotas, stats & GC
    const quotas = await admin.setQuotas(repoName, { max_branches: 10, max_repo_bytes: 5_000_000 });
    assert.equal(quotas.effective_max_branches, 10);
    const stats = await admin.getStats(repoName);
    assert.ok(stats.branches >= 1 && stats.disk_bytes > 0);
    const gcRes = await admin.gc(repoName, { prune_seconds: 0 });
    assert.ok(gcRes.after_bytes > 0);

    await admin.deleteRepo(mirrorName);
    await admin.deleteRepo(repoName);
  } finally {
    await srv.stop();
  }
});
