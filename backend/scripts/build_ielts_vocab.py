"""One-off: parse IELTS-4000.txt into static/vocab/ielts_4000.json."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from app.ielts_vocab_bank import parse_ielts_txt


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else root.parent / "uploads" / "IELTS-4000-0.txt"
    if not src.is_file():
        # Try cursor uploads path
        alt = Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\uploads\IELTS-4000-0.txt")
        src = alt if alt.is_file() else src

    entries = parse_ielts_txt(src.read_text(encoding="utf-8"))
    out = root / "static" / "vocab" / "ielts_4000.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {len(entries)} entries to {out}")


if __name__ == "__main__":
    main()
