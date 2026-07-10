import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ko.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ko')
  ];

  /// No description provided for @appTitle.
  ///
  /// In ko, this message translates to:
  /// **'MyLife English'**
  String get appTitle;

  /// No description provided for @navHome.
  ///
  /// In ko, this message translates to:
  /// **'홈'**
  String get navHome;

  /// No description provided for @navReview.
  ///
  /// In ko, this message translates to:
  /// **'돌아보기'**
  String get navReview;

  /// No description provided for @navLearn.
  ///
  /// In ko, this message translates to:
  /// **'학습'**
  String get navLearn;

  /// No description provided for @navMore.
  ///
  /// In ko, this message translates to:
  /// **'더보기'**
  String get navMore;

  /// No description provided for @navHomeSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'타임라인 · 미디어 · 캘린더'**
  String get navHomeSubtitle;

  /// No description provided for @navReviewSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'성장 통계 & 활동 현황'**
  String get navReviewSubtitle;

  /// No description provided for @navLearnSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'퀴즈로 복습'**
  String get navLearnSubtitle;

  /// No description provided for @navMoreSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'전체 메뉴 & 설정'**
  String get navMoreSubtitle;

  /// No description provided for @profileSettings.
  ///
  /// In ko, this message translates to:
  /// **'프로필 설정'**
  String get profileSettings;

  /// No description provided for @pipelineDebug.
  ///
  /// In ko, this message translates to:
  /// **'파이프라인 디버그'**
  String get pipelineDebug;

  /// No description provided for @kgPipelineDebug.
  ///
  /// In ko, this message translates to:
  /// **'KG 파이프라인 디버그'**
  String get kgPipelineDebug;

  /// No description provided for @settingsTitle.
  ///
  /// In ko, this message translates to:
  /// **'내 프로필'**
  String get settingsTitle;

  /// No description provided for @settingsSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'언어 · 레벨'**
  String get settingsSubtitle;

  /// No description provided for @nativeLanguage.
  ///
  /// In ko, this message translates to:
  /// **'모국어'**
  String get nativeLanguage;

  /// No description provided for @nativeLanguageHint.
  ///
  /// In ko, this message translates to:
  /// **'힌트·설명이 이 언어로 생성됩니다'**
  String get nativeLanguageHint;

  /// No description provided for @targetLanguages.
  ///
  /// In ko, this message translates to:
  /// **'학습 언어 및 레벨'**
  String get targetLanguages;

  /// No description provided for @saveProfile.
  ///
  /// In ko, this message translates to:
  /// **'프로필 저장'**
  String get saveProfile;

  /// No description provided for @profileSaved.
  ///
  /// In ko, this message translates to:
  /// **'프로필이 저장되었습니다'**
  String get profileSaved;

  /// No description provided for @saveFailed.
  ///
  /// In ko, this message translates to:
  /// **'저장 실패: {error}'**
  String saveFailed(String error);

  /// No description provided for @selectAtLeastOneLanguage.
  ///
  /// In ko, this message translates to:
  /// **'언어를 최소 하나 선택해 주세요'**
  String get selectAtLeastOneLanguage;

  /// No description provided for @kgTitle.
  ///
  /// In ko, this message translates to:
  /// **'내 지식 그래프'**
  String get kgTitle;

  /// No description provided for @kgEmpty.
  ///
  /// In ko, this message translates to:
  /// **'아직 지식 그래프가 비어 있습니다'**
  String get kgEmpty;

  /// No description provided for @kgEmptyHint.
  ///
  /// In ko, this message translates to:
  /// **'일기를 작성하고 그래프를 빌드하면 노드가 나타납니다'**
  String get kgEmptyHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ko'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ko':
      return AppLocalizationsKo();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
