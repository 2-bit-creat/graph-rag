"""Repair UTF-8 corrupted chat Dart files and write back to lib/."""
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LIB = ROOT / "lib"

FIXES: list[tuple[str, str]] = [
    # chat_session_controller
    ("errors.value = '진행 중인 일기 처리를 먼저 마쳐 주세요.';", None),  # placeholder
]

SESSION_REPLACEMENTS = [
    (r"errors\.value = '[^']*진행[^']*';", "errors.value = '진행 중인 일기 처리를 먼저 마쳐 주세요.';"),
    (r"final content = '[^']*지[^']*그[^']*';", "final content = '📔 지식그래프 완성';"),
    (r"errors\.value = '[^']*실패[^']*다시[^']*';", "errors.value = '일기 처리에 실패했어요. 다시 시도해 주세요.';"),
    (r"const content = '[^']*일기 처리 실패';", "const content = '📔 일기 처리 실패';"),
    (r"return '\$\{trimmed\.substring\(0, maxLen\)\}[^']*';", "return '${trimmed.substring(0, maxLen)}…';"),
    (r"content: '[^']*일기 처리 중[^']*,", "content: '📔 일기 처리 중…',"),
    (r"errors\.value = '[^']*이미[^']*일기[^']*';", "errors.value = '이미 일기 처리가 진행 중이에요. 완료된 후 다시 저장해 주세요.';"),
    (r"errors\.value = '[^']*일기 저장[^']*';", "errors.value = '일기 저장에 실패했어요.';"),
    (r"errors\.value = '[^']*음성[^']*';", "errors.value = '음성 파일이 없어요.';"),
    (r"errors\.value = '[^']*문제[^']*';", "errors.value = '풀 문제가 없어요. 메뉴 → 문제 생성에서 만들어 주세요.';"),
    (r"errors\.value = '[^']*문장[^']*선택[^']*';", "errors.value = '일기에 넣을 문장을 하나 이상 선택해 주세요.';"),
    (r"errors\.value = '[^']*대화[^']*시작[^']*';", "errors.value = '먼저 대화를 시작해 주세요.';"),
    (r"_appendJournalSubmit\('[^']*\$filename'\);", "_appendJournalSubmit('🎙️ $filename');"),
    (r"content: '📔 퀴즈: \$answer'", "content: '📝 퀴즈: $answer'"),
    (r"\(s\['speaker'\] \?\? '[^']*'\)", "(s['speaker'] ?? '나')"),
    (r"\? '[^']*'\s*\n\s*: \(s\['speaker'\]", "? '나'\n                  : (s['speaker']"),
    (r"s\.speaker == '[^']*'\)", "s.speaker == '나')"),
]

SIDEBAR_REPLACEMENTS = [
    (r"title: const Text\('채팅[^']*'\),", "title: const Text('채팅방 이름 변경'),"),
    (r"hintText: '[^']*', border: OutlineInputBorder", "hintText: '이름', border: OutlineInputBorder"),
    (r"child: const Text\('[^']*'\),\s*\n\s*\],\s*\n\s*\),\s*\n\s*\);", "child: const Text('저장')),\n        ],\n      ),\n    );", 0),
    (r"title: const Text\('채팅[^']*삭제[^']*'\)", "title: const Text('채팅방 삭제')"),
    (r"content: const Text\('[^']*삭제[^']*'\),", "content: const Text('이 채팅방을 삭제할까요? 지식그래프는 유지돼요.'),"),
    (r"child: const Text\('삭제'\)", "child: const Text('삭제')"),
    (r"child: const Text\('[^']*'\),\s*\n\s*\],\s*\n\s*\);\s*\n\s*if \(ok == true\)", "child: const Text('삭제')),\n        ],\n      ),\n    );\n    if (ok == true)"),
    (r"!p\.contains\('[^']*처리'\)", "!p.contains('일기 처리')"),
    (r"return '[^']*지식그래프[^']*';", "return '📔 지식그래프 완성';"),
    (r"return '[^']*일기 처리 실패';", "return '📔 일기 처리 실패';"),
    (r"return '[^']* \$\{journalTask\.stageLabel\}';", "return '📔 ${journalTask.stageLabel}';"),
    (r"Text\('기억 그래[^']*", "Text('기억 그래프'"),
    (r"tooltip: '[^']*접기'", "tooltip: '사이드바 접기'"),
    (r"label: const Text\('[^']*채팅'\)", "label: const Text('새 채팅')"),
    (r"Text\('[^']*새 채팅[^']*", "Text('아직 채팅방이 없어요.\\n\"새 채팅\"으로 시작하세요.'"),
    (r": '[^']*대화'", ": '새 대화'"),
    (r"tooltip: '[^']*펼치'", "tooltip: '사이드바 펼치기'"),
    (r"tooltip: '[^']*채팅'", "tooltip: '새 채팅'"),
    (r"tooltip: '[^']*션'", "tooltip: '옵션'"),
    (r"Text\('[^']*변경'\)", "Text('이름 변경')"),
    (r"PopupMenuItem\(value: 'delete', child: Text\('[^']*'\)\)", "PopupMenuItem(value: 'delete', child: Text('삭제'))"),
    (r"child: Text\('MyLife English'", "child: Text('MyLife English'"),
]

JOURNAL_MODE = """      content:
          '📔 일기 쓰기 모드\\n'
          '@화자명으로 작성한 뒤 저장하면, 받아쓰기 → 화자 확인 → 그래프 검토 순으로 '
          '아래에서 진행 상황을 확인할 수 있어요.',"""


def read_cleaned(name: str) -> str:
    src = ROOT / f"_clean_{name}" if (ROOT / f"_clean_{name}").exists() else ROOT / f"_{name.replace('.dart', '_utf8.dart')}"
    if not src.exists():
        src = LIB / ("chat" if "chat" in name else "widgets") / name
    return src.read_text(encoding="utf-8", errors="replace")


def apply_replacements(text: str, rules: list) -> str:
    for rule in rules:
        if len(rule) == 2:
            pat, repl = rule
            text = re.sub(pat, repl, text)
        else:
            pat, repl, _ = rule
            text = re.sub(pat, repl, text, count=1)
    return text


def fix_session(text: str) -> str:
    text = apply_replacements(text, SESSION_REPLACEMENTS)
    text = re.sub(
        r"content:\s*'[^']*'\s*\n\s*'@[^']*'\s*\n\s*'[^']*',",
        JOURNAL_MODE + ",",
        text,
        count=1,
    )
    return text


def fix_sidebar(text: str) -> str:
    text = text.replace(
        "title: const Text('채팅방 이름 변경'),",
        "title: const Text('채팅방 이름 변경'),",
    )
    # manual critical fixes
    manual = [
        ("title: const Text('채팅�???��'),", "title: const Text('채팅방 삭제'),"),
        ("title: const Text('채팅�??�름 변�?),", "title: const Text('채팅방 이름 변경'),"),
        ("hintText: '?�름',", "hintText: '이름',"),
        ("child: const Text('?�??)),", "child: const Text('저장')),"),
        ("content: const Text('??채팅방을 ??��?�까?? 지?�그?�프???��??�요.'),", "content: const Text('이 채팅방을 삭제할까요? 지식그래프는 유지돼요.'),"),
        ("child: const Text('??��')),", "child: const Text('삭제')),"),
        ("child: Text('기억 그래??,", "child: Text('기억 그래프',"),
        ("label: const Text('??채팅'),", "label: const Text('새 채팅'),"),
    ]
    for old, new in manual:
        text = text.replace(old, new)
    return apply_replacements(text, SIDEBAR_REPLACEMENTS)


def main() -> None:
    session = fix_session(read_cleaned("chat_session_controller.dart"))
    (LIB / "chat" / "chat_session_controller.dart").write_text(session, encoding="utf-8")
    print("fixed chat_session_controller.dart")

    sidebar = fix_sidebar(read_cleaned("chat_sidebar.dart"))
    (LIB / "chat" / "chat_sidebar.dart").write_text(sidebar, encoding="utf-8")
    print("fixed chat_sidebar.dart")

    mode_cards = read_cleaned("chat_mode_cards.dart")
    (LIB / "chat" / "chat_mode_cards.dart").write_text(mode_cards, encoding="utf-8")
    print("wrote chat_mode_cards.dart (utf8 cleaned)")


if __name__ == "__main__":
    main()
