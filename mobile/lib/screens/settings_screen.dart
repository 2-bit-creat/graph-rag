import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'quiz_queue_screen.dart';

// ─── Static data ──────────────────────────────────────────────────────────────

// Learnable target languages (the quiz engine is tuned for these three).
const _kLanguages = [
  (key: 'english', label: '영어',   flag: '🇺🇸'),
  (key: 'german',  label: '독일어', flag: '🇩🇪'),
  (key: 'korean',  label: '한국어', flag: '🇰🇷'),
];

// Native languages (UI + graph + explanations are generated in this language).
const _kNativeLanguages = [
  (key: 'korean',  label: '한국어 🇰🇷'),
  (key: 'english', label: '영어 🇺🇸'),
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
    case 'Pre-A1~A1': return Colors.grey;
    case 'A2':        return Colors.green.shade600;
    case 'B1':        return Colors.teal.shade600;
    case 'B2':        return Colors.blue.shade600;
    case 'C1':        return Colors.purple.shade600;
    case 'C2':        return Colors.red.shade700;
    default:          return Colors.grey;
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
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
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
            _targetLanguages = {profile['target_language']?.toString() ?? 'english'};
          }
          _nativeLanguage = profile['native_language']?.toString() ?? 'korean';
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
        const SnackBar(content: Text('언어를 최소 하나 선택해 주세요')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final langs = _targetLanguages.toList();
      final levelsInt = _langLevels.map((k, v) => MapEntry(k, v.round()));

      await Future.wait([
        apiClient.updateTargetLanguages(langs),
        apiClient.updateNativeLanguage(_nativeLanguage),
        apiClient.updateLanguageLevels(levelsInt),
      ]);

      // Switch the app UI language immediately on save.
      await appLocaleController.setFromNativeLanguage(_nativeLanguage);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('프로필이 저장되었습니다')),
        );
        _showReprocessDialogIfNeeded(langs);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
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
    final breakdown = languages.map((l) => '• $l: ${perLang[l] ?? 0}개 노드').join('\n');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('표현 추출 실행'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('미처리 $pending개(노드×언어)에 대해 표현을 추출합니다.\n'),
            Text(breakdown, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            const Text(
              '노드당 1번의 API 호출로 모든 언어를 처리합니다.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('나중에')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('지금 실행')),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final result = await apiClient.triggerReprocess(languages);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${result['enqueued'] ?? 0}개 추출 작업 시작됨')),
          );
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppHubAppBar(title: '내 프로필', subtitle: '언어 · 레벨'),
      body: _loading
          ? const AppLoadingScreen()
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageH, AppSpacing.md, AppSpacing.pageH, AppSpacing.xxl,
              ),
              children: [
                // ── 모국어 ──────────────────────────────────────────────────
                _SectionCard(
                  title: '모국어',
                  subtitle: '힌트·설명이 이 언어로 생성됩니다',
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: _kNativeLanguages.map((lang) => ChoiceChip(
                      label: Text(lang.label),
                      selected: _nativeLanguage == lang.key,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() => _nativeLanguage = lang.key),
                    )).toList(),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── 학습 언어 + 레벨 ────────────────────────────────────────
                _SectionCard(
                  title: '학습 언어 및 레벨',
                  subtitle: '연습할 언어를 등록하고 레벨을 설정하세요 · 세션별 전환은 튜터에서',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: _kLanguages.map((lang) {
                          final selected = _targetLanguages.contains(lang.key);
                          return FilterChip(
                            label: Text('${lang.flag} ${lang.label}'),
                            selected: selected,
                            onSelected: _saving
                                ? null
                                : (on) => setState(() {
                                      if (on) {
                                        _targetLanguages.add(lang.key);
                                        _langLevels.putIfAbsent(lang.key, () => 10);
                                      } else if (_targetLanguages.length > 1) {
                                        _targetLanguages.remove(lang.key);
                                      }
                                    }),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                      ..._targetLanguages.map((lang) {
                        final langInfo = _kLanguages.firstWhere(
                          (l) => l.key == lang,
                          orElse: () => (key: lang, label: lang, flag: '🌐'),
                        );
                        final level = _langLevels[lang] ?? 10;
                        final cefr = _cefrLabel(level.round());
                        return _LangLevelSlider(
                          flag: langInfo.flag,
                          label: langInfo.label,
                          level: level,
                          cefr: cefr,
                          cefrColor: _cefrColor(cefr),
                          disabled: _saving,
                          onChanged: (v) => setState(() => _langLevels[lang] = v),
                        );
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                const SizedBox(height: AppSpacing.lg),

                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('프로필 저장'),
                ),
                const SizedBox(height: AppSpacing.md),

                FilledButton.tonalIcon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const QuizQueueScreen()),
                  ),
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('내 퀴즈 큐 보러가기'),
                ),
                const SizedBox(height: AppSpacing.lg),

                // ── Dev ──────────────────────────────────────────────────────
                Card(
                  child: Column(children: [
                    ListTile(
                      leading: Icon(Icons.developer_mode,
                          color: Theme.of(context).colorScheme.primary),
                      title: const Text('Dev Mode'),
                      subtitle: const Text('로그인 없이 dev@local 사용자로 동작합니다.'),
                    ),
                    const Divider(height: 1),
                    const ListTile(
                      leading: Icon(Icons.folder_outlined),
                      title: Text('Debug artifacts'),
                      subtitle: Text('backend/debug_runs/{entry_id}/ 에 파이프라인 단계별 산출물'),
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
    required this.flag,
    required this.label,
    required this.level,
    required this.cefr,
    required this.cefrColor,
    required this.onChanged,
    this.disabled = false,
  });

  final String flag;
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
              Text(flag, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
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
