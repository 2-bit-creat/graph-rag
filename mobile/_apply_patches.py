"""Apply StrReplace patches from agent transcripts onto a file."""
import json
from pathlib import Path

TARGET = Path(__file__).resolve().parent / "lib" / "chat" / "journal_task_controller.dart"
TRANSCRIPTS = [
    Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\agent-transcripts\f164af2d-abc5-4d5e-aeb8-2e404bc7391a\f164af2d-abc5-4d5e-aeb8-2e404bc7391a.jsonl"),
    Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\agent-transcripts\980b9668-e984-4534-b745-c1d5d2ef9db9\980b9668-e984-4534-b745-c1d5d2ef9db9.jsonl"),
    Path(r"C:\Users\jsy97\.cursor\projects\c-Users-jsy97-Desktop-Projects-Graph-RAG\agent-transcripts\aa1d1056-4333-4ece-bf22-76bbc16f66e8\aa1d1056-4333-4ece-bf22-76bbc16f66e8.jsonl"),
]

content = TARGET.read_text(encoding="utf-8")
applied = 0
skipped = 0

for tpath in TRANSCRIPTS:
    for line in tpath.read_text(encoding="utf-8").splitlines():
        if "journal_task_controller" not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        for part in obj.get("message", {}).get("content", []):
            if part.get("name") != "StrReplace":
                continue
            inp = part.get("input", {})
            if "journal_task_controller" not in inp.get("path", ""):
                continue
            old = inp.get("old_string")
            new = inp.get("new_string")
            if not old or new is None:
                continue
            if old in content:
                count = content.count(old)
                if inp.get("replace_all"):
                    content = content.replace(old, new)
                else:
                    content = content.replace(old, new, 1)
                applied += 1
                print(f"applied ({tpath.name})")
            else:
                skipped += 1
                print(f"SKIP ({tpath.name}): {old[:60]!r}...")

TARGET.write_text(content, encoding="utf-8")
print(f"done applied={applied} skipped={skipped} len={len(content)}")
