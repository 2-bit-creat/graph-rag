import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'tutor_screen.dart' show tutorLangLabel;

/// ?�터?� 배운 ?�현 ?�체 목록 ???�릴?�서 ?��? ?�현???�·예문�??�제 ?�갈?�는지"?�
/// ?�께 ?�시 본다. ?�어�???���?구분?�서 보고, 롱프?�스�???��.
class TutorVocabScreen extends StatefulWidget {
  const TutorVocabScreen({super.key, this.initialLanguage});

  /// 진입 ???�택???�어 ?�터 (null = ?�체).
  final String? initialLanguage;

  @override
  State<TutorVocabScreen> createState() => _TutorVocabScreenState();
}

class _TutorVocabScreenState extends State<TutorVocabScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];

  /// null = ?�체 보기.
  String? _langFilter;

  /// ?�?�된 ?�현?�에 ?�제�?존재?�는 ?�어 목록 (?�렬 고정).
  List<String> get _languages {
    final langs = _items
        .map((e) => (e['language']?.toString() ?? 'english'))
        .toSet()
        .toList()
      ..sort();
    return langs;
  }

  List<Map<String, dynamic>> get _visibleItems => _langFilter == null
      ? _items
      : _items
          .where((e) => (e['language']?.toString() ?? 'english') == _langFilter)
          .toList();

  @override
  void initState() {
    super.initState();
    _langFilter = widget.initialLanguage;
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
        title: const Text('표현 삭제'),
        content: Text('"$word"을(를) 단어장에서 지울까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
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
    final visible = _visibleItems;
    return Scaffold(
      appBar: AppHubAppBar(
        title: '튜터에 배운 표현',
        subtitle: _loading
            ? null
            : _langFilter == null
                ? '${_items.length}개 · 길게 눌러 삭제'
                : '${tutorLangLabel(_langFilter!)} ${visible.length}개 · 길게 눌러 삭제',
      ),
      body: _loading
          ? const AppLoadingScreen()
          : _items.isEmpty
              ? const AppEmptyState(
                  icon: Icons.style_outlined,
                  title: '아직 담은 표현이 없어요',
                  subtitle: '튜터 첨삭에서 아까운 표현을 담으면 여기 모여요',
                )
              : Column(
                  children: [
                    if (_languages.length > 1) _buildLanguageFilter(),
                    Expanded(
                      child: visible.isEmpty
                          ? const AppEmptyState(
                              icon: Icons.style_outlined,
                              title: '이 언어에 담은 표현이 없어요',
                              subtitle: '다른 언어 탭을 확인해 보세요',
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(AppSpacing.pageH,
                                  AppSpacing.md, AppSpacing.pageH, AppSpacing.xxl),
                              itemCount: visible.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: AppSpacing.sm),
                              itemBuilder: (context, i) => _VocabTile(
                                  item: visible[i],
                                  onLongPress: () => _delete(visible[i])),
                            ),
                    ),
                  ],
                ),
    );
  }

  /// ?�어�?보기 ???�?�된 ?�현??2�??�상 ?�어??걸쳐 ?�을 ?�만 ?�출.
  Widget _buildLanguageFilter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageH, AppSpacing.sm, AppSpacing.pageH, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ChoiceChip(
              label: Text('전체 ${_items.length}'),
              selected: _langFilter == null,
              onSelected: (_) => setState(() => _langFilter = null),
            ),
            for (final lang in _languages) ...[
              const SizedBox(width: AppSpacing.xs),
              ChoiceChip(
                label: Text(
                    '${tutorLangLabel(lang)} ${_items.where((e) => (e['language']?.toString() ?? 'english') == lang).length}'),
                selected: _langFilter == lang,
                onSelected: (_) => setState(() => _langFilter = lang),
              ),
            ],
          ],
        ),
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
                          color: context.mutedText,
                        )),
              ),
            if (example.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('예: $example',
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
                    child: Text('이 문장에서 아까웠어요: $promptKo',
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
