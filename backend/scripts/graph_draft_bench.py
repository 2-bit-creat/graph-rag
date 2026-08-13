"""Latency/quality bench for the graph-draft extraction call.

The draft is one LLM call whose cost is almost entirely DECODED TOKENS — the
user watches a spinner while ~120 tokens per claim are generated one at a time.
Observed on gpt-4o-mini: 10 s for a 5-claim diary, 42 s for an 8-claim chat log.
Trimming the schema helps; the other lever is the model, and that is a judgement
call about quality that nobody should make from a vibe. This replays REAL
prompts against N models and prints latency next to what each one produced.

It reads prompts straight out of the pipeline traces the app already writes
(``backend/debug_runs/<entry>/trace.json``), so the input is exactly what
production sent — no synthetic fixture that drifts from the real prompt.

REAL API CALLS, REAL COST. One call per (trace × model); a handful of traces
against three models is a few cents on mini-class models.

Usage:
    python -m scripts.graph_draft_bench --models gpt-4o-mini,gpt-4.1-mini
    python -m scripts.graph_draft_bench --models gpt-4o-mini --limit 3 --repeat 2

Read the output as: same claim count and same coverage score = same extraction,
so a lower p50 is free speed. A model that drops claims or coverage is NOT a
drop-in replacement no matter how fast it is — check `report.md`-style detail by
re-running with --dump.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.routers import kg_build  # noqa: E402
from app.text_coverage import native_ngram_coverage  # noqa: E402

DEBUG_RUNS = Path(__file__).resolve().parents[1] / "debug_runs"


def _load_cases(limit: int) -> list[dict[str, Any]]:
    """Every stored graph-draft step, newest first."""
    cases: list[dict[str, Any]] = []
    traces = sorted(
        DEBUG_RUNS.glob("*/trace.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for path in traces:
        try:
            trace = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        for step in trace.get("steps", []):
            if step.get("name") != "statement_graph_draft":
                continue
            system_prompt = step.get("system_prompt")
            user_prompt = (step.get("input") or {}).get("user_prompt")
            if not system_prompt or not user_prompt:
                continue
            cases.append(
                {
                    "entry": path.parent.name[:8],
                    "system_prompt": system_prompt,
                    "user_prompt": user_prompt,
                    "baseline_latency_ms": step.get("latency_ms"),
                    "baseline_claims": len(
                        ((step.get("output") or {}).get("claims")) or []
                    ),
                }
            )
            if len(cases) >= limit:
                return cases
    return cases


def _source_text(user_prompt: str) -> str:
    """The transcript portion of the prompt, for scoring coverage."""
    for marker in ("--- Source text", "--- Diary text", "--- Source"):
        head, sep, tail = user_prompt.partition(marker)
        if sep:
            return tail.split("---")[0].strip()
    return user_prompt


async def _run_one(model: str, case: dict[str, Any]) -> dict[str, Any]:
    started = time.perf_counter()
    resp = await kg_build._llm_client().chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": case["system_prompt"]},
            {"role": "user", "content": case["user_prompt"]},
        ],
        temperature=0.2,
        response_format=kg_build._EXTRACTION_RESPONSE_FORMAT,
    )
    elapsed_ms = int((time.perf_counter() - started) * 1000)
    raw = resp.choices[0].message.content or "{}"
    result = kg_build._parse_llm_json(raw)
    statements = kg_build._claim_statements(result)
    usage = getattr(resp, "usage", None)
    return {
        "model": model,
        "entry": case["entry"],
        "latency_ms": elapsed_ms,
        "claims": len(statements),
        "completion_tokens": getattr(usage, "completion_tokens", None),
        "coverage": round(
            native_ngram_coverage(_source_text(case["user_prompt"]), " ".join(statements)),
            3,
        ),
        "finish_reason": getattr(resp.choices[0], "finish_reason", None),
        "result": result,
    }


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--models",
        default="gpt-4o-mini",
        help="comma-separated model ids to compare",
    )
    parser.add_argument("--limit", type=int, default=5, help="how many stored drafts to replay")
    parser.add_argument("--repeat", type=int, default=1, help="runs per (draft, model)")
    parser.add_argument("--dump", type=Path, help="write every raw result as JSON here")
    args = parser.parse_args()

    cases = _load_cases(args.limit)
    if not cases:
        print(f"no statement_graph_draft steps found under {DEBUG_RUNS}", file=sys.stderr)
        return 1

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    rows: list[dict[str, Any]] = []
    for case in cases:
        print(
            f"\nentry {case['entry']}  "
            f"(production: {case['baseline_latency_ms']} ms, "
            f"{case['baseline_claims']} claims)"
        )
        for model in models:
            for _ in range(args.repeat):
                try:
                    row = await _run_one(model, case)
                except Exception as exc:  # noqa: BLE001 — one bad model must not end the run
                    print(f"  {model:<20} FAILED: {exc}")
                    continue
                rows.append(row)
                print(
                    f"  {model:<20} {row['latency_ms']:>6} ms  "
                    f"claims={row['claims']:<3} coverage={row['coverage']:<5} "
                    f"out_tokens={row['completion_tokens']}"
                )

    print("\n── per-model summary ─────────────────────────────")
    for model in models:
        got = [r for r in rows if r["model"] == model]
        if not got:
            continue
        lat = sorted(r["latency_ms"] for r in got)
        print(
            f"{model:<20} n={len(got):<3} "
            f"median={statistics.median(lat):>6.0f} ms  max={lat[-1]:>6} ms  "
            f"claims={statistics.mean(r['claims'] for r in got):.1f}  "
            f"coverage={statistics.mean(r['coverage'] for r in got):.3f}"
        )
    print(
        "\nSame claims + same coverage as the baseline model means the swap is "
        "free speed; fewer claims or lower coverage means it is not a drop-in."
    )

    if args.dump:
        args.dump.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nraw results → {args.dump}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
