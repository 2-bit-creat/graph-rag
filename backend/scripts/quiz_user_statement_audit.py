"""Run the current quiz bundle against anonymized samples from the live DB.

The source database is read-only for this command. Statements are copied into
the explicitly supplied `_test` database under ephemeral eval users, generated
there, summarized to stdout, and deleted on completion.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import uuid
from collections import Counter
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app import crud
from app.config import get_settings
from app.models import Node, Quiz, QuizLearningMaterial, User
from app.quiz_bundle import BundleSeedError, generate_quiz_bundle
from scripts.quiz_eval import _accumulate_usage, _estimated_usage_cost


PAIRS = {
    "ko-en": ("korean", "english"),
    "ko-de": ("korean", "german"),
    "en-ko": ("english", "korean"),
}


def _content(node: Node) -> str:
    raw = (node.description or "").strip()
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict) and str(parsed.get("content") or "").strip():
                return str(parsed["content"]).strip()
        except (TypeError, ValueError):
            pass
    return (node.name or "").strip()


def _targets(user: User) -> set[str]:
    values = {str(value).lower() for value in (user.target_languages or []) if value}
    if user.target_language:
        values.add(user.target_language.lower())
    return values


def _stable_rank(pair: str, node_id: uuid.UUID) -> str:
    return hashlib.sha256(f"{pair}:{node_id}".encode()).hexdigest()


async def _source_samples(source_url: str, per_pair: int) -> tuple[dict[str, int], dict[str, list[str]]]:
    engine = create_async_engine(source_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    counts = Counter()
    candidates: dict[str, list[tuple[str, str]]] = {pair: [] for pair in PAIRS}
    try:
        async with factory() as session:
            rows = (await session.execute(
                select(Node, User)
                .join(User, User.id == Node.user_id)
                .where(Node.type == "Statement", Node.deleted_at.is_(None))
            )).all()
            for node, user in rows:
                text = _content(node)
                if not (12 <= len(text) <= 600):
                    continue
                for pair, (native, target) in PAIRS.items():
                    if user.native_language.lower() == native and target in _targets(user):
                        counts[pair] += 1
                        candidates[pair].append((_stable_rank(pair, node.id), text))
    finally:
        await engine.dispose()
    samples = {
        pair: [text for _, text in sorted(items)[:per_pair]]
        for pair, items in candidates.items()
    }
    return dict(counts), samples


async def _source_inventory(source_url: str) -> dict[str, dict[str, int]]:
    """Summarize existing live cards without reading statement text externally."""
    engine = create_async_engine(source_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    result = {pair: Counter() for pair in PAIRS}
    try:
        async with factory() as session:
            statements = (await session.execute(
                select(Node, User)
                .join(User, User.id == Node.user_id)
                .where(Node.type == "Statement", Node.deleted_at.is_(None))
            )).all()
            quizzes = (await session.scalars(
                select(Quiz).where(
                    Quiz.queue_kind.in_(("new", "review")),
                    Quiz.quiz_type.in_(("cloze", "composition")),
                )
            )).all()
            materials = (await session.scalars(select(QuizLearningMaterial))).all()
            quiz_types: dict[tuple[str, str], set[str]] = {}
            for quiz in quizzes:
                language = str(quiz.language or "english").lower()
                for node_id in quiz.source_nodes or []:
                    quiz_types.setdefault((str(node_id), language), set()).add(quiz.quiz_type)
            material_by_key = {
                (str(row.node_id), row.language.lower()): row for row in materials
            }
            for node, user in statements:
                for pair, (native, target) in PAIRS.items():
                    if user.native_language.lower() != native or target not in _targets(user):
                        continue
                    counts = result[pair]
                    counts["statements"] += 1
                    types = quiz_types.get((str(node.id), target), set())
                    counts["with_composition"] += int("composition" in types)
                    counts["with_cloze"] += int("cloze" in types)
                    counts["composition_only"] += int(
                        "composition" in types and "cloze" not in types
                    )
                    counts["without_active_quiz"] += int(not types)
                    material = material_by_key.get((str(node.id), target))
                    if "composition" in types and "cloze" not in types:
                        if material is None:
                            counts["composition_only_material_missing"] += 1
                        else:
                            counts[f"composition_only_status_{material.status}"] += 1
                            counts["composition_only_zero_expression"] += int(
                                material.expression_count == 0
                            )
                            counts["composition_only_has_expression"] += int(
                                material.expression_count > 0
                            )
                    counts["ready_zero_expression"] += int(
                        material is not None
                        and material.status == "ready"
                        and material.expression_count == 0
                    )
    finally:
        await engine.dispose()
    return {pair: dict(values) for pair, values in result.items()}


async def _evaluate(test_url: str, samples: dict[str, list[str]]) -> dict[str, Any]:
    if "_test" not in test_url.lower():
        raise RuntimeError("QUIZ_AUDIT_DATABASE_URL must point to an _test database")
    engine = create_async_engine(test_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    output: dict[str, Any] = {}
    try:
        for pair, texts in samples.items():
            native, target = PAIRS[pair]
            summary: dict[str, Any] = {
                "statements": len(texts), "bundles": 0, "composition": 0,
                "cloze": 0, "zero_cloze": 0, "repair_cards": 0,
                "reviewed_plan_cards": 0,
                "usage": {"prompt_tokens": 0, "completion_tokens": 0,
                          "cached_prompt_tokens": 0, "reasoning_tokens": 0,
                          "by_model": {}},
                "cards": [],
            }
            async with factory() as session:
                user = User(
                    id=uuid.uuid4(), email=f"quiz-user-audit:{pair}:{uuid.uuid4()}@eval.local",
                    password_hash="x", native_language=native, target_language=target,
                    target_languages=[target], language_levels={target: 50}, current_level=50,
                )
                session.add(user)
                await session.commit()
                try:
                    for index, text in enumerate(texts, 1):
                        node = await crud._get_or_create_node(
                            session, name=f"user-audit-{pair}-{index}-{uuid.uuid4().hex[:6]}",
                            type_="Statement",
                            description=json.dumps({"content": text}, ensure_ascii=False),
                            user_id=user.id,
                            claim_key=f"quiz-user-audit:{pair}:{uuid.uuid4().hex}",
                        )
                        await session.commit()
                        try:
                            created, trace = await generate_quiz_bundle(
                                session, user, language=target,
                                seed_node_ids={str(node.id)}, synthesize_audio=False,
                            )
                        except BundleSeedError as exc:
                            summary["zero_cloze"] += 1
                            summary["cards"].append({"sample": index, "error": str(exc)})
                            continue
                        summary["bundles"] += 1
                        for step in trace.get("steps") or []:
                            usage = (step.get("output") or {}).get("usage")
                            if usage is not None:
                                _accumulate_usage(
                                    usage,
                                    summary["usage"],
                                    model=str(step.get("model") or "unknown"),
                                )
                        compositions = [q for q in created if q.quiz_type == "composition"]
                        clozes = [q for q in created if q.quiz_type == "cloze"]
                        summary["composition"] += len(compositions)
                        summary["cloze"] += len(clozes)
                        summary["zero_cloze"] += int(not clozes)
                        for quiz in clozes:
                            data = quiz.quiz_data or {}
                            origin = str(data.get("_origin") or data.get("origin") or "")
                            if origin == "repair":
                                summary["repair_cards"] += 1
                            if origin == "reviewed_plan":
                                summary["reviewed_plan_cards"] += 1
                        summary["cards"].append({
                            "sample": index,
                            "source_preview": text[:80],
                            "composition": len(compositions),
                            "clozes": [
                                {
                                    "answer": (q.quiz_data or {}).get("blank"),
                                    "meaning": (q.quiz_data or {}).get("target_native"),
                                    "sentence": q.sentence_target,
                                }
                                for q in clozes
                            ],
                        })
                finally:
                    await session.delete(user)
                    await session.commit()
            summary["estimated_cost_usd"] = _estimated_usage_cost(summary["usage"])[0]
            output[pair] = summary
    finally:
        await engine.dispose()
    return output


async def main_async(args: argparse.Namespace) -> int:
    source_url = get_settings().database_url
    inventory = await _source_inventory(source_url)
    print(json.dumps({"existing_inventory": inventory}, ensure_ascii=False, indent=2))
    if args.inventory_only:
        return 0
    counts, samples = await _source_samples(source_url, args.per_pair)
    print(json.dumps({"available_statements": counts, "sample_sizes": {
        pair: len(values) for pair, values in samples.items()
    }}, ensure_ascii=False, indent=2))
    result = await _evaluate(args.test_database_url, samples)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--per-pair", type=int, default=3)
    parser.add_argument("--inventory-only", action="store_true")
    parser.add_argument(
        "--test-database-url",
        default=os.getenv("QUIZ_AUDIT_DATABASE_URL", ""),
        required=not bool(os.getenv("QUIZ_AUDIT_DATABASE_URL")),
    )
    return asyncio.run(main_async(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
