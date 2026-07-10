"""Restore corrupted Dart chat files from agent transcripts."""
import json
from pathlib import Path


TARGETS: dict[str, str | None] = {
    "compose/journal_phase.dart": None,
    "chat/journal_task_controller.dart": None,
    "chat/chat_session_controller.dart": None,
    "widgets/journal_progress_card.dart": None,
    "chat/chat_sidebar.dart": None,
    "widgets/entity_identity_sheet.dart": None,
    "chat/chat_mode_cards.dart": None,
    "widgets/target_language_button.dart": None,
}

TRANSCRIPTS = [
    Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\agent-transcripts\f164af2d-abc5-4d5e-aeb8-2e404bc7391a\f164af2d-abc5-4d5e-aeb8-2e404bc7391a.jsonl"),
    Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\agent-transcripts\980b9668-e984-4534-b745-c1d5d2ef9db9\980b9668-e984-4534-b745-c1d5d2ef9db9.jsonl"),
    Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\agent-transcripts\aa1d1056-4333-4ece-bf22-76bbc16f66e8\aa1d1056-4333-4ece-bf22-76bbc16f66e8.jsonl"),
    Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\agent-transcripts\ddb55310-3cf5-4530-8b72-3a9ceb6e184e\ddb55310-3cf5-4530-8b72-3a9ceb6e184e.jsonl"),
    Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\agent-transcripts\50e8e168-1b1b-42a9-ad4b-26a25f235ed5\50e8e168-1b1b-42a9-ad4b-26a25f235ed5.jsonl"),
]


def norm_path(p: str) -> str:
    return p.replace("\\", "/").lower()


for tpath in TRANSCRIPTS:
    if not tpath.exists():
        print("skip missing", tpath)
        continue
    for line in tpath.read_text(encoding="utf-8").splitlines():
        if "Write" not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        for part in obj.get("message", {}).get("content", []):
            if part.get("name") != "Write":
                continue
            inp = part.get("input", {})
            raw = norm_path(inp.get("path", ""))
            contents = inp.get("contents")
            if not contents:
                continue
            for key in TARGETS:
                if key in raw and TARGETS[key] is None:
                    TARGETS[key] = contents
                    print("found", key, "from", tpath.name)

base = Path(__file__).resolve().parent / "lib"
for key, content in TARGETS.items():
    if content:
        dest = base / key
        dest.write_text(content, encoding="utf-8")
        print("wrote", dest)
    else:
        print("MISSING", key)
