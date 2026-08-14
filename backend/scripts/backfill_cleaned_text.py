"""정제 전 표기로 굳어버린 기존 항목·진술 노드를 정제본 표기로 되돌린다.

WHY THESE ROWS EXIST
--------------------
음성 경로는 정제 직후 ``apply_cleaned_text_to_segments``로 정제문을 세그먼트에
되매핑했지만, 타이핑·OCR 경로(``run_journal_text_pipeline``)에는 그 되매핑이 없었다.
그래서 세그먼트가 원문("출근완") 그대로 남았고, 그래프 추출의 다화자 분기는
세그먼트로 만든 라벨 텍스트를 원본으로 쓰기 때문에 진술 노드까지 정제 전 표기로
커밋됐다. 단일 화자(일기) 분기는 ``transcript_clean_native``를 직접 써서 멀쩡했다 —
사진으로 만든 대화 캡처만 정제가 안 된 것처럼 보인 이유다.

파이프라인은 고쳤으므로 신규 항목은 정상이다. 이 스크립트는 이미 저장된 것들을
정리한다.

WHAT IT DOES
------------
1. 항목: ``transcript_clean_native``를 세그먼트에 되매핑한다(런타임과 똑같은
   ``apply_cleaned_text_to_segments``). 1:1 매핑이 확실할 때만 바뀌고, 원문은 각
   세그먼트의 ``text_raw``에 남는다. ``transcript_native``는 건드리지 않으므로
   '자세히 보기'의 원문도 그대로다.
2. 진술 노드: 그 항목이 만든 Statement의 본문에서 (원문 조각 → 정제 조각) 치환만
   적용한다. **재추출하지 않는다** — 다시 뽑으면 노드·엣지가 갈리고 거기 붙은 퀴즈와
   사용자 수정이 날아가기 때문. 표기만 고치는 외과적 수술이라 노드 id, 엣지, 퀴즈,
   제목은 그대로 유지된다.

SAFETY
------
* 기본은 dry run. ``--apply`` 를 줘야 실제로 쓴다.
* 치환은 '원문 조각이 본문에 그대로 들어 있을 때'만 한다. 부분 일치나 추측 없음.
* 정제본과 원문의 줄 수가 맞지 않는 항목은 건너뛴다(런타임과 같은 안전 규칙).

    python -m scripts.backfill_cleaned_text                 # 리포트만
    python -m scripts.backfill_cleaned_text --apply         # 실제 반영
    python -m scripts.backfill_cleaned_text --user <uuid>   # 한 계정만
"""

from __future__ import annotations

import argparse
import asyncio
import json
import uuid as _uuid

from sqlalchemy import select

from app.db import async_session_factory
from app.journal_pipeline import apply_cleaned_text_to_segments
from app.models import JournalEntry, JournalGraphLink, Node

# 이보다 짧은 조각은 본문 어디에나 우연히 들어 있을 수 있어 치환 대상에서 뺀다.
_MIN_REPLACEABLE = 2

# 정제는 발화 끝에 마침표를 붙이는 일이 잦은데, 진술 본문은 추출 단계에서 이미
# 문장부호가 붙어 나온다. 그대로 치환하면 "가보자고." 가 "가보자고.." 가 된다.
_TRAIL_PUNCT = ".?!…。！？"


def _segment_pairs(before: list, after: list) -> list[tuple[str, str]]:
    """되매핑 전후 세그먼트에서 (원문, 정제문) 쌍을 뽑는다 — 실제로 달라진 것만."""
    pairs: list[tuple[str, str]] = []
    for old, new in zip(before, after):
        if not isinstance(old, dict) or not isinstance(new, dict):
            continue
        raw = str(old.get("text") or "").strip()
        clean = str(new.get("text") or "").strip()
        if not raw or not clean or raw == clean or len(raw) < _MIN_REPLACEABLE:
            continue
        # 끝 문장부호만 다른 쌍은 진술 본문에서 얻을 게 없다 — 추출이 이미 문장부호를
        # 붙여 놨고, 치환해 봐야 중복만 만든다.
        if raw.rstrip(_TRAIL_PUNCT + " ") == clean.rstrip(_TRAIL_PUNCT + " "):
            continue
        pairs.append((raw, clean))
    # 긴 조각부터 치환해야 짧은 조각이 긴 조각 안을 먼저 갉아먹지 않는다.
    return sorted(pairs, key=lambda p: len(p[0]), reverse=True)


def _splice(content: str, raw: str, clean: str) -> str:
    """raw를 clean으로 바꾸되, 경계에서 문장부호가 겹치지 않게 한다."""
    out: list[str] = []
    i = 0
    while True:
        j = content.find(raw, i)
        if j < 0:
            out.append(content[i:])
            return "".join(out)
        out.append(content[i:j])
        end = j + len(raw)
        replacement = clean
        while (
            replacement
            and replacement[-1] in _TRAIL_PUNCT
            and end < len(content)
            and content[end] == replacement[-1]
        ):
            replacement = replacement[:-1]
        out.append(replacement)
        i = end


def _rewrite_content(content: str, pairs: list[tuple[str, str]]) -> str:
    out = content
    for raw, clean in pairs:
        if raw in out:
            out = _splice(out, raw, clean)
    return out


async def main(apply: bool, user_id: str | None) -> None:
    entries_changed = 0
    nodes_changed = 0
    entries_skipped = 0

    async with async_session_factory() as session:
        stmt = select(JournalEntry).order_by(JournalEntry.created_at)
        if user_id:
            stmt = stmt.where(JournalEntry.user_id == _uuid.UUID(user_id))
        entries = list((await session.execute(stmt)).scalars())

        for entry in entries:
            segments = entry.transcript_segments
            clean = (entry.transcript_clean_native or "").strip()
            if not isinstance(segments, list) or not segments or not clean:
                continue
            remapped = apply_cleaned_text_to_segments(segments, clean)
            if remapped is segments:
                entries_skipped += 1
                continue
            pairs = _segment_pairs(segments, remapped)
            if not pairs:
                continue

            entries_changed += 1
            print(f"\nentry {entry.id}")
            for raw, clean_text in pairs:
                print(f"  세그먼트: {raw!r} → {clean_text!r}")

            # 이 항목이 만든 Statement 노드만 — 다른 항목의 노드는 건드리지 않는다.
            node_rows = await session.execute(
                select(Node)
                .join(JournalGraphLink, JournalGraphLink.node_id == Node.id)
                .where(
                    JournalGraphLink.journal_entry_id == entry.id,
                    Node.type == "Statement",
                    Node.deleted_at.is_(None),
                )
            )
            for node in set(node_rows.scalars()):
                try:
                    desc = json.loads(node.description or "{}")
                except (json.JSONDecodeError, TypeError):
                    continue
                if not isinstance(desc, dict):
                    continue
                content = str(desc.get("content") or "")
                rewritten = _rewrite_content(content, pairs)
                if rewritten == content:
                    continue
                nodes_changed += 1
                print(f"  진술 {node.id}: {content!r} → {rewritten!r}")
                if apply:
                    desc["content"] = rewritten
                    node.description = json.dumps(desc, ensure_ascii=False)

            if apply:
                entry.transcript_segments = remapped

        if apply:
            await session.commit()

    print(
        f"\n항목 {entries_changed}건 / 진술 {nodes_changed}건 대상"
        f" (정제본 줄 수가 맞지 않아 건너뛴 항목 {entries_skipped}건)"
    )
    if not apply:
        print("dry run — 실제로 반영하려면 --apply 를 붙여 다시 실행하세요.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="실제로 DB에 쓴다")
    parser.add_argument("--user", default=None, help="특정 user_id만 처리")
    args = parser.parse_args()
    asyncio.run(main(args.apply, args.user))
