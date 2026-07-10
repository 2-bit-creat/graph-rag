// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'MyLife English';

  @override
  String get navHome => 'Home';

  @override
  String get navReview => 'Review';

  @override
  String get navLearn => 'Learn';

  @override
  String get navMore => 'More';

  @override
  String get navHomeSubtitle => 'Timeline · Media · Calendar';

  @override
  String get navReviewSubtitle => 'Growth stats & activity';

  @override
  String get navLearnSubtitle => 'Review with quizzes';

  @override
  String get navMoreSubtitle => 'Menu & settings';

  @override
  String get profileSettings => 'Profile settings';

  @override
  String get pipelineDebug => 'Pipeline debug';

  @override
  String get kgPipelineDebug => 'KG pipeline debug';

  @override
  String get settingsTitle => 'My profile';

  @override
  String get settingsSubtitle => 'Language · Level';

  @override
  String get nativeLanguage => 'Native language';

  @override
  String get nativeLanguageHint =>
      'Hints and explanations are generated in this language';

  @override
  String get targetLanguages => 'Target languages & levels';

  @override
  String get saveProfile => 'Save profile';

  @override
  String get profileSaved => 'Profile saved';

  @override
  String saveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get selectAtLeastOneLanguage => 'Select at least one language';

  @override
  String get kgTitle => 'My knowledge graph';

  @override
  String get kgEmpty => 'Your knowledge graph is empty';

  @override
  String get kgEmptyHint =>
      'Write journal entries and build the graph to see nodes';
}
