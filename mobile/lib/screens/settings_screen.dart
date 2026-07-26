import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../auth/account_controller.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'privacy_policy_screen.dart';

// ─── Static data ──────────────────────────────────────────────────────────────

// Learnable target languages (the quiz engine is tuned for these three).
// A learner can't "learn" their own native language, so [forNative] excludes
// it — mirrors the backend's languages.valid_target_for_native().
List<({String key, String label})> _kLanguages({String? forNative}) => [
      (key: 'english', label: tr('kg.langEnglish')),
      (key: 'german', label: tr('kg.langGerman')),
      (key: 'korean', label: tr('kg.langKorean')),
    ].where((l) => l.key != forNative).toList();

// Native languages (UI + graph + explanations are generated in this language).
List<({String key, String label})> get _kNativeLanguages => [
      (key: 'korean', label: tr('kg.langKorean')),
      (key: 'english', label: tr('kg.langEnglish')),
    ];

String _cefrLabel(int level) {
  if (level <= 15) return 'Pre-A1~A1';
  if (level <= 35) return 'A2';
  if (level <= 55) return 'B1';
  if (level <= 75) return 'B2';
  if (level <= 90) return 'C1';
  return 'C2';
}

Color _cefrColor(String cefr) {
  switch (cefr) {
    case 'Pre-A1~A1':
      return Colors.grey;
    case 'A2':
      return Colors.green.shade600;
    case 'B1':
      return Colors.teal.shade600;
    case 'B2':
      return Colors.blue.shade600;
    case 'C1':
      return Colors.purple.shade600;
    case 'C2':
      return Colors.red.shade700;
    default:
      return Colors.grey;
  }
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Set<String> _targetLanguages = {'english'};
  String _nativeLanguage = 'korean';
  // Per-language level: {english: 50, german: 10}
  Map<String, double> _langLevels = {'english': 10};
  double _dailyClozeTarget = 20;
  double _dailyCompositionTarget = 5;
  double _quizReviewRatio = 0.5;
  bool _loading = true;
  bool _saving = false;
  bool _speakerConsent = accountController.speakerIdConsent;
  bool _speakerBusy = false;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── Privacy & data ────────────────────────────────────────────────────────

  Future<void> _toggleSpeakerConsent(bool value) async {
    setState(() => _speakerBusy = true);
    try {
      final policy = await apiClient.getPrivacyPolicy();
      await apiClient.recordConsent(
        version: policy['version']?.toString() ?? '',
        speakerIdConsent: value,
      );
      accountController.setSpeakerIdConsent(value);
      if (mounted) {
        setState(() => _speakerConsent = value);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(value
                ? tr('settings.speakerConsentGiven')
                : tr('settings.speakerConsentWithdrawn')),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('settings.changeFailed', {
              'error': e.toString().replaceFirst('Exception: ', ''),
            })),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _speakerBusy = false);
    }
  }

  Future<void> _exportData() async {
    setState(() => _exporting = true);
    try {
      final json = await apiClient.exportMyData();
      final bytes = Uint8List.fromList(utf8.encode(json));
      String? savedPath;
      try {
        savedPath = await FilePicker.platform.saveFile(
          dialogTitle: tr('settings.exportSaveDialogTitle'),
          fileName: 'my-data.json',
          bytes: bytes,
        );
      } catch (_) {
        savedPath = null; // e.g. unsupported on this platform
      }
      if (!mounted) return;
      if (savedPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('settings.exportSavedToFile'))),
        );
      } else {
        // Universal fallback so the right is always exercisable.
        await Clipboard.setData(ClipboardData(text: json));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('settings.exportCopiedToClipboard'))),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('settings.exportFailed', {
              'error': e.toString().replaceFirst('Exception: ', ''),
            })),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _load() async {
    try {
      final profile = await apiClient.getQuizProfile();
      if (mounted) {
        setState(() {
          final rawLangs = profile['target_languages'];
          if (rawLangs is List && rawLangs.isNotEmpty) {
            _targetLanguages = rawLangs.map((e) => e.toString()).toSet();
          } else {
            _targetLanguages = {
              profile['target_language']?.toString() ?? 'english'
            };
          }
          _nativeLanguage = profile['native_language']?.toString() ?? 'korean';
          _dailyClozeTarget =
              (profile['daily_cloze_target'] as num?)?.toDouble() ?? 20;
          _dailyCompositionTarget =
              (profile['daily_composition_target'] as num?)?.toDouble() ?? 5;
          _quizReviewRatio =
              (profile['quiz_review_ratio'] as num?)?.toDouble() ?? 0.5;
          // Sync the app UI language to the loaded native language.
          appLocaleController.setFromNativeLanguage(_nativeLanguage);

          // Load per-language levels
          final rawLevels = profile['language_levels'];
          if (rawLevels is Map && rawLevels.isNotEmpty) {
            _langLevels = rawLevels.map(
              (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
            );
          } else {
            // Fall back to legacy current_level for English
            final legacy = (profile['current_level'] as num?)?.toDouble() ?? 10;
            _langLevels = {'english': legacy};
          }
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_targetLanguages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('settings.selectAtLeastOneLanguage'))),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final langs = _targetLanguages.toList();
      final levelsInt = _langLevels.map((k, v) => MapEntry(k, v.round()));

      await apiClient.updateProfileSettings(
        nativeLanguage: _nativeLanguage,
        targetLanguages: langs,
        languageLevels: levelsInt,
        dailyClozeTarget: _dailyClozeTarget.round(),
        dailyCompositionTarget: _dailyCompositionTarget.round(),
        quizReviewRatio: _quizReviewRatio,
      );

      // Switch the app UI language immediately on save.
      await appLocaleController.setFromNativeLanguage(_nativeLanguage);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('settings.profileSaved'))),
        );
        _showReprocessDialogIfNeeded(langs);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('settings.saveFailed', {'error': e}))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showReprocessDialogIfNeeded(List<String> languages) async {
    if (languages.length <= 1) return;
    Map<String, dynamic>? info;
    try {
      info = await apiClient.getReprocessInfo(languages);
    } catch (_) {}
    if (!mounted) return;
    final pending = info?['pending_pairs'] as int? ?? 0;
    if (pending == 0) return;

    final perLang = info?['per_language'] as Map? ?? {};
    final breakdown = languages
        .map((l) => tr('settings.reprocessNodeCountLine', {
              'lang': l,
              'count': perLang[l] ?? 0,
            }))
        .join('\n');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('settings.reprocessDialogTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('settings.reprocessBody', {'pending': pending})),
            Text(breakdown, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            Text(
              tr('settings.reprocessOneApiCallNote'),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.later'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('settings.runNow'))),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final result = await apiClient.triggerReprocess(languages);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('settings.reprocessStartedSnackbar', {
                'count': result['enqueued'] ?? 0,
              })),
            ),
          );
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppHubAppBar(
          title: tr('settings.myProfileTitle'),
          subtitle: tr('settings.langLevelSubtitle')),
      body: _loading
          ? const AppLoadingScreen()
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageH,
                AppSpacing.md,
                AppSpacing.pageH,
                AppSpacing.xxl,
              ),
              children: [
                // ── Native language ─────────────────────────────────────────
                _SectionCard(
                  title: tr('settings.nativeLanguageTitle'),
                  subtitle: tr('settings.nativeLanguageSubtitle'),
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: _kNativeLanguages
                        .map((lang) => ChoiceChip(
                              label: Text(lang.label),
                              selected: _nativeLanguage == lang.key,
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(() {
                                        _nativeLanguage = lang.key;
                                        // A learner can't "learn" their own native
                                        // language — drop it if it was already picked
                                        // as a target.
                                        if (_targetLanguages.remove(lang.key) &&
                                            _targetLanguages.isEmpty) {
                                          _targetLanguages.add(
                                            _kLanguages(forNative: lang.key)
                                                .first
                                                .key,
                                          );
                                        }
                                      }),
                            ))
                        .toList(),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Learning languages + level ──────────────────────────────
                _SectionCard(
                  title: tr('settings.learningLanguagesTitle'),
                  subtitle: tr('settings.learningLanguagesSubtitle'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children:
                            _kLanguages(forNative: _nativeLanguage).map((lang) {
                          final selected = _targetLanguages.contains(lang.key);
                          return FilterChip(
                            avatar:
                                const Icon(Icons.language_rounded, size: 16),
                            label: Text(lang.label),
                            selected: selected,
                            onSelected: _saving
                                ? null
                                : (on) => setState(() {
                                      if (on) {
                                        _targetLanguages.add(lang.key);
                                        _langLevels.putIfAbsent(
                                            lang.key, () => 10);
                                      } else if (_targetLanguages.length > 1) {
                                        _targetLanguages.remove(lang.key);
                                      }
                                    }),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                      ..._targetLanguages.map((lang) {
                        final langInfo =
                            _kLanguages(forNative: _nativeLanguage).firstWhere(
                          (l) => l.key == lang,
                          orElse: () => (key: lang, label: lang),
                        );
                        final level = _langLevels[lang] ?? 10;
                        final cefr = _cefrLabel(level.round());
                        return _LangLevelSlider(
                          label: langInfo.label,
                          level: level,
                          cefr: cefr,
                          cefrColor: _cefrColor(cefr),
                          disabled: _saving,
                          onChanged: (v) =>
                              setState(() => _langLevels[lang] = v),
                        );
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                const SizedBox(height: AppSpacing.md),
                AppSurfaceCard(
                  child: Row(
                    children: [
                      const Icon(Icons.local_fire_department_rounded,
                          color: AppColors.accentWarm),
                      const SizedBox(width: AppSpacing.md),
                      const Expanded(
                        child: Text(
                          '일일 단어·작문 목표는 ‘내 학습률’에서 설정할 수 있습니다.',
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: AppSpacing.lg),

                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(tr('settings.saveProfileButton')),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Privacy & data ───────────────────────────────────────────
                Card(
                  child: Column(children: [
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(tr('settings.privacyPolicyTitle')),
                      subtitle: Text(tr('settings.privacyPolicySubtitle')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const PrivacyPolicyScreen()),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.record_voice_over_outlined),
                      title: Text(tr('settings.speakerConsentTitle')),
                      subtitle: Text(tr('settings.speakerConsentSubtitle')),
                      value: _speakerConsent,
                      onChanged: _speakerBusy ? null : _toggleSpeakerConsent,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.download_outlined),
                      title: Text(tr('settings.exportDataTitle')),
                      subtitle: Text(tr('settings.exportDataSubtitle')),
                      trailing: _exporting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.chevron_right),
                      onTap: _exporting ? null : _exportData,
                    ),
                  ]),
                ),
                const SizedBox(height: AppSpacing.lg),

                // ── Dev ──────────────────────────────────────────────────────
                Card(
                  child: Column(children: [
                    ListTile(
                      leading: Icon(Icons.developer_mode,
                          color: Theme.of(context).colorScheme.primary),
                      title: Text(tr('settings.devModeTitle')),
                      subtitle: Text(tr('settings.devModeSubtitle')),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(tr('settings.debugArtifactsTitle')),
                      subtitle: Text(tr('settings.debugArtifactsSubtitle')),
                    ),
                  ]),
                ),
              ],
            ),
    );
  }
}

// ─── Reusable sub-widgets ─────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

class _LangLevelSlider extends StatelessWidget {
  const _LangLevelSlider({
    required this.label,
    required this.level,
    required this.cefr,
    required this.cefrColor,
    required this.onChanged,
    this.disabled = false,
  });

  final String label;
  final double level;
  final String cefr;
  final Color cefrColor;
  final ValueChanged<double> onChanged;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.translate_rounded,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cefrColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: cefrColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  cefr,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cefrColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 36,
                child: Text(
                  'Lv.${level.round()}',
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: cefrColor,
              thumbColor: cefrColor,
              overlayColor: cefrColor.withValues(alpha: 0.15),
            ),
            child: Slider(
              value: level,
              min: 1,
              max: 100,
              divisions: 99,
              onChanged: disabled ? null : onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
