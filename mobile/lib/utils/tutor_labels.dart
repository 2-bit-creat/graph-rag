/// Shared tutor language labels (extracted from the legacy tutor screen).

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
