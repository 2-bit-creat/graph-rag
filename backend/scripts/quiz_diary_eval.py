"""Run the complete quiz pipeline against disposable diary Statements.

This is an operator-facing quality check.  It uses the already-created test
accounts, writes a readable result bundle under ``eval/runs/``, then removes
only the temporary Statement nodes and their dependent learning data.

Example:
    python -m scripts.quiz_diary_eval
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import select

from app import crud
from app.db import async_session_factory
from app.models import Node, User
from app.quiz_materials import generate_complete_learning_set
from app.node_expression_store import get_node_expressions


_RUNS_DIR = Path(__file__).resolve().parents[1] / "eval" / "runs"

# Two natural diary entries per actual learner-language pair.  Each entry has
# enough context to exercise LLM study segmentation without teaching names or
# incidental details as vocabulary.
_CASES = (
    {
        "email": "simple:test1@local",
        "language": "korean",
        "label": "en-ko",
        "entries": (
            "I stopped by a small bakery on my way home and bought a loaf of sourdough. "
            "The smell filled the kitchen while I made soup for dinner.",
            "I finally organized the photos on my phone this evening. "
            "I found pictures from last spring and ended up calling my sister to reminisce.",
        ),
    },
    {
        "email": "simple:test2@local",
        "language": "english",
        "label": "ko-en",
        "entries": (
            "퇴근길에 비가 갑자기 와서 편의점에서 우산을 샀다. "
            "집에 도착했을 때는 신발이 조금 젖어 있었지만, 따뜻한 차를 마시니 기분이 한결 나아졌다.",
            "오늘은 미뤄 두었던 방 정리를 시작했다. "
            "오래된 사진을 발견해서 잠시 추억에 잠겼고, 결국 계획보다 늦게 잠들었다.",
        ),
    },
    {
        "email": "simple:test2@local",
        "language": "german",
        "label": "ko-de",
        "entries": (
            "오늘은 친구를 만나서 함께 저녁을 먹었다. 오래 못 만나서 이야기를 많이 나눴다.",
            "기차가 늦게 와서 약속 시간에 조금 늦었다.",
        ),
    },
)


def _quiz_view(quiz) -> dict:
    data = quiz.quiz_data or {}
    return {
        "quiz_type": quiz.quiz_type,
        "language": quiz.language,
        "queue_kind": quiz.queue_kind,
        "question_native": quiz.question_native,
        "sentence_target": quiz.sentence_target,
        "canonical_form": data.get("canonical_form"),
        "surface_form": data.get("surface_form") or data.get("surface_answer"),
        "answer_native": data.get("answer_native"),
        "reference_answers": data.get("model_answers"),
    }


async def _run_case(case: dict, out_dir: Path) -> dict:
    created_nodes: list[uuid.UUID] = []
    result = {"pair": case["label"], "entries": [], "cleanup": []}
    try:
        async with async_session_factory() as session:
            user = await session.scalar(select(User).where(User.email == case["email"]))
            if user is None:
                raise RuntimeError(f"Missing test account: {case['email']}")
            if user.native_language == case["language"]:
                raise RuntimeError("Test case target language must differ from the native language")

            for index, text in enumerate(case["entries"], start=1):
                node = Node(
                    user_id=user.id,
                    type="Statement",
                    name=f"__quiz_diary_eval__:{case['label']}:{index}:{uuid.uuid4().hex[:8]}",
                    description=json.dumps({"content": text}, ensure_ascii=False),
                )
                session.add(node)
                await session.commit()
                created_nodes.append(node.id)

                material, quizzes, trace = await generate_complete_learning_set(
                    session,
                    user,
                    node_id=node.id,
                    language=case["language"],
                    direct_node=True,
                    limit=8,
                )
                await session.commit()
                expressions = await get_node_expressions(user.id, str(node.id), case["language"])
                result["entries"].append(
                    {
                        "source": text,
                        "node_id": str(node.id),
                        "material": {
                            "status": material.status,
                            "composition_count": material.composition_count,
                            "expression_count": material.expression_count,
                            "error": material.error,
                        },
                        "steps": trace.get("analysis", trace).get("steps", []),
                        "materialization": trace.get("materialization", {}),
                        "expressions": expressions,
                        "quizzes": [_quiz_view(quiz) for quiz in quizzes],
                    }
                )
    finally:
        async with async_session_factory() as cleanup_session:
            for node_id in created_nodes:
                try:
                    result["cleanup"].append(
                        {"node_id": str(node_id), "result": await crud.delete_statement_cascade(cleanup_session, node_id, user.id)}
                    )
                except Exception as exc:  # Keep the result bundle even if cleanup needs manual help.
                    result["cleanup"].append({"node_id": str(node_id), "error": f"{type(exc).__name__}: {exc}"})

    path = out_dir / f"{case['label']}.json"
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
    return result


def _summary(result: dict) -> str:
    lines = [f"# {result['pair']} diary pipeline evaluation\n"]
    for index, entry in enumerate(result["entries"], start=1):
        material = entry["material"]
        quizzes = entry["quizzes"]
        compositions = [q for q in quizzes if q["quiz_type"] == "composition"]
        clozes = [q for q in quizzes if q["quiz_type"] == "cloze"]
        lines.extend(
            [
                f"## Entry {index}\n",
                f"Source: {entry['source']}\n",
                f"- material: {material['status']}; compositions={len(compositions)}, expressions={material['expression_count']}, clozes={len(clozes)}\n",
            ]
        )
        for step in entry["steps"]:
            lines.append(f"- {step.get('name')}: {json.dumps(step.get('output') or {}, ensure_ascii=False)}\n")
        for quiz in quizzes:
            if quiz["quiz_type"] == "composition":
                references = ", ".join(
                    str(answer.get("text") or "")
                    for answer in (quiz["reference_answers"] or [])
                    if isinstance(answer, dict)
                )
                lines.append(f"- Writing: {quiz['question_native']} → {references}\n")
            else:
                lines.append(f"- Word: {quiz['canonical_form']} / {quiz['surface_form']} → {quiz['sentence_target']}\n")
    lines.append(f"\nCleanup: {json.dumps(result['cleanup'], ensure_ascii=False)}\n")
    return "".join(lines)


async def main_async() -> int:
    run_id = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    out_dir = _RUNS_DIR / f"diary-live-{run_id}"
    out_dir.mkdir(parents=True, exist_ok=False)
    results = []
    selected_label = (os.environ.get("QUIZ_DIARY_EVAL_LABEL") or "").strip()
    cases = [case for case in _CASES if not selected_label or case["label"] == selected_label]
    for case in cases:
        results.append(await _run_case(case, out_dir))
    (out_dir / "report.md").write_text("\n".join(_summary(result) for result in results), encoding="utf-8")
    print(out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main_async()))
