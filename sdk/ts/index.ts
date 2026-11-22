/**
 * Zero-dependency TypeScript client for gitd.
 * Uses the built-in Fetch API (Node 20+, Deno, Bun, browsers).
 */

export type Scope = "git:read" | "git:write" | "checks:write";

export type CheckStatus = "pending" | "running" | "passed" | "failed";

export interface CommitCheck {
  name: string;
  status: CheckStatus;
  summary: string;
  url: string;
  updated_at: number;
}

export interface CommitCheckList {
  sha: string;
  rollup: "none" | "pending" | "passed" | "failed";
  checks: CommitCheck[];
}

export interface Repo {
  name: string;
  id: string;
  created_at: number;
}

export interface RepoQuotas {
  max_branches: number;
  max_repo_bytes: number;
  effective_max_branches: number;
  effective_max_repo_bytes: number;
  updated_at: number | null;
}

export interface RepoStats {
  branches: number;
  disk_bytes: number;
  objects_loose: number;
  size_loose_kb: number;
  objects_packed: number;
  size_pack_kb: number;
  last_gc_at: number | null;
  expired_since_gc: number;
  quotas: { max_branches: number; max_repo_bytes: number };
}

export interface GcResult {
  before_bytes: number;
  after_bytes: number;
  reclaimed_bytes: number;
  duration_ms: number;
}

export interface TokenOptions {
  repo: string;
  scopes: Scope[];
  ttl_seconds?: number;
  refs?: string[];
  read_refs?: string[];
  paths?: string[];
  branch_ttl_seconds?: number;
}

export interface TokenResponse {
  token: string;
  jti: string;
  expires_at: number;
}

export interface Branch {
  name: string;
  commit: string;
  committed_at: number;
  subject: string;
  expires_at: number | null;
  locked: boolean;
  lock_reason: string | null;
}

export interface BranchRule {
  id: number;
  pattern: string;
  allow_direct_push: boolean;
  allow_force_push: boolean;
  allow_delete: boolean;
  required_merge_strategy: "merge" | "squash" | "fast-forward" | null;
  required_checks: string[];
  created_at: number;
}

export interface CreateRuleOptions {
  pattern: string;
  allow_direct_push?: boolean;
  allow_force_push?: boolean;
  allow_delete?: boolean;
  required_merge_strategy?: "merge" | "squash" | "fast-forward";
  required_checks?: string[];
}

export interface TreeEntry {
  name: string;
  path: string;
  type: "blob" | "tree" | "commit";
  mode: string;
  oid: string;
  size: number | null;
}

export interface TreeResponse {
  commit: string;
  path: string;
  entries: TreeEntry[];
}

export interface CommitInfo {
  sha: string;
  parents: string[];
  author: { name: string; email: string };
  time: number;
  subject: string;
  body: string;
}

export interface FileEdit {
  old: string;
  new: string;
  replace_all?: boolean;
}

export interface FileChange {
  path: string;
  content?: string;
  content_base64?: string;
  delete?: boolean;
  edits?: FileEdit[];
  patch?: string;
}

export interface CommitOptions {
  branch: string;
  expected_head: string | null;
  from?: string;
  message: string;
  author?: { name: string; email: string };
  ttl_seconds?: number;
  changes: FileChange[];
}

export interface CommitResult {
  sha: string;
  branch: string;
  parent: string | null;
}

export interface CompareFile {
  path: string;
  status: string;
  additions: number | null;
  deletions: number | null;
}

export interface CompareResult {
  base: string;
  head: string;
  merge_base: string | null;
  ahead: number;
  behind: number;
  files: CompareFile[];
  patch: string | null;
}

export interface MergeOptions {
  base: string;
  head: string;
  strategy?: "merge" | "squash" | "fast-forward";
  dry_run?: boolean;
  delete_head?: boolean;
  expected_base_head?: string;
  message?: string;
  author?: { name: string; email: string };
}

export interface MergeResult {
  result: "fast_forward" | "merged" | "squashed" | "up_to_date";
  sha: string;
  head_deleted?: boolean;
}

export interface BatchMergeOptions {
  base: string;
  heads: string[];
  strategy?: "merge" | "squash";
  dry_run?: boolean;
  delete_heads?: boolean;
  expected_base_head?: string;
  message?: string;
  author?: { name: string; email: string };
}

export interface BatchMergeResult {
  result: "merged" | "squashed" | "up_to_date";
  sha: string;
  merged_heads: string[];
  deleted_heads: string[];
}

export interface DryRunMergeResult {
  dry_run: true;
  mergeable: boolean;
  result: "fast_forward" | "merged" | "squashed" | "up_to_date" | null;
  blocked_by:
    | "branch_locked"
    | "rule_violation"
    | "missing_required_check"
    | "not_fast_forward"
    | "merge_conflict"
    | null;
  conflicts: string[];
  missing_checks: string[];
}

export interface MergeCheckBranch {
  head: string;
  sha: string;
  mergeable: boolean;
  blocked_by?: string | null;
  conflicts: string[];
  missing_checks?: string[];
}

export interface MergeCheckPair {
  a: string;
  b: string;
  conflicts: string[];
}

export interface MergeCheckOverlap {
  a: string;
  b: string;
  paths: string[];
}

export interface ConflictCluster {
  heads: string[];
  files: string[];
}

export interface BlockedHead {
  head: string;
  blocked_by: string;
  conflicts: string[];
  missing_checks: string[];
}

export interface MergeCheckResult {
  base: string;
  base_sha: string;
  branches: MergeCheckBranch[];
  pair_conflicts: MergeCheckPair[];
  file_overlaps: MergeCheckOverlap[];
  clean_heads: string[];
  conflict_clusters: ConflictCluster[];
  blocked_heads: BlockedHead[];
}

export interface IntegrateWaveOptions {
  base: string;
  heads: string[];
  strategy?: "merge" | "squash";
  deleteHeads?: boolean;
  requiredChecks?: string[];
  timeoutMs?: number;
  resolveCluster?: (cluster: ConflictCluster) => Promise<string | null> | string | null;
}

export interface IntegrateWaveResult {
  base: string;
  sha: string | null;
  batchMerged: string[];
  clusterMerged: string[];
  deletedHeads: string[];
  unresolvedClusters: ConflictCluster[];
  blockedHeads: BlockedHead[];
}

export interface GrepOptions {
  ref?: string;
  path?: string;
  fixed?: boolean;
  ignoreCase?: boolean;
  limit?: number;
}

export interface GrepMatch {
  path: string;
  line: number;
  text: string;
}

export interface GrepResult {
  commit: string;
  matches: GrepMatch[];
  truncated: boolean;
}

export interface ArchiveOptions {
  ref?: string;
  format?: "tar.gz" | "tar" | "zip";
  path?: string;
}

export interface SyncOptions {
  direction: "fetch" | "push";
  url: string;
  branch: string;
  remote_branch?: string;
  token?: string;
  username?: string;
  force?: boolean;
}

export interface SyncFetchResult {
  direction: "fetch";
  branch: string;
  remote_branch: string;
  old_sha: string | null;
  new_sha: string;
}

export interface SyncPushResult {
  direction: "push";
  branch: string;
  remote_branch: string;
  sha: string;
}

export type SyncResult = SyncFetchResult | SyncPushResult;

export interface Webhook {
  id: number;
  url: string;
  secret?: string;
  created_at: number;
}

export interface RepoEvent {
  id: number;
  repo: string;
  kind: string;
  ref: string;
  old: string;
  new: string;
  detail: string;
  created_at: number;
}

export interface EventQueryOptions {
  after?: number;
  kind?: string;
  ref?: string;
  limit?: number;
}

export class GitdError extends Error {
  readonly status: number;
  readonly code: string;
  readonly body: Record<string, unknown>;

  constructor(status: number, code: string, message: string, body: Record<string, unknown> = {}) {
    super(message);
    this.name = "GitdError";
    this.status = status;
    this.code = code;
    this.body = body;
  }
}

export class ConflictError extends GitdError {
  readonly currentHead: string | null;
  readonly conflicts: string[];

  constructor(code: string, message: string, body: Record<string, unknown>) {
    super(409, code, message, body);
    this.name = "ConflictError";
    this.currentHead = typeof body.current_head === "string" ? body.current_head : null;
    this.conflicts = Array.isArray(body.conflicts) ? (body.conflicts as string[]) : [];
  }
}

export interface ClientOptions {
  baseUrl: string;
  token: string;
  fetch?: typeof globalThis.fetch;
}

function encodePath(path: string): string {
  return path
    .split("/")
    .map((seg) => encodeURIComponent(seg))
    .join("/");
}

export class GitdClient {
  readonly baseUrl: string;
  readonly token: string;
  readonly #fetch: typeof globalThis.fetch;

  constructor(opts: ClientOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/+$/, "");
    this.token = opts.token;
    this.#fetch = opts.fetch ?? globalThis.fetch;
  }

  /** Returns a new client targeting the same server with a different key/token. */
  withToken(token: string): GitdClient {
    return new GitdClient({ baseUrl: this.baseUrl, token, fetch: this.#fetch });
  }

  async #request(method: string, path: string, body?: unknown): Promise<Response> {
    const headers: Record<string, string> = {
      authorization: `Bearer ${this.token}`,
    };
    let payload: string | undefined;
    if (body !== undefined) {
      headers["content-type"] = "application/json";
      payload = JSON.stringify(body);
    }
    const resp = await this.#fetch(`${this.baseUrl}${path}`, {
      method,
      headers,
      body: payload,
    });
    if (!resp.ok) {
      let data: Record<string, unknown> = {};
      try {
        data = (await resp.json()) as Record<string, unknown>;
      } catch {
        // Non-JSON error body; fall back to status text.
      }
      const errObj = (data.error as Record<string, unknown> | undefined) ?? {};
      const code = typeof errObj.code === "string" ? errObj.code : `http_${resp.status}`;
      const msg = typeof errObj.message === "string" ? errObj.message : resp.statusText;
      if (resp.status === 409) {
        throw new ConflictError(code, msg, data);
      }
      throw new GitdError(resp.status, code, msg, data);
    }
    return resp;
  }

  async #json<T>(method: string, path: string, body?: unknown): Promise<T> {
    const resp = await this.#request(method, path, body);
    return (await resp.json()) as T;
  }

  async healthz(): Promise<boolean> {
    const resp = await this.#fetch(`${this.baseUrl}/healthz`);
    return resp.ok;
  }

  // ---- Repos & Tokens ----

  createRepo(name: string): Promise<Repo> {
    return this.#json("POST", "/v1/repos", { name });
  }

  async listRepos(): Promise<Repo[]> {
    const res = await this.#json<{ repos: Repo[] }>("GET", "/v1/repos");
    return res.repos;
  }

  getRepo(name: string): Promise<Repo> {
    return this.#json("GET", `/v1/repos/${name}`);
  }

  async deleteRepo(name: string): Promise<void> {
    await this.#request("DELETE", `/v1/repos/${name}`);
  }

  createToken(opts: TokenOptions): Promise<TokenResponse> {
    return this.#json("POST", "/v1/tokens", opts);
  }

  async revokeToken(jti: string): Promise<void> {
    await this.#request("POST", `/v1/tokens/${encodeURIComponent(jti)}/revoke`);
  }

  // ---- Branches ----

  async listBranches(repo: string): Promise<Branch[]> {
    const res = await this.#json<{ branches: Branch[] }>("GET", `/v1/repos/${repo}/branches`);
    return res.branches;
  }

  createBranch(
    repo: string,
    opts: { name: string; from: string; ttl_seconds?: number },
  ): Promise<{ name: string; commit: string }> {
    return this.#json("POST", `/v1/repos/${repo}/branches`, opts);
  }

  async deleteBranch(repo: string, name: string, expected?: string): Promise<void> {
    const q = expected ? `?expected=${encodeURIComponent(expected)}` : "";
    await this.#request("DELETE", `/v1/repos/${repo}/branches/${encodePath(name)}${q}`);
  }

  lockBranch(repo: string, name: string, reason = ""): Promise<{ branch: string; locked: boolean; reason: string }> {
    return this.#json("PUT", `/v1/repos/${repo}/branches/${encodePath(name)}/lock`, { reason });
  }

  async unlockBranch(repo: string, name: string): Promise<void> {
    await this.#request("DELETE", `/v1/repos/${repo}/branches/${encodePath(name)}/lock`);
  }

  createRule(repo: string, opts: CreateRuleOptions): Promise<BranchRule> {
    return this.#json("POST", `/v1/repos/${repo}/rules`, opts);
  }

  async listRules(repo: string): Promise<BranchRule[]> {
    const res = await this.#json<{ rules: BranchRule[] }>("GET", `/v1/repos/${repo}/rules`);
    return res.rules;
  }

  async deleteRule(repo: string, id: number): Promise<void> {
    await this.#request("DELETE", `/v1/repos/${repo}/rules/${id}`);
  }

  // ---- Files, Trees, History ----

  async readFile(repo: string, path: string, ref?: string): Promise<Uint8Array> {
    const q = ref ? `?ref=${encodeURIComponent(ref)}` : "";
    const resp = await this.#request("GET", `/v1/repos/${repo}/files/${encodePath(path)}${q}`);
    return new Uint8Array(await resp.arrayBuffer());
  }

  async readTextFile(repo: string, path: string, ref?: string): Promise<string> {
    return new TextDecoder().decode(await this.readFile(repo, path, ref));
  }

  readTree(repo: string, path?: string, ref?: string): Promise<TreeResponse> {
    const suffix = path ? `/${encodePath(path)}` : "";
    const q = ref ? `?ref=${encodeURIComponent(ref)}` : "";
    return this.#json("GET", `/v1/repos/${repo}/tree${suffix}${q}`);
  }

  async log(repo: string, opts: { ref?: string; limit?: number; path?: string } = {}): Promise<CommitInfo[]> {
    const params = new URLSearchParams();
    if (opts.ref) params.set("ref", opts.ref);
    if (opts.limit !== undefined) params.set("limit", String(opts.limit));
    if (opts.path) params.set("path", opts.path);
    const qs = params.toString();
    const res = await this.#json<{ commits: CommitInfo[] }>("GET", `/v1/repos/${repo}/log${qs ? `?${qs}` : ""}`);
    return res.commits;
  }

  getCommit(repo: string, sha: string): Promise<CommitInfo> {
    return this.#json("GET", `/v1/repos/${repo}/commits/${encodeURIComponent(sha)}`);
  }

  postCheck(
    repo: string,
    sha: string,
    opts: { name: string; status: CheckStatus; summary?: string; url?: string },
  ): Promise<CommitCheck & { sha: string }> {
    return this.#json("POST", `/v1/repos/${repo}/commits/${encodeURIComponent(sha)}/checks`, opts);
  }

  listChecks(repo: string, sha: string): Promise<CommitCheckList> {
    return this.#json("GET", `/v1/repos/${repo}/commits/${encodeURIComponent(sha)}/checks`);
  }

  // ---- Commits, Compare, Merge ----

  commit(repo: string, opts: CommitOptions): Promise<CommitResult> {
    return this.#json("POST", `/v1/repos/${repo}/commits`, opts);
  }

  /**
   * Commits to `branch` using compare-and-swap, retrying on 409 conflicts.
   * `build` is called on each attempt with the latest known head commit SHA
   * (or `null` if the branch does not exist yet).
   */
  async commitWithRetry(
    repo: string,
    branch: string,
    build: (head: string | null) => Promise<Omit<CommitOptions, "branch" | "expected_head">> | Omit<CommitOptions, "branch" | "expected_head">,
    opts: { maxAttempts?: number; initialHead?: string | null } = {},
  ): Promise<CommitResult> {
    const maxAttempts = opts.maxAttempts ?? 5;
    let head: string | null;
    if (opts.initialHead !== undefined) {
      head = opts.initialHead;
    } else {
      const branches = await this.listBranches(repo);
      head = branches.find((b) => b.name === branch)?.commit ?? null;
    }
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const payload = await build(head);
      try {
        return await this.commit(repo, {
          ...payload,
          branch,
          expected_head: head,
        });
      } catch (err) {
        if (err instanceof ConflictError && attempt + 1 < maxAttempts) {
          head = err.currentHead;
          continue;
        }
        throw err;
      }
    }
    throw new Error("unreachable");
  }

  compare(repo: string, base: string, head: string): Promise<CompareResult> {
    return this.#json("GET", `/v1/repos/${repo}/compare/${encodePath(base)}...${encodePath(head)}`);
  }

  merge(repo: string, opts: MergeOptions): Promise<MergeResult> {
    return this.#json("POST", `/v1/repos/${repo}/merges`, opts);
  }

  mergeDryRun(repo: string, opts: Omit<MergeOptions, "dry_run">): Promise<DryRunMergeResult> {
    return this.#json("POST", `/v1/repos/${repo}/merges`, { ...opts, dry_run: true });
  }

  checkMergeConflicts(
    repo: string,
    opts: { base: string; heads: string[]; include_file_overlaps?: boolean },
  ): Promise<MergeCheckResult> {
    return this.#json("POST", `/v1/repos/${repo}/merges/check`, opts);
  }

  batchMerge(repo: string, opts: BatchMergeOptions): Promise<BatchMergeResult> {
    return this.#json("POST", `/v1/repos/${repo}/merges/batch`, opts);
  }

  /** Wait over live SSE until every SHA in `shas` has all `requiredChecks` passing. */
  async waitForChecks(
    repo: string,
    shas: string[],
    opts: { requiredChecks?: string[]; timeoutMs?: number } = {},
  ): Promise<Record<string, CommitChecksResult>> {
    const required = opts.requiredChecks ?? [];
    const unique = [...new Set(shas)];
    const results: Record<string, CommitChecksResult> = {};
    const satisfied = (res: CommitChecksResult): boolean => {
      if (required.length === 0) return res.rollup === "passed";
      const byName = new Map(res.checks.map((c) => [c.name, c.status]));
      return required.every((name) => byName.get(name) === "passed");
    };
    const failed = (res: CommitChecksResult): boolean => {
      if (required.length === 0) return res.rollup === "failed";
      const byName = new Map(res.checks.map((c) => [c.name, c.status]));
      return required.some((name) => byName.get(name) === "failed");
    };

    const history = await this.listEvents(repo, { limit: 1 });
    const afterId = history.events.length > 0 ? history.events[history.events.length - 1].id : 0;

    const pending = new Set<string>();
    for (const sha of unique) {
      const res = await this.listChecks(repo, sha);
      results[sha] = res;
      if (failed(res)) {
        throw new Error(`checks failed on ${sha.slice(0, 10)}`);
      }
      if (!satisfied(res)) pending.add(sha);
    }
    if (pending.size === 0) return results;

    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), opts.timeoutMs ?? 60_000);
    try {
      for await (const ev of this.streamEvents(repo, { after: afterId, kind: "check_updated", signal: ac.signal })) {
        const sha = ev.new;
        if (!pending.has(sha)) continue;
        const res = await this.listChecks(repo, sha);
        results[sha] = res;
        if (failed(res)) {
          throw new Error(`checks failed on ${sha.slice(0, 10)}`);
        }
        if (satisfied(res)) {
          pending.delete(sha);
          if (pending.size === 0) {
            ac.abort();
            return results;
          }
        }
      }
    } catch (err) {
      if (pending.size === 0) return results;
      if (ac.signal.aborted) throw new Error(`timed out waiting for checks on ${[...pending].join(", ")}`);
      throw err;
    } finally {
      clearTimeout(timer);
    }
    return results;
  }

  planWaveMerge(
    repo: string,
    base: string,
    heads: string[],
    opts: { includeFileOverlaps?: boolean } = {},
  ): Promise<MergeCheckResult> {
    return this.checkMergeConflicts(repo, {
      base,
      heads,
      include_file_overlaps: opts.includeFileOverlaps ?? true,
    });
  }

  /**
   * Integrate a wave of parallel agent branches into `base`:
   * 1. Optionally waits over SSE for `requiredChecks` on all heads.
   * 2. Plans clean heads vs conflict clusters via Conflict Radar (`/merges/check`).
   * 3. Atomically batch-merges all `clean_heads` in one CAS call (`/merges/batch`).
   * 4. Invokes `resolveCluster` (if supplied) for each conflict cluster and merges the result.
   */
  async integrateWave(repo: string, opts: IntegrateWaveOptions): Promise<IntegrateWaveResult> {
    const deleteHeads = opts.deleteHeads ?? true;
    const strategy = opts.strategy ?? "merge";

    if (opts.requiredChecks && opts.requiredChecks.length > 0) {
      const branches = await this.listBranches(repo);
      const byName = new Map(branches.map((b) => [b.name, b.commit]));
      const shas = opts.heads.map((h) => byName.get(h)).filter((s): s is string => Boolean(s));
      if (shas.length > 0) {
        await this.waitForChecks(repo, shas, {
          requiredChecks: opts.requiredChecks,
          timeoutMs: opts.timeoutMs,
        });
      }
    }

    const plan = await this.planWaveMerge(repo, opts.base, opts.heads);
    const batchMerged: string[] = [];
    const clusterMerged: string[] = [];
    const deletedHeads: string[] = [];
    const unresolvedClusters: ConflictCluster[] = [];
    let latestSha: string | null = plan.base_sha;

    if (plan.clean_heads.length > 0) {
      const res = await this.batchMerge(repo, {
        base: opts.base,
        heads: plan.clean_heads,
        strategy,
        delete_heads: deleteHeads,
      });
      latestSha = res.sha;
      batchMerged.push(...res.merged_heads);
      deletedHeads.push(...res.deleted_heads);
    }

    for (const cluster of plan.conflict_clusters) {
      if (!opts.resolveCluster) {
        unresolvedClusters.push(cluster);
        continue;
      }
      const resolvedBranch = await opts.resolveCluster(cluster);
      if (!resolvedBranch) {
        unresolvedClusters.push(cluster);
        continue;
      }
      if (opts.requiredChecks && opts.requiredChecks.length > 0) {
        const branches = await this.listBranches(repo);
        const sha = branches.find((b) => b.name === resolvedBranch)?.commit;
        if (sha) {
          await this.waitForChecks(repo, [sha], {
            requiredChecks: opts.requiredChecks,
            timeoutMs: opts.timeoutMs,
          });
        }
      }
      const res = await this.merge(repo, {
        base: opts.base,
        head: resolvedBranch,
        strategy,
        delete_head: deleteHeads,
      });
      latestSha = res.sha;
      clusterMerged.push(resolvedBranch);
      if (res.head_deleted) deletedHeads.push(resolvedBranch);
    }

    return {
      base: opts.base,
      sha: latestSha,
      batchMerged,
      clusterMerged,
      deletedHeads,
      unresolvedClusters,
      blockedHeads: plan.blocked_heads,
    };
  }

  // ---- Grep, Archive, Sync ----

  grep(repo: string, query: string, opts: GrepOptions = {}): Promise<GrepResult> {
    const params = new URLSearchParams({ q: query });
    if (opts.ref) params.set("ref", opts.ref);
    if (opts.path) params.set("path", opts.path);
    if (opts.fixed) params.set("fixed", "1");
    if (opts.ignoreCase) params.set("ignore_case", "1");
    if (opts.limit !== undefined) params.set("limit", String(opts.limit));
    return this.#json("GET", `/v1/repos/${repo}/grep?${params.toString()}`);
  }

  async archive(repo: string, opts: ArchiveOptions = {}): Promise<Uint8Array> {
    const params = new URLSearchParams();
    if (opts.ref) params.set("ref", opts.ref);
    if (opts.format) params.set("format", opts.format);
    if (opts.path) params.set("path", opts.path);
    const qs = params.toString();
    const resp = await this.#request("GET", `/v1/repos/${repo}/archive${qs ? `?${qs}` : ""}`);
    return new Uint8Array(await resp.arrayBuffer());
  }

  sync(repo: string, opts: SyncOptions): Promise<SyncResult> {
    return this.#json("POST", `/v1/repos/${repo}/sync`, opts);
  }

  // ---- Webhooks ----

  createWebhook(repo: string, url: string): Promise<Webhook> {
    return this.#json("POST", `/v1/repos/${repo}/webhooks`, { url });
  }

  async listWebhooks(repo: string): Promise<Webhook[]> {
    const res = await this.#json<{ webhooks: Webhook[] }>("GET", `/v1/repos/${repo}/webhooks`);
    return res.webhooks;
  }

  async deleteWebhook(repo: string, id: number): Promise<void> {
    await this.#request("DELETE", `/v1/repos/${repo}/webhooks/${id}`);
  }

  async listWebhookDeliveries(repo: string, limit?: number): Promise<unknown[]> {
    const q = limit !== undefined ? `?limit=${limit}` : "";
    const res = await this.#json<{ deliveries: unknown[] }>("GET", `/v1/repos/${repo}/webhooks/deliveries${q}`);
    return res.deliveries;
  }

  // ---- Quotas, Stats & Maintenance ----

  getQuotas(repo: string): Promise<RepoQuotas> {
    return this.#json("GET", `/v1/repos/${repo}/quotas`);
  }

  setQuotas(repo: string, opts: { max_branches?: number; max_repo_bytes?: number }): Promise<RepoQuotas> {
    return this.#json("PUT", `/v1/repos/${repo}/quotas`, {
      max_branches: opts.max_branches ?? 0,
      max_repo_bytes: opts.max_repo_bytes ?? 0,
    });
  }

  getStats(repo: string): Promise<RepoStats> {
    return this.#json("GET", `/v1/repos/${repo}/stats`);
  }

  gc(repo: string, opts: { prune_seconds?: number } = {}): Promise<GcResult> {
    return this.#json("POST", `/v1/repos/${repo}/gc`, opts.prune_seconds !== undefined ? opts : undefined);
  }

  // ---- Events & Live SSE Stream ----

  listEvents(
    repo: string,
    opts: EventQueryOptions = {},
  ): Promise<{ events: RepoEvent[]; next_after: number }> {
    const params = new URLSearchParams();
    if (opts.after !== undefined) params.set("after", String(opts.after));
    if (opts.kind) params.set("kind", opts.kind);
    if (opts.ref) params.set("ref", opts.ref);
    if (opts.limit !== undefined) params.set("limit", String(opts.limit));
    const qs = params.toString();
    return this.#json("GET", `/v1/repos/${repo}/events${qs ? `?${qs}` : ""}`);
  }

  async *streamEvents(
    repo: string,
    opts: Omit<EventQueryOptions, "limit"> & { signal?: AbortSignal } = {},
  ): AsyncGenerator<RepoEvent> {
    const params = new URLSearchParams({ stream: "1" });
    if (opts.after !== undefined) params.set("after", String(opts.after));
    if (opts.kind) params.set("kind", opts.kind);
    if (opts.ref) params.set("ref", opts.ref);
    const resp = await this.#fetch(`${this.baseUrl}/v1/repos/${repo}/events?${params.toString()}`, {
      method: "GET",
      headers: {
        authorization: `Bearer ${this.token}`,
        accept: "text/event-stream",
      },
      signal: opts.signal,
    });
    if (!resp.ok || !resp.body) {
      throw new GitdError(resp.status, `http_${resp.status}`, resp.statusText);
    }
    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let dataLines: string[] = [];
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let nl: number;
        while ((nl = buf.indexOf("\n")) !== -1) {
          let line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (line.endsWith("\r")) line = line.slice(0, -1);
          if (line === "") {
            if (dataLines.length > 0) {
              const payload = dataLines.join("\n");
              dataLines = [];
              yield JSON.parse(payload) as RepoEvent;
            }
          } else if (line.startsWith("data:")) {
            dataLines.push(line.slice(5).trimStart());
          }
        }
      }
    } finally {
      await reader.cancel().catch(() => {});
    }
  }
}
