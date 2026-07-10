"""Fix mojibake Korean strings in Dart files (Cursor Write corrupts UTF-8 on Windows)."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent / "lib"

# file -> list of (old, new) — old must match exactly in file
FIXES: dict[str, list[tuple[str, str]]] = {
    "chat/chat_mode_cards.dart": [
        ("'???�?????�기 초안'", "'이 대화 → 일기 초안'"),
        (
            "'?��? 채팅?�서 ??말만 ?�리?�요 (AI ?��? ?�외). 체크 ???�?�하거나 ?�래 ?�력창으�??�정.'",
            "'내가 채팅에서 한 말만 정리해요 (AI 답변은 제외). 체크 후 저장하거나 아래 입력창으로 수정.'",
        ),
        (
            "'?�?�에???�로 ?�리???�용??찾�? 못했?�요.'",
            "'대화에서 새로 정리할 내용을 찾지 못했어요.'",
        ),
        ("Text('?�기�??�??($includedCount)')", "Text('일기로 저장 ($includedCount)')"),
        ("'?��? 그래?�에 ?�음'", "'이미 그래프에 있음'"),
        (
            "'?��? 그래?�에 ?�음: \"$matched\"'",
            "'이미 그래프에 있음: \"$matched\"'",
        ),
        ("'?�문 ?�즈'", "'작문 퀴즈'"),
        ("const Text('?�음 문장')", "const Text('다음 문장')"),
        ("tooltip: '복습 ?�어?�에 ?�기'", "tooltip: '복습 단어장에 담기'"),
        ("'?�어 ?�즈'", "'단어 퀴즈'"),
        ("'?�답!'", "'정답!'"),
        ("'?�답'", "'오답'"),
        ("const Text('?�음 문제')", "const Text('다음 문제')"),
    ],
    "chat/chat_session_controller.dart": [
        (
            "'?�기 처리???�패?�어?? ?�시 ?�도??주세??'",
            "'일기 처리에 실패했어요. 다시 시도해 주세요.'",
        ),
        ("'?�� ?�기 처리 ?�패'", "'📔 일기 처리 실패'"),
        ("'?�기 ?�?�에 ?�패?�어??'", "'일기 저장에 실패했어요.'"),
        ("'?�음 ?�이?��? ?�어??'", "'다음 아이템이 없어요.'"),
        ("content: '?�� ?�즈: $answer'", "content: '📝 퀴즈: $answer'"),
    ],
    "widgets/speaker_merge_sheet.dart": [
        (
            "SnackBar(content: Text('??: ${e.toString().replaceFirst('Exception: ', '')}'))",
            "SnackBar(content: Text('실패: ${e.toString().replaceFirst('Exception: ', '')}'))",
        ),
        (
            "Text('?? ??? / ??', style: theme.textTheme.titleMedium)",
            "Text('화자 합치기 / 분리', style: theme.textTheme.titleMedium)",
        ),
        (
            "'?? ???? ??? ?? ?? ?? ?? ?? ??? ????. '\n"
            "            '?? ???? ?? ????? ?? ?? ? ???.'",
            "'같은 사람이면 카드를 길게 눌러 다른 화자 위로 끌어다 합치세요. '\n"
            "            '잘못 합쳤으면 분리 아이콘으로 다시 나눌 수 있어요.'",
        ),
        ("child: const Text('??')", "child: const Text('취소')"),
        (": const Text('??')", ": const Text('적용')"),
        ("tooltip: '??'", "tooltip: '분리'"),
        (".join(' ? ')", ".join(' · ')"),
    ],
    "screens/tutor_screen.dart": [
        ("const TextSpan(text: '  ?? ', style: TextStyle(color: AppColors.hubGraph))", "const TextSpan(text: '  → ', style: TextStyle(color: AppColors.hubGraph))"),
    ],
}

# Whole-file rewrites (small files)
REWRITES: dict[str, str] = {
    "utils/tutor_labels.dart": '''/// Shared tutor language labels (extracted from the legacy tutor screen).

String tutorLangLabel(String code) => switch (code) {
      'english' => 'English',
      'korean' => '한국어',
      'german' => 'Deutsch',
      _ => code,
    };

enum TutorSourceMode { journal, review }

extension TutorSourceModeX on TutorSourceMode {
  String get api => switch (this) {
        TutorSourceMode.journal => 'journal',
        TutorSourceMode.review => 'review',
      };
  String get label => switch (this) {
        TutorSourceMode.journal => '일기 기반',
        TutorSourceMode.review => '복습 추천',
      };
}
''',
    "widgets/target_language_button.dart": '''import 'package:flutter/material.dart';

import '../api/client.dart';
import '../utils/tutor_labels.dart';
import '../theme/app_theme.dart';

/// Toolbar chip to switch the active target language for quizzes/tutor.
///
/// Persists via `target_language` on the user profile API.
class TargetLanguageButton extends StatelessWidget {
  const TargetLanguageButton({
    super.key,
    required this.languages,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  final List<String> languages;
  final String selected;
  final ValueChanged<String> onChanged;
  final bool enabled;

  static const _flags = {
    'english': '🇺🇸',
    'korean': '🇰🇷',
    'german': '🇩🇪',
  };

  Future<void> _pick(BuildContext context) async {
    if (!enabled || languages.length <= 1) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.pageH, 0, AppSpacing.pageH, AppSpacing.sm),
              child: Text('학습 언어',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            for (final lang in languages)
              ListTile(
                leading: Text(_flags[lang] ?? '🌐', style: const TextStyle(fontSize: 22)),
                title: Text(tutorLangLabel(lang)),
                trailing: lang == selected
                    ? Icon(Icons.check_rounded, color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, lang),
              ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
    if (picked == null || picked == selected) return;
    try {
      await apiClient.updateActiveTargetLanguage(picked);
      onChanged(picked);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final flag = _flags[selected] ?? '🌐';
    final label = tutorLangLabel(selected);
    return TextButton.icon(
      onPressed: enabled && languages.length > 1 ? () => _pick(context) : null,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      icon: Text(flag, style: const TextStyle(fontSize: 16)),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          if (languages.length > 1) ...[
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)),
          ],
        ],
      ),
    );
  }
}
''',
}


def main() -> None:
    for rel, pairs in FIXES.items():
        path = ROOT / rel
        text = path.read_text(encoding="utf-8")
        original = text
        for old, new in pairs:
            if old not in text:
                print(f"WARN missing in {rel}: {old[:50]!r}...")
            else:
                text = text.replace(old, new)
        if text != original:
            path.write_text(text, encoding="utf-8")
            print(f"fixed {rel}")
        else:
            print(f"unchanged {rel}")

    for rel, content in REWRITES.items():
        path = ROOT / rel
        path.write_text(content, encoding="utf-8")
        print(f"rewrote {rel}")


if __name__ == "__main__":
    main()
