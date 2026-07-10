/// Human-readable label for a tutor target-language code.
String tutorLangLabel(String code) => switch (code) {
      'english' => 'English',
      'german' => 'Deutsch',
      'japanese' => '日本語',
      'chinese' => '中文',
      'spanish' => 'Español',
      'french' => 'Français',
      _ => code,
    };
