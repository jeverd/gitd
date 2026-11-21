"""Render gitd benchmark results JSON into a pure black-and-white HTML page.

Usage:
    python3 tests/bench/render_html.py \
        --suite-json tests/bench/results/c7i-2xlarge/suite/results.json \
        --forges-json tests/bench/results/c7i-2xlarge/forges/results.json \
        --out tests/bench/results/c7i-2xlarge/index.html
"""

from __future__ import annotations

import argparse
import html
import json
import os
import sys
from pathlib import Path
from typing import Any

BENCH_DIR = Path(__file__).resolve().parent
if str(BENCH_DIR) not in sys.path:
    sys.path.insert(0, str(BENCH_DIR))

import common  # noqa: E402

CSS = """\
:root {
  --bg: #ffffff;
  --fg: #000000;
  --muted: #555555;
  --border: #000000;
  --hair: #dcdcdc;
  --track: #f3f3f3;
}
* { box-sizing: border-box; }
html, body {
  margin: 0;
  padding: 0;
  background: var(--bg);
  color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  font-size: 14px;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}
main {
  max-width: 980px;
  margin: 0 auto;
  padding: 40px 24px 72px;
}
header {
  border-bottom: 2px solid var(--border);
  padding-bottom: 18px;
  margin-bottom: 28px;
}
.title-row {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: baseline;
  gap: 12px;
}
h1 {
  margin: 0;
  font-size: 28px;
  font-weight: 700;
  letter-spacing: -0.02em;
}
.status {
  display: inline-block;
  padding: 3px 9px;
  border: 1px solid var(--border);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}
.status.live {
  background: #000000;
  color: #ffffff;
}
.status.done {
  background: #ffffff;
  color: #000000;
}
.subtitle {
  margin: 8px 0 0;
  color: var(--muted);
  font-size: 13px;
}
.env-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 20px;
  margin-top: 14px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px;
  color: var(--fg);
}
.env-grid span strong {
  font-weight: 600;
}
.kpi-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 12px;
  margin-bottom: 36px;
}
@media (max-width: 760px) {
  .kpi-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
.kpi {
  border: 1px solid var(--border);
  padding: 14px 16px;
}
.kpi .label {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--muted);
}
.kpi .value {
  margin-top: 4px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 24px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.kpi .detail {
  margin-top: 4px;
  font-size: 12px;
  color: var(--muted);
}
section {
  margin-top: 38px;
}
h2 {
  margin: 0 0 6px;
  font-size: 17px;
  font-weight: 700;
  letter-spacing: -0.01em;
  border-bottom: 1px solid var(--border);
  padding-bottom: 6px;
}
h3 {
  margin: 22px 0 8px;
  font-size: 13px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
p.lead {
  margin: 6px 0 14px;
  color: var(--muted);
  font-size: 13px;
}
.note {
  border-left: 2px solid var(--border);
  background: var(--track);
  padding: 10px 14px;
  margin: 12px 0 16px;
  font-size: 13px;
}
.pending-box {
  border: 1px dashed var(--border);
  background: var(--track);
  padding: 20px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 13px;
}
table {
  width: 100%;
  border-collapse: collapse;
  margin: 10px 0 18px;
  font-size: 13px;
}
th, td {
  padding: 8px 10px;
  border-bottom: 1px solid var(--hair);
  vertical-align: middle;
}
thead th {
  border-top: 1px solid var(--border);
  border-bottom: 1px solid var(--border);
  background: var(--track);
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  text-align: left;
  white-space: nowrap;
}
th.num, td.num {
  text-align: right;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
td.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-variant-numeric: tabular-nums;
}
tr.bold-row td {
  font-weight: 700;
}
.bars {
  margin: 12px 0 22px;
  border: 1px solid var(--hair);
  padding: 14px 16px;
}
.bars-title {
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 10px;
  color: var(--muted);
}
.bar-group {
  margin-bottom: 12px;
}
.bar-group:last-child {
  margin-bottom: 0;
}
.bar-group-label {
  font-size: 12px;
  font-weight: 600;
  margin-bottom: 4px;
}
.bar-row {
  display: grid;
  grid-template-columns: 120px 1fr 84px;
  align-items: center;
  gap: 10px;
  margin: 3px 0;
  font-size: 12px;
}
.bar-label {
  color: var(--muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.bar-track {
  height: 12px;
  background: var(--track);
  border: 1px solid var(--hair);
  position: relative;
}
.bar-fill {
  height: 100%;
  background: #000000;
}
.bar-fill.muted {
  background: #888888;
}
.bar-fill.light {
  background: #c8c8c8;
}
.bar-val {
  text-align: right;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-variant-numeric: tabular-nums;
}
.two-col {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 18px;
}
@media (max-width: 760px) {
  .two-col { grid-template-columns: 1fr; }
}
footer {
  margin-top: 48px;
  padding-top: 14px;
  border-top: 1px solid var(--hair);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px;
  color: var(--muted);
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  gap: 8px;
}
"""


def _esc(v: Any) -> str:
    return html.escape(str(v), quote=True)


def _table(headers: list[tuple[str, bool]], rows: list[list[tuple[Any, str]]]) -> str:
    ths = "".join(
        f'<th class="{"num" if is_num else ""}">{_esc(label)}</th>'
        for label, is_num in headers
    )
    trs: list[str] = []
    for row in rows:
        tds = "".join(
            f'<td class="{cls}">{val}</td>' for val, cls in row
        )
        trs.append(f"<tr>{tds}</tr>")
    return (
        "<table><thead><tr>"
        + ths
        + "</tr></thead><tbody>"
        + "".join(trs)
        + "</tbody></table>"
    )


def _bar_width(val: float, max_val: float) -> float:
    if max_val <= 0 or val <= 0:
        return 0.0
    return max(0.8, min(100.0, (val / max_val) * 100.0))


def _render_kpis(suite: dict[str, Any] | None, forges: dict[str, Any] | None) -> str:
    cards: list[tuple[str, str, str]] = []
    if suite:
        b1_rows = suite.get("b1_zero_clone", {}).get("edit_loop", [])
        if b1_rows:
            best = max(b1_rows, key=lambda r: r.get("speedup_vs_full_p50", 0))
            cards.append(
                (
                    "Max Zero-Clone Speedup",
                    f"{best['speedup_vs_full_p50']}x",
                    f"{best['source']} ({best['files']:,} files) vs. full clone",
                )
            )
        b2_rows = suite.get("b2_fanout_fanin", {}).get("sweep", [])
        if b2_rows:
            peak_tp = max(b2_rows, key=lambda r: r.get("commits_per_sec", 0))
            cards.append(
                (
                    "Peak Commit Throughput",
                    f"{peak_tp['commits_per_sec']}/s",
                    f"at {peak_tp['agents']} concurrent agents",
                )
            )
        b3_rows = suite.get("b3_cas_race", [])
        if b3_rows:
            total_landed = sum(r["verified_commits"] for r in b3_rows)
            total_lost = sum(r["lost_updates"] for r in b3_rows)
            total_conflicts = sum(r["total_conflicts"] for r in b3_rows)
            cards.append(
                (
                    "CAS Lost Updates",
                    str(total_lost),
                    f"{total_landed} commits / {total_conflicts:,} 409 retries",
                )
            )
        rss = suite.get("rss") or {}
        if rss.get("idle_mib") is not None:
            cards.append(
                (
                    "Memory Footprint",
                    f"{rss['idle_mib']} MiB",
                    f"idle RSS · {rss['peak_mib']} MiB peak across suite",
                )
            )
    if not cards and forges:
        rows = forges.get("results", [])
        if rows:
            g = next((r for r in rows if r["target"] == "gitd"), rows[0])
            cards.append(("Cold Start", common.format_ms(g["cold_start_ms"]["p50"]), f"{g['target']} container"))
    if not cards:
        return ""
    items = []
    for label, val, detail in cards:
        items.append(
            f'<div class="kpi"><div class="label">{_esc(label)}</div>'
            f'<div class="value">{_esc(val)}</div>'
            f'<div class="detail">{_esc(detail)}</div></div>'
        )
    return '<div class="kpi-grid">' + "".join(items) + "</div>"


def _render_b1(b1: dict[str, Any]) -> str:
    edit_rows = b1.get("edit_loop", [])
    rows = []
    for r in edit_rows:
        rows.append(
            [
                (_esc(f"{r['size']} ({r['source']}, {r['files']:,} files)"), ""),
                (_esc(common.format_ms(r["api_total_ms"]["p50"])), "num"),
                (_esc(common.format_ms(r["api_total_ms"]["p95"])), "num"),
                (_esc(common.format_ms(r["shallow_total_ms"]["p50"])), "num"),
                (_esc(common.format_ms(r["full_total_ms"]["p50"])), "num"),
                (_esc(f"{r['speedup_vs_shallow_p50']}x / {r['speedup_vs_full_p50']}x"), "num"),
                (_esc(f"0 B / {common.format_bytes(r['shallow_disk_bytes'])}"), "num"),
            ]
        )
    tbl = _table(
        [
            ("Repository", False),
            ("API p50", True),
            ("API p95", True),
            ("Shallow p50", True),
            ("Full p50", True),
            ("Speedup (Shallow / Full)", True),
            ("Client Disk (API / Shallow)", True),
        ],
        rows,
    )

    bars_html = ""
    if edit_rows:
        groups = []
        for r in edit_rows:
            api_v = r["api_total_ms"]["p50"]
            sh_v = r["shallow_total_ms"]["p50"]
            fu_v = r["full_total_ms"]["p50"]
            mx = max(api_v, sh_v, fu_v, 1.0)
            groups.append(
                f'<div class="bar-group">'
                f'<div class="bar-group-label">{_esc(r["source"])} ({r["files"]:,} files, {r["commits"]:,} commits)</div>'
                f'<div class="bar-row"><span class="bar-label">gitd API</span><div class="bar-track"><div class="bar-fill" style="width:{_bar_width(api_v, mx):.1f}%"></div></div><span class="bar-val">{_esc(common.format_ms(api_v))}</span></div>'
                f'<div class="bar-row"><span class="bar-label">shallow clone</span><div class="bar-track"><div class="bar-fill muted" style="width:{_bar_width(sh_v, mx):.1f}%"></div></div><span class="bar-val">{_esc(common.format_ms(sh_v))}</span></div>'
                f'<div class="bar-row"><span class="bar-label">full clone</span><div class="bar-track"><div class="bar-fill light" style="width:{_bar_width(fu_v, mx):.1f}%"></div></div><span class="bar-val">{_esc(common.format_ms(fu_v))}</span></div>'
                f"</div>"
            )
        bars_html = '<div class="bars"><div class="bars-title">End-to-End p50 Latency Comparison (per repository scale)</div>' + "".join(groups) + "</div>"

    arch_html = ""
    arch_rows = b1.get("subdir_archive", [])
    if arch_rows:
        ar = [
            [
                (f"{_esc(a['size'])} (<code>{_esc(a['subdir'])}</code>)", ""),
                (_esc(common.format_ms(a["archive_extract_ms"]["p50"])), "num"),
                (_esc(common.format_bytes(a["archive_wire_bytes"])), "num"),
                (_esc(common.format_ms(a["shallow_clone_ms"]["p50"])), "num"),
                (_esc(common.format_bytes(a["shallow_disk_bytes"])), "num"),
            ]
            for a in arch_rows
        ]
        arch_html = (
            "<h3>Subdirectory Archive (GET /archive?path=...) vs. Shallow Clone</h3>"
            + _table(
                [
                    ("Repo / Subdir", False),
                    ("Archive+Extract p50", True),
                    ("Archive Wire", True),
                    ("Shallow Clone p50", True),
                    ("Shallow Disk", True),
                ],
                ar,
            )
        )

    return (
        "<section>"
        "<h2>1. Zero-Clone API Loop vs. git clone -&gt; edit -&gt; git push</h2>"
        '<p class="lead"><code>GET /grep</code> -&gt; <code>GET /files</code> -&gt; <code>POST /commits</code> (0 B local checkout) compared against cloning, grepping, committing, and pushing with <code>git</code>.</p>'
        + tbl
        + bars_html
        + arch_html
        + "</section>"
    )


def _render_b2(b2: dict[str, Any]) -> str:
    sweep = b2.get("sweep", [])
    rows = []
    for r in sweep:
        rss_s = f"{r['peak_rss_mib']} MiB" if r.get("peak_rss_mib") is not None else "-"
        rows.append(
            [
                (_esc(r["agents"]), "num"),
                (_esc(r["total_commits"]), "num"),
                (_esc(f"{r['commits_per_sec']}/s"), "num"),
                (_esc(common.format_ms(r["commit_ms"]["p50"])), "num"),
                (_esc(common.format_ms(r["commit_ms"]["p95"])), "num"),
                (_esc(common.format_ms(r["commit_ms"]["p99"])), "num"),
                (_esc(common.format_ms(r["compare_ms"]["p50"])), "num"),
                (_esc(common.format_ms(r["merge_ms"])), "num"),
                (_esc(rss_s), "num"),
            ]
        )
    tbl = _table(
        [
            ("Agents", True),
            ("Commits", True),
            ("Throughput", True),
            ("Commit p50", True),
            ("Commit p95", True),
            ("Commit p99", True),
            ("Compare p50", True),
            ("Merge", True),
            ("Peak RSS", True),
        ],
        rows,
    )

    bars_html = ""
    if sweep:
        mx = max((r["commits_per_sec"] for r in sweep), default=1.0)
        b_rows = "".join(
            f'<div class="bar-row"><span class="bar-label">{r["agents"]} agent(s)</span>'
            f'<div class="bar-track"><div class="bar-fill" style="width:{_bar_width(r["commits_per_sec"], mx):.1f}%"></div></div>'
            f'<span class="bar-val">{r["commits_per_sec"]}/s</span></div>'
            for r in sweep
        )
        bars_html = '<div class="bars"><div class="bars-title">Aggregate Throughput (commits/sec)</div>' + b_rows + "</div>"

    reaper = b2.get("reaper") or {}
    reaper_note = ""
    if reaper:
        reaper_note = (
            f'<div class="note"><strong>Branch Expiry Reaper:</strong> drained '
            f'<code>{reaper["branches"]}</code> expired branches in '
            f'<strong>{reaper["drain_after_ttl_s"]} s</strong> after {reaper["ttl_seconds"]}s TTL.</div>'
        )

    return (
        "<section>"
        "<h2>2. Multi-Agent Fan-Out &amp; Fan-In Concurrency Scaling</h2>"
        '<p class="lead">Concurrent agents minting scoped tokens, committing to isolated branches on a 500-file repo, comparing against <code>main</code>, and merging the winner.</p>'
        + tbl
        + bars_html
        + reaper_note
        + "</section>"
    )


def _render_b3(b3: list[dict[str, Any]]) -> str:
    rows = []
    for r in b3:
        c409 = common.format_ms(r["conflict_ms"]["p50"]) if r["total_conflicts"] else "-"
        rows.append(
            [
                (_esc(r["agents"]), "num"),
                (_esc(f"{r['verified_commits']}/{r['expected_commits']}"), "num"),
                (_esc(r["lost_updates"]), "num"),
                (_esc(r["total_conflicts"]), "num"),
                (_esc(common.format_ms(r["win_ms"]["p50"])), "num"),
                (_esc(c409), "num"),
                (_esc(f"{r['retries']['p50']} / {int(r['retries']['max'])}"), "num"),
                (_esc(f"{r['landed_commits_per_sec']}/s"), "num"),
            ]
        )
    tbl = _table(
        [
            ("Agents", True),
            ("Verified Commits", True),
            ("Lost Updates", True),
            ("409 Conflicts", True),
            ("201 p50", True),
            ("409 p50", True),
            ("Retries (p50/max)", True),
            ("Landed Rate", True),
        ],
        rows,
    )
    return (
        "<section>"
        "<h2>3. CAS Contention Storm on <code>main</code></h2>"
        '<p class="lead">All agents racing concurrently to commit directly to <code>main</code> using <code>expected_head</code> compare-and-swap retries; final git log and tree archive verified for 0 lost updates.</p>'
        + tbl
        + "</section>"
    )


def _render_b4(forges: dict[str, Any] | None) -> str:
    if forges is None:
        return (
            "<section>"
            "<h2>4. Forge Comparison: gitd vs. Gitea &amp; Forgejo (Docker)</h2>"
            '<div class="pending-box">IN PROGRESS ON c7i.2xlarge — Building gitd Docker image and benchmarking Gitea &amp; Forgejo containers under identical <code>--cpus=4 --memory=4g</code> limits. This page refreshes every 10s.</div>'
            "</section>"
        )

    rows = []
    for r in forges.get("results", []):
        conc_cell = f"{common.format_ms(r['conc_commit_ms']['p50'])} ({r['conc_commits_per_sec']}/s)"
        if r.get("conc_errors", 0):
            conc_cell += f", {r['conc_errors']} err"
        rows.append(
            [
                (_esc(r["target"]), "mono"),
                (_esc(common.format_bytes(r["image_bytes"])), "num"),
                (_esc(common.format_ms(r["cold_start_ms"]["p50"])), "num"),
                (_esc(f"{r['idle_rss_mib']} MiB" if r.get("idle_rss_mib") is not None else "-"), "num"),
                (_esc(f"{r['peak_rss_mib']} MiB" if r.get("peak_rss_mib") is not None else "-"), "num"),
                (_esc(f"{r['provision_wall_s']} s ({r['provision_count']}x)"), "num"),
                (_esc(common.format_ms(r["repo_create_ms"]["p50"])), "num"),
                (_esc(common.format_ms(r["token_mint_ms"]["p50"])), "num"),
                (_esc(common.format_ms(r["seq_commit_ms"]["p50"])), "num"),
                (_esc(conc_cell), "num"),
            ]
        )
    tbl = _table(
        [
            ("Target", False),
            ("Image Size", True),
            ("Cold Start", True),
            ("Idle RSS", True),
            ("Peak RSS", True),
            ("Provision Repos+Tokens", True),
            ("Create Repo p50", True),
            ("Mint Token p50", True),
            ("Seq Commit p50", True),
            ("Conc Commit p50 (Rate)", True),
        ],
        rows,
    )
    return (
        "<section>"
        "<h2>4. Forge Comparison: gitd vs. Gitea &amp; Forgejo (Docker)</h2>"
        f'<p class="lead">Single-container SQLite runs with identical limits (<code>--cpus={_esc(forges.get("cpus", "4"))} --memory={_esc(forges.get("memory", "4g"))}</code>).</p>'
        '<div class="note"><strong>Scope note:</strong> Gitea and Forgejo are full human Git forges (web UI, PRs, issues, ORM) issuing user-level PATs; <code>gitd</code> is purpose-built minimal git storage for agents issuing repo+ref-scoped HMAC-SHA256 tokens.</div>'
        + tbl
        + "</section>"
    )


def _render_b5(b5: dict[str, Any]) -> str:
    po = b5["proxy_overhead"]
    p_rows = [
        [
            (_esc("git clone"), ""),
            (_esc(common.format_ms(po["clone"]["gitd_ms"]["p50"])), "num"),
            (_esc(common.format_ms(po["clone"]["bare_ms"]["p50"])), "num"),
            (_esc(f"{po['clone']['overhead_p50_ms']:+.1f} ms"), "num"),
        ]
    ]
    for pr in po["pushes"]:
        p_rows.append(
            [
                (_esc(f"git push ({pr['payload']})"), ""),
                (_esc(common.format_ms(pr["gitd_ms"]["p50"])), "num"),
                (_esc(common.format_ms(pr["bare_ms"]["p50"])), "num"),
                (_esc(f"{pr['overhead_p50_ms']:+.1f} ms"), "num"),
            ]
        )
    proxy_tbl = _table(
        [("Git Op", False), ("gitd p50", True), ("Bare http-backend p50", True), ("Delta", True)],
        p_rows,
    )

    g = b5["guardrails"]
    g_rows = [
        [
            (_esc("read_file"), "mono"),
            (_esc(common.format_ms(g["admin_key_ms"]["read_file_ms"]["p50"])), "num"),
            (_esc(common.format_ms(g["scoped_token_ms"]["read_file_ms"]["p50"])), "num"),
        ],
        [
            (_esc("grep"), "mono"),
            (_esc(common.format_ms(g["admin_key_ms"]["grep_ms"]["p50"])), "num"),
            (_esc(common.format_ms(g["scoped_token_ms"]["grep_ms"]["p50"])), "num"),
        ],
        [
            (_esc("commit"), "mono"),
            (_esc(common.format_ms(g["admin_key_ms"]["commit_ms"]["p50"])), "num"),
            (_esc(common.format_ms(g["scoped_token_ms"]["commit_ms"]["p50"])), "num"),
        ],
    ]
    guard_tbl = _table(
        [("Operation", False), ("Admin Key p50", True), ("Scoped Token p50", True)],
        g_rows,
    )

    mf = b5["multifile_commits"]
    mf_rows = [
        [
            (_esc(mr["files"]), "num"),
            (_esc(common.format_ms(mr["commit_ms"]["p50"])), "num"),
            (_esc(common.format_ms(mr["commit_ms"]["p95"])), "num"),
            (_esc(common.format_ms(mr["ms_per_file_p50"])), "num"),
        ]
        for mr in mf
    ]
    mf_tbl = _table(
        [("Files in Commit", True), ("p50", True), ("p95", True), ("ms / file", True)],
        mf_rows,
    )
    mx_mf = max((mr["commit_ms"]["p50"] for mr in mf), default=1.0)
    mf_bars = "".join(
        f'<div class="bar-row"><span class="bar-label">{mr["files"]} file(s)</span>'
        f'<div class="bar-track"><div class="bar-fill" style="width:{_bar_width(mr["commit_ms"]["p50"], mx_mf):.1f}%"></div></div>'
        f'<span class="bar-val">{_esc(common.format_ms(mr["commit_ms"]["p50"]))}</span></div>'
        for mr in mf
    )

    return (
        "<section>"
        "<h2>5. Smart HTTP Overhead, Guardrails &amp; Multi-File Curve</h2>"
        '<div class="two-col">'
        "<div><h3>Smart HTTP Proxy vs. Bare http-backend</h3>"
        + proxy_tbl
        + "</div>"
        "<div><h3>Guardrail Scoping Overhead</h3>"
        + guard_tbl
        + f'<div class="note">Pre-write ACL rejection on unauthorized 5 MiB <code>git push</code> to locked <code>main</code>: <strong>{_esc(common.format_ms(g["rejected_5mib_push_ms"]["p50"]))}</strong> p50 (p95 {_esc(common.format_ms(g["rejected_5mib_push_ms"]["p95"]))}, {g["revoked_tokens_seeded"]} revoked tokens checked, <code>main</code> unchanged: <code>{g["main_unchanged"]}</code>).</div>'
        + "</div>"
        "</div>"
        "<h3>Multi-File Commit Scaling (POST /commits)</h3>"
        + mf_tbl
        + '<div class="bars"><div class="bars-title">Commit p50 by File Count (2 KiB files)</div>'
        + mf_bars
        + "</div>"
        "</section>"
    )


def render_html(suite: dict[str, Any] | None, forges: dict[str, Any] | None) -> str:
    is_complete = suite is not None and forges is not None
    refresh_meta = "" if is_complete else '<meta http-equiv="refresh" content="10">'
    status_cls = "done" if is_complete else "live"
    status_text = "Complete · All 5 Benchmarks" if is_complete else "Live · B1/B2/B3/B5 Done · B4 Running"

    src = suite or forges or {}
    sysinfo = src.get("sysinfo") or {}
    rss = (suite or {}).get("rss") or {}

    env_bits: list[str] = []
    if sysinfo.get("cpu_model"):
        env_bits.append(f"<span><strong>CPU:</strong> {_esc(sysinfo['cpu_model'])} ({_esc(sysinfo.get('cpu_count', '-'))} vCPU)</span>")
    if sysinfo.get("os"):
        env_bits.append(f"<span><strong>OS:</strong> {_esc(sysinfo['os'])} ({_esc(sysinfo.get('arch', '-'))})</span>")
    if sysinfo.get("ram_gib") is not None:
        env_bits.append(f"<span><strong>RAM:</strong> {_esc(sysinfo['ram_gib'])} GiB</span>")
    if sysinfo.get("disk_fs"):
        env_bits.append(f"<span><strong>Disk:</strong> {_esc(sysinfo['disk_fs'])}</span>")
    if sysinfo.get("git_version"):
        env_bits.append(f"<span><strong>Git:</strong> {_esc(sysinfo['git_version'])}</span>")
    if sysinfo.get("gitd_bin_bytes"):
        env_bits.append(f"<span><strong>Binary:</strong> {_esc(common.format_bytes(sysinfo['gitd_bin_bytes']))}</span>")
    if rss.get("idle_mib") is not None:
        env_bits.append(f"<span><strong>RSS:</strong> {_esc(rss['idle_mib'])} MiB idle / {_esc(rss['peak_mib'])} MiB peak</span>")

    body_parts: list[str] = [_render_kpis(suite, forges)]
    if suite and "b1_zero_clone" in suite:
        body_parts.append(_render_b1(suite["b1_zero_clone"]))
    if suite and "b2_fanout_fanin" in suite:
        body_parts.append(_render_b2(suite["b2_fanout_fanin"]))
    if suite and "b3_cas_race" in suite:
        body_parts.append(_render_b3(suite["b3_cas_race"]))
    body_parts.append(_render_b4(forges))
    if suite and "b5_proxy_guardrails_limits" in suite:
        body_parts.append(_render_b5(suite["b5_proxy_guardrails_limits"]))

    issues = suite.get("server_log_issues", 0) if suite else "-"
    ts = sysinfo.get("timestamp_utc", "")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{refresh_meta}
<title>gitd Benchmark Results</title>
<style>
{CSS}
</style>
</head>
<body>
<main>
  <header>
    <div class="title-row">
      <h1>gitd Benchmarks</h1>
      <span class="status {status_cls}">{_esc(status_text)}</span>
    </div>
    <p class="subtitle">Mode: <code>{_esc(src.get('mode', 'full'))}</code> · Open-source git storage for AI agents, written in Zig</p>
    <div class="env-grid">{''.join(env_bits)}</div>
  </header>
  {''.join(body_parts)}
  <footer>
    <span>server_log_issues: {_esc(issues)}</span>
    <span>generated from JSON · {_esc(ts)}</span>
  </footer>
</main>
</body>
</html>
"""


def _load_optional_json(path: str | None) -> dict[str, Any] | None:
    if not path or not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Render black-and-white HTML benchmark report")
    ap.add_argument("--suite-json", help="Path to suite/results.json")
    ap.add_argument("--forges-json", help="Path to forges/results.json")
    ap.add_argument("--out", required=True, help="Output HTML file path")
    return ap.parse_args(argv)


def main() -> None:
    args = parse_args()
    suite = _load_optional_json(args.suite_json)
    forges = _load_optional_json(args.forges_json)
    doc = render_html(suite, forges)
    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(doc)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
