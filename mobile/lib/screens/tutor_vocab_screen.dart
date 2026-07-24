import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../utils/tutor_lang_label.dart';

/// 튜터와 배운 표현 전체 목록 — 드릴에서 담은 표현을 뜻·예문·"언제 헷갈렸는지"와
/// 함께 다시 본다. 표현마다 언어 배지가 붙는다. 롱프레스로 삭제.
class TutorVocabScreen extends StatefulWidget {
  const TutorVocabScreen({super.key});

  @override
  State<TutorVocabScreen> createState() => _TutorVocabScreenState();
}

class _TutorVocabScreenState extends State<TutorVocabScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final resp = await apiClient.getTutorVocab();
      final items = (resp['items'] as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _items = items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final word = item['word']?.toString() ?? '';
    final lang = item['language']?.toString() ?? 'english';
    if (word.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('statementBank.deleteExprTitle')),
        content: Text(tr('tutorVocab.deleteConfirmBody', {'word': word})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.delete'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await apiClient.deleteTutorExpression(expression: word, language: lang);
      if (mounted) setState(() => _items.removeWhere((e) => e['word'] == word && e['language'] == lang));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppHubAppBar(
        title: tr('tutorVocab.pageTitle'),
        subtitle: _loading ? null : tr('tutorVocab.subtitle', {'count': _items.length}),
      ),
      body: _loading
          ? const AppLoadingScreen()
          : _items.isEmpty
              ? AppEmptyState(
                  icon: Icons.style_outlined,
                  title: tr('tutorVocab.emptyTitle'),
                  subtitle: tr('tutorVocab.emptySubtitle'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.pageH,
                      AppSpacing.md, AppSpacing.pageH, AppSpacing.xxl),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, i) =>
                      _VocabTile(item: _items[i], onLongPress: () => _delete(_items[i])),
                ),
    );
  }
}

class _VocabTile extends StatelessWidget {
  const _VocabTile({required this.item, required this.onLongPress});
  final Map<String, dynamic> item;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final word = item['word']?.toString() ?? '';
    final meaning = item['meaning']?.toString() ?? '';
    final example = item['example']?.toString() ?? '';
    final lang = item['language']?.toString() ?? '';
    final promptKo = item['prompt_ko']?.toString() ?? '';

    return InkWell(
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: AppSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(word,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          )),
                ),
                if (lang.isNotEmpty) _LangBadge(language: lang),
              ],
            ),
            if (meaning.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(meaning,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textMuted,
                        )),
              ),
            if (example.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('“$example”',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.65),
                        )),
              ),
            if (promptKo.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.history_edu_rounded,
                      size: 14, color: AppColors.hubQuiz),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(tr('tutorVocab.confusedInSentence', {'prompt': promptKo}),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: AppColors.hubQuiz,
                            )),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LangBadge extends StatelessWidget {
  const _LangBadge({required this.language});
  final String language;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.hubGraph.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(tutorLangLabel(language),
          style: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.hubGraph)),
    );
  }
}
