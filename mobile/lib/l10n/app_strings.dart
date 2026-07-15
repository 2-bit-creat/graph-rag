import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight, dependency-free i18n. The app's native-language setting drives
/// the UI language: Korean natives see Korean, English natives see English.
///
/// This is deliberately NOT the ARB/gen-l10n system — it's a flat key→string map
/// so strings can be added incrementally without a build step. Developer/debug
/// screens stay Korean and are intentionally out of scope.
class AppLocaleController extends ChangeNotifier {
  String _locale = 'ko'; // 'ko' | 'en'

  String get locale => _locale;
  bool get isEnglish => _locale == 'en';

  static const _prefsKey = 'ui_locale';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved == 'en' || saved == 'ko') _locale = saved!;
    } catch (_) {
      // Non-fatal — fall back to Korean.
    }
  }

  /// Map a native-language key ('korean'/'english') to a UI locale and persist.
  Future<void> setFromNativeLanguage(String? nativeLanguage) async {
    final next =
        (nativeLanguage ?? '').toLowerCase() == 'english' ? 'en' : 'ko';
    await _set(next);
  }

  Future<void> _set(String next) async {
    if (next == _locale) return;
    _locale = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, next);
    } catch (_) {}
  }
}

/// Global singleton — wired into the top-level ListenableBuilder in main.dart so
/// changing it rebuilds the whole app.
final appLocaleController = AppLocaleController();

/// Translate a key for the current locale. Falls back to the Korean string, then
/// the key itself, so a missing translation degrades gracefully.
String tr(String key) {
  final map = appLocaleController.isEnglish ? _en : _ko;
  return map[key] ?? _ko[key] ?? key;
}

const Map<String, String> _ko = {
  // App shell
  'app.title': 'MyLife English',
  'shell.graphChat': '그래프 대화',
  'shell.roomsMenu': '채팅방 · 메뉴',
  'shell.collapseChat': '대화 패널 접기',
  'shell.expandChat': '대화 패널 펼치기',
  // Chat input + menu
  'chat.inputHint': '아무 얘기나 해보세요…',
  'chat.emptyTitle': '그래프를 보면서 바로 물어보세요.\nAI가 내 일기를 기억하고 답해요.',
  'chat.menu.journal': '일기 쓰기',
  'chat.menu.distill': '이 대화 일기로 정리',
  'chat.menu.composition': '작문 퀴즈',
  'chat.menu.word': '단어 퀴즈',
  'chat.mode.distill': '대화 → 일기 정리',
  'chat.mode.composition': '작문 퀴즈',
  'chat.mode.word': '단어 퀴즈',
  'chat.mode.journal': '일기 쓰기',
  'chat.hint.distill': '고칠 부분을 말해보세요. 예) 첫 문장 빼줘',
  'chat.hint.composition': '영어로 작문해서 보내기',
  'chat.hint.word': '빈칸에 들어갈 표현을 입력하세요',
  'chat.hint.journal': '일기를 작성하세요…',
  'graph.emptyTitle': '아직 지식그래프가 비어 있어요',
  'graph.emptyBody': '+ 버튼으로 첫 일기를 써보세요. 기록이 지식그래프가 됩니다.',
  'graph.pinEmpty': '이 진술에서는 문제를 만들지 못했어요. 표현이 너무 짧거나 반려됐을 수 있어요.',
  'journal.failed': '일기 처리에 실패했어요. 잠시 후 다시 시도해 주세요.',
  'quiz.empty': '아직 풀 문제가 없어요. 방금 문제를 만들기 시작했으니 잠시 후 다시 눌러 주세요.',
  'quiz.sessionDone': '이 세션을 다 풀었어요! 👏',
  'quiz.close': '닫기',
  'quiz.more': '더 풀기',
  // Settings
  'settings.title': '설정',
  'settings.nativeLanguage': '모국어',
  'settings.targetLanguages': '배우는 언어',
  'settings.nativeNote': '모국어를 바꾸면 새로 만드는 지식그래프와 앱 언어가 해당 언어로 바뀌어요.',
  'common.save': '저장',
  'common.saved': '저장했어요.',
  'common.cancel': '취소',
  // Accounts
  'account.title': '입장',
  'account.welcome': '아이디를 입력하면 나만의 공간이 열려요.',
  'account.newId': '새 아이디',
  'account.hint': '3–20자 영문·숫자',
  'account.enter': '입장',
  'account.saved': '저장된 아이디',
  'account.switch': '계정 전환',
  'account.signOut': '로그아웃',
  'account.forget': '이 기기에서 제거',
  'account.deleteData': '계정과 데이터 삭제',
  'account.deleteConfirm': '이 계정의 모든 일기·그래프·퀴즈가 영구 삭제됩니다. 계속할까요?',
  'account.mainHint': '기존 데이터는 아이디 "main"으로 열 수 있어요.',
};

const Map<String, String> _en = {
  'app.title': 'MyLife English',
  'shell.graphChat': 'Graph chat',
  'shell.roomsMenu': 'Rooms · Menu',
  'shell.collapseChat': 'Collapse chat panel',
  'shell.expandChat': 'Expand chat panel',
  'chat.inputHint': 'Say anything…',
  'chat.emptyTitle':
      'Ask right here while you look at your graph.\nThe AI remembers your journal and answers.',
  'chat.menu.journal': 'Write a journal',
  'chat.menu.distill': 'Turn this chat into a journal',
  'chat.menu.composition': 'Writing quiz',
  'chat.menu.word': 'Vocabulary quiz',
  'chat.mode.distill': 'Chat → journal',
  'chat.mode.composition': 'Writing quiz',
  'chat.mode.word': 'Vocabulary quiz',
  'chat.mode.journal': 'Journal',
  'chat.hint.distill': 'Tell me what to fix. e.g. "drop the first sentence"',
  'chat.hint.composition': 'Write your answer and send',
  'chat.hint.word': 'Type the expression for the blank',
  'chat.hint.journal': 'Write your journal…',
  'graph.emptyTitle': 'Your knowledge graph is empty',
  'graph.emptyBody':
      'Tap + to write your first journal. Your entries become a knowledge graph.',
  'graph.pinEmpty':
      "Couldn't generate a quiz from this statement — the expression may be too short or was rejected.",
  'journal.failed':
      "Couldn't process the journal. Please try again in a moment.",
  'quiz.empty':
      'No questions yet. I just started generating some — try again in a moment.',
  'quiz.sessionDone': 'You finished this session! 👏',
  'quiz.close': 'Close',
  'quiz.more': 'More',
  'settings.title': 'Settings',
  'settings.nativeLanguage': 'Native language',
  'settings.targetLanguages': 'Languages you\'re learning',
  'settings.nativeNote':
      'Changing your native language switches new knowledge graphs and the app language to it.',
  'common.save': 'Save',
  'common.saved': 'Saved.',
  'common.cancel': 'Cancel',
  'account.title': 'Enter',
  'account.welcome': 'Type an ID to open your own space.',
  'account.newId': 'New ID',
  'account.hint': '3–20 letters or digits',
  'account.enter': 'Enter',
  'account.saved': 'Saved IDs',
  'account.switch': 'Switch account',
  'account.signOut': 'Sign out',
  'account.forget': 'Remove from this device',
  'account.deleteData': 'Delete account & data',
  'account.deleteConfirm':
      'This permanently deletes all journals, graph, and quizzes for this account. Continue?',
  'account.mainHint': 'Your existing data opens under the ID "main".',
};
