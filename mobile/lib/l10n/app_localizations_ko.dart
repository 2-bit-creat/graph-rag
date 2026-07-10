// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'MyLife English';

  @override
  String get navHome => '홈';

  @override
  String get navReview => '돌아보기';

  @override
  String get navLearn => '학습';

  @override
  String get navMore => '더보기';

  @override
  String get navHomeSubtitle => '타임라인 · 미디어 · 캘린더';

  @override
  String get navReviewSubtitle => '성장 통계 & 활동 현황';

  @override
  String get navLearnSubtitle => '퀴즈로 복습';

  @override
  String get navMoreSubtitle => '전체 메뉴 & 설정';

  @override
  String get profileSettings => '프로필 설정';

  @override
  String get pipelineDebug => '파이프라인 디버그';

  @override
  String get kgPipelineDebug => 'KG 파이프라인 디버그';

  @override
  String get settingsTitle => '내 프로필';

  @override
  String get settingsSubtitle => '언어 · 레벨';

  @override
  String get nativeLanguage => '모국어';

  @override
  String get nativeLanguageHint => '힌트·설명이 이 언어로 생성됩니다';

  @override
  String get targetLanguages => '학습 언어 및 레벨';

  @override
  String get saveProfile => '프로필 저장';

  @override
  String get profileSaved => '프로필이 저장되었습니다';

  @override
  String saveFailed(String error) {
    return '저장 실패: $error';
  }

  @override
  String get selectAtLeastOneLanguage => '언어를 최소 하나 선택해 주세요';

  @override
  String get kgTitle => '내 지식 그래프';

  @override
  String get kgEmpty => '아직 지식 그래프가 비어 있습니다';

  @override
  String get kgEmptyHint => '일기를 작성하고 그래프를 빌드하면 노드가 나타납니다';
}
