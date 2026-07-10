"""Fix corrupted Korean string literals in chat-related Dart files."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "lib"

REPLACEMENTS: dict[str, list[tuple[str, str]]] = {
    "chat/chat_session_controller.dart": [
        ("errors.value = '진행 중인 ?기 처리?먼? 마쳐 주세??';", "errors.value = '진행 중인 일기 처리를 먼저 마쳐 주세요.';"),
        ("errors.value = '진행 중인 일기 처리?먼? 마쳐 주세??';", "errors.value = '진행 중인 일기 처리를 먼저 마쳐 주세요.';"),
        ("return '${trimmed.substring(0, maxLen)}??;", "return '${trimmed.substring(0, maxLen)}…';"),
        ("content: '? ?기 처리 중?,", "content: '📔 일기 처리 중…',"),
        ("errors.value = '? ?기 처리가 진행 중이?요. ?료?????시 ?해 주세??';", "errors.value = '이미 일기 처리가 진행 중이에요. 완료된 후 다시 저장해 주세요.';"),
        ("errors.value = '?기 ?에 ?패?어??';", "errors.value = '일기 저장에 실패했어요.';"),
        ("errors.value = '? ???는 문제가 ?어?? 메뉴 ??문제 ?성?서 만들??주세??';", "errors.value = '풀 문제가 없어요. 메뉴 → 문제 생성에서 만들어 주세요.';"),
        ("speaker: (s['speaker'] ?? '??).toString().trim().isEmpty\n                  ? '??\n                  : (s['speaker'] ?? '??).toString().trim(),", "speaker: (s['speaker'] ?? '나').toString().trim().isEmpty\n                  ? '나'\n                  : (s['speaker'] ?? '나').toString().trim(),"),
        ("final allSelf = included.every((s) => s.speaker == '??);", "final allSelf = included.every((s) => s.speaker == '나');"),
        ("errors.value = '?기???을 문장???나 ?상 ?택??주세??';", "errors.value = '일기에 넣을 문장을 하나 이상 선택해 주세요.';"),
    ],
    "chat/chat_sidebar.dart": [
        ("title: const Text('채팅???름 변?),", "title: const Text('채팅방 이름 변경'),"),
        ("hintText: '?름',", "hintText: '이름',"),
        ("child: const Text('???)),", "child: const Text('저장')),"),
        ("title: const Text('채팅????),", "title: const Text('채팅방 삭제'),"),
        ("content: const Text('??채팅방을 ???까?? 지?그?프?????요.'),", "content: const Text('이 채팅방을 삭제할까요? 지식그래프는 유지돼요.'),"),
        ("child: const Text('??)),", "child: const Text('삭제')),"),
        ("if (!active || !p.contains('?기 처리')) return p;", "if (!active || !p.contains('일기 처리')) return p;"),
        ("return '? 지?그?프 ?성';", "return '📔 지식그래프 완성';"),
        ("return '? ?기 처리 ?패';", "return '📔 일기 처리 실패';"),
        ("return '? ${journalTask.stageLabel}';", "return '📔 ${journalTask.stageLabel}';"),
        ("child: Text('기억 그래??,", "child: Text('기억 그래프',"),
        ("tooltip: '?이?바 ?기',", "tooltip: '사이드바 접기',"),
        ("label: const Text('??채팅'),", "label: const Text('새 채팅'),"),
        ("child: Text('?직 채팅방이 ?어??\\n\"??채팅\"?로 ?작?세??',", "child: Text('아직 채팅방이 없어요.\\n\"새 채팅\"으로 시작하세요.',"),
        ("title: title?.isNotEmpty == true ? title! : '????,", "title: title?.isNotEmpty == true ? title! : '새 대화',"),
        ("tooltip: '?이?바 ?치?,", "tooltip: '사이드바 펼치기',"),
        ("tooltip: '??채팅',", "tooltip: '새 채팅',"),
        ("tooltip: '?션',", "tooltip: '옵션',"),
        ("PopupMenuItem(value: 'rename', child: Text('?름 변?)),", "PopupMenuItem(value: 'rename', child: Text('이름 변경')),"),
        ("PopupMenuItem(value: 'delete', child: Text('??')),", "PopupMenuItem(value: 'delete', child: Text('삭제')),"),
    ],
    "widgets/target_language_button.dart": [
        ("'english': '????',", "'english': '영어',"),
        ("'korean': '????',", "'korean': '한국어',"),
        ("'german': '????',", "'german': '독일어',"),
        ("child: Text('??? ???',", "child: Text('학습 언어',"),
        ("leading: Text(_flags[lang] ?? '???',", "leading: Text(_flags[lang] ?? '🌐',"),
        ("final flag = _flags[selected] ?? '???';", "final flag = _flags[selected] ?? '🌐';"),
    ],
}

for rel, pairs in REPLACEMENTS.items():
    path = ROOT / rel.replace("/", "\\")
    if not path.exists():
        print("missing", path)
        continue
    text = path.read_text(encoding="utf-8")
    changed = 0
    for old, new in pairs:
        if old in text:
            text = text.replace(old, new)
            changed += 1
    path.write_text(text, encoding="utf-8")
    print(rel, "replacements", changed)
