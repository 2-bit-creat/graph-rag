/// Shared tutor language labels (extracted from the legacy tutor screen).
String tutorLangLabel(String code) => switch (code) {
      'english' => 'English',
      'german' => 'Deutsch',
      'japanese' => '?ĽćŹčŞ?,
      'chinese' => 'ä¸?',
      'spanish' => 'EspaĂąol',
      'french' => 'FranĂ§ais',
      _ => code,
    };

enum TutorSourceMode { journal, review }

extension TutorSourceModeX on TutorSourceMode {
  String get api => switch (this) {
        TutorSourceMode.journal => 'journal',
        TutorSourceMode.review => 'review',
      };
  String get label => switch (this) {
        TutorSourceMode.journal => '???źę¸°?ě',
        TutorSourceMode.review => 'ëłľěľ ?í',
      };
}
