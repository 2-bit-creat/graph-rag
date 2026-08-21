"""Offline quiz-generation quality eval across native/target language pairs.

Runs REAL quiz generation (real OpenAI calls, real cost) against a fixed
golden set of statements (``backend/eval/golden_statements.json``) for one or
more (native, target) pairs, and writes a review bundle to
``backend/eval/runs/<timestamp>_<git-sha>/``:

- ``report.md``   — every generated card, rendered like a learner would see
                     it, with QA score and origin (reviewed_plan/repair).
                     Read this to judge quality.
- ``failures.md``  — every rejected candidate with its gate reason code.
                     Read this to find what to tighten next.
- ``cards.json``   — full machine-readable card + provenance dump.
- ``metrics.json`` — per-pair aggregate numbers (see below).
- ``run.json``     — argv, git sha, model ids, CLOZE_GENERATOR_VERSION.

Usage:
    python -m scripts.quiz_eval --pairs ko-en,ko-de,en-ko
    python -m scripts.quiz_eval --pairs ko-de --ids ko-003,ko-007 --compare eval/runs/<prev>
    python -m scripts.quiz_eval --pairs ko-en,ko-de,en-ko --assert-baseline eval/baseline.json

Safety: every statement is seeded into a throwaway user + Statement node in
whatever database DATABASE_URL points at (the same test-DB guard used by the
pytest suite does NOT apply here — this script does real, cost-incurring API
calls on purpose). Point DATABASE_URL at the `_test` database, never at a
database with real user data. Each pair's ephemeral user (and everything it
owns, via ON DELETE CASCADE) is deleted in a `finally` block, so a normal run
leaves nothing behind — but a killed process can leave an eval user around;
they're named `quiz-eval:<pair>:<run-id>@eval.local` and safe to delete by hand.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
import uuid
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import crud  # noqa: E402
from app.config import get_settings  # noqa: E402
from app.db import async_session_factory, init_db  # noqa: E402
from app.language_packs import target_pack  # noqa: E402
from app.languages import is_supported_pair, pair_key  # noqa: E402
from app.models import Node, Quiz, User  # noqa: E402
from app.quiz_bundle import CLOZE_GENERATOR_VERSION, BundleSeedError, generate_quiz_bundle  # noqa: E402

_GOLDEN_PATH = Path(__file__).resolve().parent.parent / "eval" / "golden_statements.json"
_RUNS_DIR = Path(__file__).resolve().parent.parent / "eval" / "runs"

_PAIR_CODES = {"ko-en": ("korean", "english"), "ko-de": ("korean", "german"), "en-ko": ("english", "korean")}

_MODEL_PRICES = {
    "gpt-4o-mini": {"input": 0.15, "cached_input": 0.075, "output": 0.60},
    "gpt-5.4-mini": {"input": 0.75, "cached_input": 0.075, "output": 4.50},
}


_CANDIDATE_PREFIX_RE = __import__("re").compile(r"^candidate \d+:\s*")


def _gate_code(reason: str) -> str:
    """Recover a stable histogram bucket from a rejection message.

    Rejection strings are ``"candidate N: <message>"``, and ``<message>``
    itself may or may not carry a ``"<code>: ..."`` prefix from
    ``language_packs.reasons`` (only pack-gate rejections do; the older
    structural checks in ``_cloze_structural_reason``/``validate_quiz_payload``
    are still free text). Strip the candidate prefix, then use the shared
    ``reasons.split_reason`` so pack-gate rejections land in the same bucket
    vocabulary the gates themselves use; anything else buckets as "uncoded"
    rather than fragmenting into one bucket per unique free-text message.
    """
    from app.language_packs.reasons import split_reason

    stripped = _CANDIDATE_PREFIX_RE.sub("", reason.strip())
    code, _message = split_reason(stripped)
    return code or "uncoded"


def _git_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=Path(__file__).resolve().parent, text=True
        ).strip()
    except Exception:
        return "unknown"


def _load_golden(ids: set[str] | None) -> list[dict]:
    data = json.loads(_GOLDEN_PATH.read_text(encoding="utf-8"))
    statements = data["statements"]
    if ids:
        statements = [
            s for s in statements
            if s["id"] in ids or str(s.get("quality_case_id") or "") in ids
        ]
    return statements


def _check_golden_expectation(
    statement: dict, views: list[dict], *, target_language: str = "english"
) -> dict | None:
    """Check a narrow semantic regression contract on the generated cards.

    Written for the current scramble/composition-only pipeline (``cloze`` is
    disabled — see ``quiz_types.ENABLED_QUIZ_TYPES``). Unlike cloze, neither
    card type has a model-generated native-language gloss to check: a
    scramble's ``question_native``/composition's ``question_native`` is the
    untranslated source statement verbatim, not something the model produced.
    So only the TARGET-language output is checked here — ``native_contains``/
    ``native_forbidden_exact`` in a golden statement's ``expect_cloze`` are
    silently unused in this mode (they were meaningful only for cloze's
    generated native gloss field, which no longer exists).
    """
    by_target = statement.get("expect_cloze_by_target") or {}
    expected = by_target.get(target_language) or statement.get("expect_cloze")
    if not isinstance(expected, dict):
        return None
    # A target_contains entry is normally one required substring. An entry
    # that is itself a list is an any-of group (e.g. synonymous domain terms
    # like "Diskontsatz"/"Abzinsungssatz" for "discount rate") — at least one
    # of its members must be present, not all of them.
    target_terms = [
        [str(v).casefold()] if not isinstance(v, list) else [str(alt).casefold() for alt in v]
        for v in expected.get("target_contains") or []
    ]
    # A word that must never appear in ANY generated target-language text for
    # this statement. Unlike the positive check above, which needs one card to
    # match and so rides on which expressions the planner happened to pick,
    # this holds for every card — the right shape for a boundary invariant
    # such as "no generated sentence may contain a possessive determiner".
    forbidden_words = {
        str(v).strip().casefold() for v in expected.get("target_forbidden_words") or []
    }
    # Every target-language string actually produced for this statement: a
    # scramble card's reference sentence, plus each composition card's model
    # answers.
    target_texts: list[str] = []
    for view in views:
        if view.get("quiz_type") == "scramble":
            text = view.get("sentence_target")
            if text:
                target_texts.append(str(text))
        elif view.get("quiz_type") == "composition":
            target_texts.extend(str(m) for m in (view.get("model_answers") or []) if m)
    violations = []
    matching = []
    for text in target_texts:
        folded = text.casefold()
        if forbidden_words & set(folded.split()):
            violations.append(text)
        if all(any(alt in folded for alt in group) for group in target_terms):
            matching.append(text)
    passed = not violations and (
        bool(matching)
        # A statement that only states a forbidden-word invariant passes on
        # not violating it; it must not require a positive match it never set.
        or not target_terms
    )
    return {
        "statement_id": statement["id"],
        "quality_case_id": statement.get("quality_case_id"),
        "passed": passed,
        "expected": expected,
        "matching_target_texts": matching,
        "forbidden_word_violations": violations,
    }


def _extract_step(trace: dict, name: str) -> dict | None:
    for step in trace.get("steps") or []:
        if step.get("name") == name:
            return step
    return None


def _accumulate_usage(value: Any, totals: dict, *, model: str) -> None:
    """Recursively total plain, list, and review/repair usage payloads."""
    if isinstance(value, list):
        for item in value:
            _accumulate_usage(item, totals, model=model)
        return
    if not isinstance(value, dict):
        return
    if "prompt_tokens" in value or "completion_tokens" in value:
        bucket = totals["by_model"].setdefault(model or "unknown", {
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "cached_prompt_tokens": 0,
            "reasoning_tokens": 0,
        })
        for key in ("prompt_tokens", "completion_tokens", "cached_prompt_tokens", "reasoning_tokens"):
            amount = int(value.get(key) or 0)
            totals[key] += amount
            bucket[key] += amount
        return
    for nested in value.values():
        _accumulate_usage(nested, totals, model=model)


def _card_view(quiz: Quiz) -> dict:
    qd = quiz.quiz_data or {}
    view = {
        "quiz_type": quiz.quiz_type,
        "question_native": quiz.question_native,
        "sentence_target": quiz.sentence_target,
    }
    if quiz.quiz_type == "cloze":
        view.update({
            # How this card was produced: directly from the independently
            # reviewed plan, or by a focused alignment repair.
            "origin": qd.get("_origin"),
            "canonical_form": qd.get("canonical_form"),
            "surface_answer": qd.get("blank"),
            "prompt_target": qd.get("prompt_en"),
            "context_native": qd.get("context_ko"),
            "target_native": qd.get("target_ko"),
        })
    else:
        view.update({
            "target_expressions": qd.get("target_expressions"),
            "model_answers": [m.get("text") for m in (qd.get("model_answers") or [])],
        })
    return view


def _estimated_usage_cost(usage: dict) -> tuple[float | None, dict[str, float]]:
    """Price recorded usage without double-counting cached prompt tokens."""
    by_model: dict[str, float] = {}
    for model, model_usage in (usage.get("by_model") or {}).items():
        prices = _MODEL_PRICES.get(model)
        if prices is None:
            return None, {}
        cached = int(model_usage.get("cached_prompt_tokens") or 0)
        prompt = int(model_usage.get("prompt_tokens") or 0)
        uncached = max(0, prompt - cached)
        completion = int(model_usage.get("completion_tokens") or 0)
        by_model[model] = (
            uncached * prices["input"]
            + cached * prices["cached_input"]
            + completion * prices["output"]
        ) / 1_000_000
    return sum(by_model.values()), by_model


async def _make_eval_user(session, *, native: str, target: str, level: int, run_id: str, pair: str) -> User:
    user = User(
        id=uuid.uuid4(),
        email=f"quiz-eval:{pair}:{run_id}@eval.local",
        password_hash="x",
        native_language=native,
        target_language=target,
        target_languages=[target],
        language_levels={target: level},
        current_level=level,
    )
    session.add(user)
    await session.commit()
    return user


async def _make_seed_node(session, user: User, statement: dict) -> Node:
    node = await crud._get_or_create_node(
        session,
        name=f"eval-{statement['id']}-{uuid.uuid4().hex[:6]}",
        type_="Statement",
        description=json.dumps({"content": statement["text"]}, ensure_ascii=False),
        user_id=user.id,
        claim_key=f"quiz-eval:{statement['id']}:{uuid.uuid4().hex[:8]}",
    )
    await session.commit()
    return node


async def _run_pair(
    *, native: str, target: str, statements: list[dict], level: int, repeat: int, run_id: str
) -> tuple[list[dict], dict]:
    """Returns (cards, pair_metrics) for one (native, target) pair."""
    pair = pair_key(native, target)
    cards: list[dict] = []
    metrics = {
        "pair": pair, "native": native, "target": target,
        "statements": 0, "bundles": 0, "bundle_errors": 0,
        "chunks_proposed": 0, "chunks_selected": 0, "cards_emitted": 0,
        "cloze_cards_saved": 0, "cloze_origin_counts": Counter(),
        "gate_histogram": Counter(), "repair_gate_histogram": Counter(),
        "rejection_samples": [],
        "qa_scores": [], "verdicts": Counter(),
        "repair_attempts": 0, "semantic_reviews_reused": 0,
        "pack_coverage": target_pack(target).coverage,
        "golden_checks": [], "golden_failures": 0,
        "usage": {
            "prompt_tokens": 0, "completion_tokens": 0,
            "cached_prompt_tokens": 0, "reasoning_tokens": 0, "by_model": {},
        },
    }
    async with async_session_factory() as session:
        user = await _make_eval_user(
            session, native=native, target=target, level=level, run_id=run_id, pair=pair
        )
        try:
            for statement in statements:
                metrics["statements"] += 1
                for rep in range(repeat):
                    node = await _make_seed_node(session, user, statement)
                    try:
                        created, trace = await generate_quiz_bundle(
                            session,
                            user,
                            language=target,
                            seed_node_ids={str(node.id)},
                            synthesize_audio=False,
                        )
                    except BundleSeedError as exc:
                        metrics["bundle_errors"] += 1
                        cards.append({
                            "statement_id": statement["id"], "repeat": rep, "pair": pair,
                            "error": str(exc),
                        })
                        continue
                    metrics["bundles"] += 1
                    plan_step = _extract_step(trace, "bundle_plan_generate")
                    if plan_step:
                        metrics["chunks_proposed"] += int(
                            (plan_step.get("output") or {}).get("raw_expression_count") or 0
                        )
                    struct_step = _extract_step(trace, "bundle_structural_validation")
                    struct_out = (struct_step or {}).get("output") or {}
                    for reason in struct_out.get("structural_rejections") or []:
                        metrics["gate_histogram"][_gate_code(reason)] += 1
                    # Gates that fired during authoring/repair. Counted in a
                    # separate histogram because a hit here usually means the
                    # gate WORKED (the repair then satisfied it), while a hit
                    # in structural_rejections means a candidate was dropped.
                    for reason in struct_out.get("repair_path_rejections") or []:
                        metrics["repair_gate_histogram"][_gate_code(reason)] += 1
                        # Keep a bounded sample of the raw text too. The
                        # histogram buckets everything without a reason code
                        # as "uncoded", which is exactly the bucket you need
                        # to read when deciding what to fix next.
                        if len(metrics["rejection_samples"]) < 60:
                            metrics["rejection_samples"].append(reason[:300])
                    for reason in struct_out.get("quality_rejections") or []:
                        metrics["gate_histogram"][_gate_code(str(reason))] += 1
                        if len(metrics["rejection_samples"]) < 60:
                            metrics["rejection_samples"].append(str(reason)[:300])
                    for step in trace.get("steps") or []:
                        usage = (step.get("output") or {}).get("usage")
                        if usage is not None:
                            _accumulate_usage(
                                usage, metrics["usage"], model=str(step.get("model") or "unknown")
                            )
                    qa_step = _extract_step(trace, "bundle_cloze_batch_quality_review")
                    if qa_step:
                        qa_output = qa_step.get("output") or {}
                        metrics["repair_attempts"] += int(qa_output.get("repair_count") or 0)
                        metrics["semantic_reviews_reused"] += int(
                            qa_output.get("reused_plan_review_count") or 0
                        )
                        for review in (
                            list(qa_output.get("initial_reviews") or [])
                            + list(qa_output.get("repair_reviews") or [])
                        ):
                            if not isinstance(review, dict):
                                continue
                            metrics["qa_scores"].append(int(review.get("score") or 0))
                            metrics["verdicts"][str(review.get("verdict") or "missing")] += 1
                    saved_clozes = [q for q in created if q.quiz_type == "cloze"]
                    metrics["cloze_cards_saved"] += len(saved_clozes)
                    # Compatibility alias: this field historically counted
                    # saved cloze cards despite its misleading name.
                    metrics["chunks_selected"] += len(saved_clozes)
                    for quiz in saved_clozes:
                        origin = str((quiz.quiz_data or {}).get("_origin") or "unknown")
                        metrics["cloze_origin_counts"][origin] += 1
                    metrics["cards_emitted"] += len(created)
                    created_views = [_card_view(quiz) for quiz in created]
                    golden_check = _check_golden_expectation(
                        statement, created_views, target_language=target
                    )
                    if golden_check is not None:
                        metrics["golden_checks"].append(golden_check)
                        if not golden_check["passed"]:
                            metrics["golden_failures"] += 1
                    for quiz in created:
                        cards.append({
                            "statement_id": statement["id"], "repeat": rep, "pair": pair,
                            "tags": statement.get("tags") or [],
                            **_card_view(quiz),
                        })
        finally:
            # If generation raised mid-flush, `session` may be poisoned
            # (SQLAlchemy's PendingRollbackError) — a delete on it would just
            # raise again and leave the eval user behind. Roll back first,
            # and if the session or connection itself is unusable (e.g. the
            # DB dropped mid-run), clean up from a fresh session instead of
            # letting cleanup failure mask the real error.
            try:
                await session.rollback()
                await session.delete(user)
                await session.commit()
            except Exception as cleanup_exc:
                print(f"  cleanup via primary session failed ({cleanup_exc!r}); retrying with a fresh session", file=sys.stderr)
                async with async_session_factory() as cleanup_session:
                    fresh_user = await cleanup_session.get(User, user.id)
                    if fresh_user is not None:
                        await cleanup_session.delete(fresh_user)
                        await cleanup_session.commit()
    metrics["gate_histogram"] = dict(metrics["gate_histogram"])
    metrics["repair_gate_histogram"] = dict(metrics["repair_gate_histogram"])
    metrics["cloze_origin_counts"] = dict(metrics["cloze_origin_counts"])
    metrics["verdicts"] = dict(metrics["verdicts"])
    metrics["cards_per_statement"] = (
        metrics["cards_emitted"] / metrics["statements"] if metrics["statements"] else 0.0
    )
    saved_clozes = metrics["cloze_cards_saved"]
    metrics["clozes_per_statement"] = (
        saved_clozes / metrics["statements"] if metrics["statements"] else 0.0
    )
    metrics["reviewed_plan_card_rate"] = (
        metrics["cloze_origin_counts"].get("reviewed_plan", 0) / saved_clozes if saved_clozes else 0.0
    )
    metrics["repair_card_rate"] = (
        metrics["cloze_origin_counts"].get("repair", 0) / saved_clozes if saved_clozes else 0.0
    )
    cost, cost_by_model = _estimated_usage_cost(metrics["usage"])
    metrics["estimated_cost_usd"] = cost
    metrics["estimated_cost_by_model_usd"] = cost_by_model
    metrics["estimated_cost_per_bundle_usd"] = (
        cost / metrics["bundles"] if cost is not None and metrics["bundles"] else None
    )
    metrics["estimated_cost_per_saved_cloze_usd"] = (
        cost / saved_clozes if cost is not None and saved_clozes else None
    )
    return cards, metrics


def _write_report(cards: list[dict], metrics_by_pair: dict[str, dict], out_dir: Path) -> None:
    lines = ["# Quiz eval report\n"]
    for pair, metrics in metrics_by_pair.items():
        lines.append(f"## {pair} ({metrics['native']} -> {metrics['target']})\n")
        lines.append(
            f"- statements: {metrics['statements']}, bundles: {metrics['bundles']}, "
            f"cards emitted: {metrics['cards_emitted']}, clozes/statement: {metrics['clozes_per_statement']:.2f}\n"
            f"- pack coverage: {metrics['pack_coverage']}\n"
            f"- saved cloze origins: {metrics['cloze_origin_counts']}\n"
            f"- reused shared semantic reviews: {metrics['semantic_reviews_reused']}\n"
            f"- estimated API cost: ${metrics['estimated_cost_usd']:.4f}\n"
            f"- semantic golden failures: {metrics['golden_failures']} / {len(metrics['golden_checks'])}\n"
            f"- gate histogram: {metrics['gate_histogram']}\n"
            f"- repair-path gate histogram: {metrics['repair_gate_histogram']}\n"
        )
        by_statement: dict[str, list[dict]] = {}
        for card in cards:
            if card["pair"] != pair:
                continue
            by_statement.setdefault(card["statement_id"], []).append(card)
        for statement_id, statement_cards in by_statement.items():
            lines.append(f"### {statement_id}\n")
            for card in statement_cards:
                if "error" in card:
                    lines.append(f"- **ERROR**: {card['error']}\n")
                    continue
                if card["quiz_type"] == "cloze":
                    lines.append(
                        f"- **cloze** [{card.get('origin') or 'unknown'}] `{card.get('canonical_form')}` — {card.get('prompt_target')} "
                        f"→ **{card.get('surface_answer')}** (native: {card.get('target_native')})\n"
                    )
                else:
                    lines.append(
                        f"- **composition** {card.get('question_native')} — "
                        f"model answer: {(card.get('model_answers') or [''])[0]}\n"
                    )
        lines.append("\n")
    (out_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def _write_failures(metrics_by_pair: dict[str, dict], out_dir: Path) -> None:
    lines = ["# Gate rejection histogram by pair\n"]
    for pair, metrics in metrics_by_pair.items():
        lines.append(f"## {pair}\n")
        if not metrics["gate_histogram"]:
            lines.append("(no rejections recorded)\n")
            continue
        for code, count in sorted(metrics["gate_histogram"].items(), key=lambda kv: -kv[1]):
            lines.append(f"- `{code}`: {count}\n")
        lines.append("\n")
    (out_dir / "failures.md").write_text("\n".join(lines), encoding="utf-8")


def _compare(prev_dir: Path, metrics_by_pair: dict[str, dict]) -> str:
    prev_metrics = json.loads((prev_dir / "metrics.json").read_text(encoding="utf-8"))
    lines = [f"# Compare against {prev_dir.name}\n"]
    for pair, metrics in metrics_by_pair.items():
        prev = prev_metrics.get(pair)
        if not prev:
            lines.append(f"## {pair}: no previous data\n")
            continue
        delta_cps = metrics["cards_per_statement"] - prev["cards_per_statement"]
        lines.append(
            f"## {pair}\n- cards/statement: {prev['cards_per_statement']:.2f} -> "
            f"{metrics['cards_per_statement']:.2f} ({delta_cps:+.2f})\n"
        )
        prev_hist = prev.get("gate_histogram", {})
        cur_hist = metrics["gate_histogram"]
        codes = sorted(set(prev_hist) | set(cur_hist))
        for code in codes:
            before, after = prev_hist.get(code, 0), cur_hist.get(code, 0)
            if before != after:
                lines.append(f"  - `{code}`: {before} -> {after}\n")
    return "\n".join(lines)


def _assert_baseline(baseline_path: Path, metrics_by_pair: dict[str, dict]) -> int:
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    failures = []
    for pair, metrics in metrics_by_pair.items():
        base = baseline.get(pair)
        if not base:
            continue
        if metrics["cards_per_statement"] < base["cards_per_statement"] * 0.85:
            failures.append(f"{pair}: cards_per_statement dropped >15% ({base['cards_per_statement']:.2f} -> {metrics['cards_per_statement']:.2f})")
        if metrics["pack_coverage"] != "full" and base.get("pack_coverage") == "full":
            failures.append(f"{pair}: pack_coverage regressed from full to {metrics['pack_coverage']}")
    if failures:
        print("BASELINE ASSERTION FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("Baseline assertions passed.")
    return 0


def _assert_golden(metrics_by_pair: dict[str, dict]) -> int:
    failures = [
        f"{pair}/{check['statement_id']} ({check.get('quality_case_id')})"
        for pair, metrics in metrics_by_pair.items()
        for check in metrics.get("golden_checks") or []
        if not check.get("passed")
    ]
    if failures:
        print("SEMANTIC GOLDEN ASSERTION FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("Semantic golden assertions passed.")
    return 0


async def main_async(args: argparse.Namespace) -> int:
    settings = get_settings()
    if settings.is_production:
        print("Refusing to run quiz_eval against a production environment.", file=sys.stderr)
        return 1
    await init_db()

    pairs = [p.strip() for p in args.pairs.split(",") if p.strip()]
    for p in pairs:
        if p not in _PAIR_CODES:
            print(f"Unknown pair code {p!r}; choose from {sorted(_PAIR_CODES)}", file=sys.stderr)
            return 1

    ids = {i.strip() for i in args.ids.split(",")} if args.ids else None
    golden = _load_golden(ids)

    run_id = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    out_dir = Path(args.out) if args.out else _RUNS_DIR / f"{run_id}_{_git_sha()}"
    out_dir.mkdir(parents=True, exist_ok=True)

    all_cards: list[dict] = []
    metrics_by_pair: dict[str, dict] = {}
    for code in pairs:
        native, target = _PAIR_CODES[code]
        if not is_supported_pair(native, target):
            print(f"Skipping {code}: not a supported pair", file=sys.stderr)
            continue
        statements = [s for s in golden if s["native"] == native]
        if not statements:
            print(f"No golden statements for native={native}; skipping {code}", file=sys.stderr)
            continue
        print(f"Running {code}: {len(statements)} statements x {args.repeat} repeat(s)...")
        cards, metrics = await _run_pair(
            native=native, target=target, statements=statements,
            level=args.level, repeat=args.repeat, run_id=run_id,
        )
        all_cards.extend(cards)
        metrics_by_pair[code] = metrics
        print(
            f"  {code}: {metrics['cards_emitted']} cards from {metrics['bundles']} bundles "
            f"(cards/statement={metrics['cards_per_statement']:.2f})"
        )

    (out_dir / "cards.json").write_text(
        json.dumps(all_cards, ensure_ascii=False, indent=2, default=str), encoding="utf-8"
    )
    (out_dir / "metrics.json").write_text(
        json.dumps(metrics_by_pair, ensure_ascii=False, indent=2, default=str), encoding="utf-8"
    )
    (out_dir / "run.json").write_text(
        json.dumps({
            "argv": sys.argv, "git_sha": _git_sha(),
            "openai_model": settings.openai_model,
            "quiz_author_model": settings.quiz_author_model,
            "quiz_quality_model": settings.quiz_quality_model,
            "cloze_generator_version": CLOZE_GENERATOR_VERSION,
            "golden_set_version": json.loads(_GOLDEN_PATH.read_text(encoding="utf-8"))["version"],
        }, indent=2),
        encoding="utf-8",
    )
    _write_report(all_cards, metrics_by_pair, out_dir)
    _write_failures(metrics_by_pair, out_dir)

    print(f"\nWrote {out_dir}")

    exit_code = 0
    if args.compare:
        comparison = _compare(Path(args.compare), metrics_by_pair)
        (out_dir / "compare.md").write_text(comparison, encoding="utf-8")
        print(comparison)
    if args.assert_baseline:
        exit_code = _assert_baseline(Path(args.assert_baseline), metrics_by_pair)
    if args.assert_golden:
        exit_code = max(exit_code, _assert_golden(metrics_by_pair))
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pairs", required=True, help="Comma-separated pair codes: ko-en,ko-de,en-ko")
    parser.add_argument("--ids", default=None, help="Comma-separated golden statement ids to restrict to")
    parser.add_argument("--level", type=int, default=50, help="Learner level 1-100 (default 50)")
    parser.add_argument("--repeat", type=int, default=1, help="Repeats per statement (variance check)")
    parser.add_argument("--out", default=None, help="Output directory (default eval/runs/<ts>_<sha>)")
    parser.add_argument("--compare", default=None, help="Previous run directory to diff against")
    parser.add_argument("--assert-baseline", default=None, help="baseline.json to assert against (nonzero exit on regression)")
    parser.add_argument("--assert-golden", action="store_true", help="fail when semantic golden expectations are not met")
    args = parser.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    raise SystemExit(main())
