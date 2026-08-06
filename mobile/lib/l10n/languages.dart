// Single source of truth for language lists across the app — mirrors the
// backend's app/languages.py SUPPORTED_PAIRS. Only 3 pairs are supported:
// korean->english, korean->german, english->korean. A learner's native
// language is fixed at account creation; the target choices offered in
// settings/quiz pickers are always derived from it via [targetsForNative],
// never hardcoded per screen — that drift (quiz_pipeline_panel.dart's old
// per-file language map was missing 'korean' entirely) is exactly what this
// module exists to prevent.
import 'app_strings.dart';

/// Languages the user may set as their native (UI/graph/explanation)
/// language — chosen once at account creation, locked afterward.
List<({String key, String label})> get kNativeLanguages => [
      (key: 'korean', label: tr('kg.langKorean')),
      (key: 'english', label: tr('kg.langEnglish')),
    ];

/// Every language the quiz engine can target, with flag emoji for pickers.
/// Use [targetsForNative] rather than this directly when offering choices —
/// a learner can never target their own native language.
List<({String key, String label, String flag})> get kTargetLanguages => [
      (key: 'english', label: tr('kg.langEnglish'), flag: '🇺🇸'),
      (key: 'german', label: tr('kg.langGerman'), flag: '🇩🇪'),
      (key: 'korean', label: tr('kg.langKorean'), flag: '🇰🇷'),
    ];

const Map<String, Set<String>> _kSupportedPairs = {
  'korean': {'english', 'german'},
  'english': {'korean'},
};

/// The target languages available to a learner with the given native
/// language — mirrors backend languages.valid_target_for_native(). Falls
/// back to the full target list for an unrecognized native so a caller
/// never silently gets zero choices.
List<({String key, String label, String flag})> targetsForNative(
        String? native) =>
    kTargetLanguages
        .where((l) => _kSupportedPairs[native]?.contains(l.key) ?? true)
        .toList();

/// Locale-aware label for any of the 3 supported languages; falls back to
/// the raw key title-cased for anything else (defensive, not expected to
/// fire for a supported pair).
String langLabel(String key) {
  switch (key) {
    case 'english':
      return tr('kg.langEnglish');
    case 'german':
      return tr('kg.langGerman');
    case 'korean':
      return tr('kg.langKorean');
    default:
      return key.isEmpty ? key : key[0].toUpperCase() + key.substring(1);
  }
}

/// Broader legacy label map (Korean-only copy), kept for quiz rows created
/// before the 3-pair restriction that may still carry an older target
/// language (japanese, chinese, ...). New pickers should use [langLabel] /
/// [kTargetLanguages] instead; this exists only so old data still renders a
/// readable label rather than a raw language code.
const Map<String, String> kLegacyLanguageLabelsKo = {
  'english': '영어',
  'german': '독일어',
  'korean': '한국어',
  'japanese': '일본어',
  'chinese': '중국어',
  'spanish': '스페인어',
  'french': '프랑스어',
  'portuguese': '포르투갈어',
  'italian': '이탈리아어',
  'arabic': '아랍어',
  'russian': '러시아어',
};
