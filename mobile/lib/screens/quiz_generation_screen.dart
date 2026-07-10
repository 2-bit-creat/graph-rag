import 'package:flutter/material.dart';

import '../api/client.dart';
import '../compose/compose_session_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../utils/tutor_lang_label.dart';

/// 문제 생성 페이지 — 작문(composition) 문제를 수동으로 만들고 대기 큐를 관리한다.
///
/// 생성은 일기 기반(journal)만. 만들어진 문제는 생성된 순서(FIFO)대로 작문
/// 퀴즈에서 출제된다. 일기가 없으면 409(no_seed)로 실패하고 일기 작성을 안내.
class QuizGenerationScreen extends StatefulWidget {
  const QuizGenerationScreen({super.key});

  @override
  State<QuizGenerationScreen> createState() => _QuizGenerationScreenState();
}

class _QuizGenerationScreenState extends State<QuizGenerationScreen> {
  bool _loading = true;
  bool _generating = false;

  List<String> _languages = ['english'];
  String _language = 'english';
  int _count = 3;
  String _difficulty = 'normal';

  List<Map<String, dynamic>> _queue = [];
  int _reviewDue = 0;

  static const _counts = [1, 3, 5, 10];
  static const _difficulties = [
    (value: 'easy', label: '쉽게'),
    (value: 'normal', label: '보통'),
    (value: 'hard', label: '어렵게'),
  ];

  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  Future<void> _load({bool initial = false}) async {
    if (initial) setState(() => _loading = true);
    try {
      final results = await Future.wait([
        apiClient.getQuizProfile(),
        apiClient.getCompositionQuizQueue(),
      ]);
      final profile = results[0] as Map<String, dynamic>;
      final queue = results[1] as List<Map<String, dynamic>>;

      final rawLangs = profile['target_languages'];
      final langs = (rawLangs is List && rawLangs.isNotEmpty)
          ? rawLangs.map((e) => e.toString()).toList()
          : [profile['target_language']?.toString() ?? 'english'];

      var reviewDue = 0;
      final queueCounts = profile['queue_counts'];
      if (queueCounts is Map && queueCounts['composition'] is Map) {
        reviewDue =
            ((queueCounts['composition'] as Map)['review'] as num?)?.toInt() ?? 0;
      }

      if (!mounted) return;
      setState(() {
        _languages = langs;
        if (!_languages.contains(_language)) _language = _languages.first;
        _queue = queue;
        _reviewDue = reviewDue;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(e);
    }
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    try {
      await apiClient.generateCompositionQuizzes(
        language: _language,
        count: _count,
        difficulty: _difficulty,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('작문 문제 $_count개를 만들었어요')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      if (e.toString().contains('no_seed')) {
        _showNoSeedDialog();
      } else {
        _showError(e);
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _showNoSeedDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('일기가 필요해요'),
        content: const Text('작문 문제는 내 일기 문장으로 만들어요.\n먼저 일기를 한 편 작성해 주세요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              composeSession.open(startNew: true);
            },
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: const Text('일기 쓰기'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final id = item['id']?.toString();
    if (id == null) return;
    try {
      await apiClient.deleteCompositionQuiz(id);
      if (!mounted) return;
      setState(() => _queue.removeWhere((q) => q['id']?.toString() == id));
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const AppHubAppBar(
        title: '문제 생성',
        subtitle: '내 일기 문장으로 작문 문제 만들기',
      ),
      body: _loading
          ? const AppLoadingScreen(message: '불러오는 중…')
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageH, AppSpacing.lg, AppSpacing.pageH, AppSpacing.xxl),
                children: [
                  _buildGeneratorCard(),
                  const SizedBox(height: AppSpacing.xl),
                  _buildQueueSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildGeneratorCard() {
    return AppSurfaceCard(
      tint: AppColors.hubQuiz,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_fix_high_rounded,
                  size: 18, color: AppColors.hubQuiz),
              const SizedBox(width: 6),
              Text('새 작문 문제',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
              const Spacer(),
              Text('일기 기반',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.textMuted,
                      )),
            ],
          ),
          if (_languages.length > 1) ...[
            const SizedBox(height: AppSpacing.md),
            _chipRowLabel('언어'),
            const SizedBox(height: 6),
            Wrap(
              spacing: AppSpacing.xs,
              children: [
                for (final lang in _languages)
                  ChoiceChip(
                    label: Text(tutorLangLabel(lang)),
                    selected: lang == _language,
                    onSelected: _generating
                        ? null
                        : (_) => setState(() => _language = lang),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _chipRowLabel('개수'),
          const SizedBox(height: 6),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final n in _counts)
                ChoiceChip(
                  label: Text('$n개'),
                  selected: n == _count,
                  onSelected:
                      _generating ? null : (_) => setState(() => _count = n),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _chipRowLabel('난이도'),
          const SizedBox(height: 6),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final d in _difficulties)
                ChoiceChip(
                  label: Text(d.label),
                  selected: d.value == _difficulty,
                  onSelected: _generating
                      ? null
                      : (_) => setState(() => _difficulty = d.value),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _generating ? null : _generate,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.hubQuiz,
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              icon: _generating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.bolt_rounded, size: 20),
              label: Text(_generating ? '생성 중… (문제당 몇 초 걸려요)' : '문제 생성'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chipRowLabel(String text) {
    return Text(text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: AppColors.textMuted,
              fontWeight: FontWeight.w700,
            ));
  }

  Widget _buildQueueSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(
          title: '대기 중인 문제 (${_queue.length})',
          subtitle: _reviewDue > 0
              ? '생성된 순서대로 출제 · 복습 예정 $_reviewDue개'
              : '생성된 순서대로 출제돼요',
        ),
        const SizedBox(height: AppSpacing.md),
        if (_queue.isEmpty)
          AppSurfaceCard(
            child: Row(
              children: [
                const Icon(Icons.inbox_rounded,
                    size: 20, color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('생성된 문제가 없어요. 위에서 만들어 보세요.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textMuted,
                          )),
                ),
              ],
            ),
          )
        else
          for (var i = 0; i < _queue.length; i++) ...[
            _QueueItemCard(
              index: i + 1,
              item: _queue[i],
              onDelete: () => _deleteItem(_queue[i]),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
      ],
    );
  }
}

// ── Queue item card ───────────────────────────────────────────────────────────

class _QueueItemCard extends StatelessWidget {
  const _QueueItemCard({
    required this.index,
    required this.item,
    required this.onDelete,
  });

  final int index;
  final Map<String, dynamic> item;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final qd = (item['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final prompt = item['question_ko']?.toString() ?? '';
    final cefr = qd['cefr']?.toString() ?? '';
    final style = qd['style'];
    final focusKo = style is Map ? (style['focus_ko']?.toString() ?? '') : '';
    final difficulty = switch (qd['difficulty']?.toString() ?? '') {
      'easy' => '쉽게',
      'hard' => '어렵게',
      _ => '',
    };
    final lang = tutorLangLabel(qd['language']?.toString() ?? '');

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.hubQuiz.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Text('$index',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.hubQuiz)),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(height: 1.35)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (lang.isNotEmpty) _miniBadge(lang, AppColors.hubGraph),
                    if (cefr.isNotEmpty) _miniBadge(cefr, AppColors.textMuted),
                    if (focusKo.isNotEmpty) _miniBadge(focusKo, AppColors.hubQuiz),
                    if (difficulty.isNotEmpty)
                      _miniBadge(difficulty, AppColors.accentWarm),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onDelete,
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: AppColors.textMuted,
            tooltip: '삭제',
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }

  Widget _miniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style:
              TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
    );
  }
}
