import 'dart:async';
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../utils/idempotency_key.dart';
import '../widgets/app_ui.dart';
import 'quiz_pipeline_hub_screen.dart';

class QuizExplorationScreen extends StatefulWidget {
  const QuizExplorationScreen({super.key});

  @override
  State<QuizExplorationScreen> createState() => _QuizExplorationScreenState();
}

class _QuizExplorationScreenState extends State<QuizExplorationScreen> {
  bool _loading = true;
  bool _submitting = false;
  bool _savingAuto = false;
  bool _autoGenerate = false;
  String? _error;
  List<Map<String, dynamic>> _nodes = [];
  List<Map<String, dynamic>> _runs = [];
  List<String> _languages = [];
  final Set<String> _selectedNodes = {};
  final Set<String> _selectedLanguages = {};
  Timer? _pollTimer;
  Timer? _settleRefreshTimer;
  bool _hadActiveRun = false;

  static const _languageLabels = {
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _settleRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final results = await Future.wait([
        apiClient.getQuizProfile(),
        apiClient.listQuizExplorations(),
        apiClient.listQuizGenerationRuns(),
      ]);
      final profile = Map<String, dynamic>.from(results[0]);
      final exploration = Map<String, dynamic>.from(results[1]);
      final runsData = Map<String, dynamic>.from(results[2]);
      final rawLanguages = profile['target_languages'];
      final languages = rawLanguages is List
          ? rawLanguages.map((value) => value.toString().toLowerCase()).toList()
          : <String>[
              profile['target_language']?.toString().toLowerCase() ?? 'english'
            ];
      final nodes = (exploration['items'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      final runs = (runsData['items'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      if (!mounted) return;
      setState(() {
        _languages = languages;
        _nodes = nodes;
        _runs = runs;
        _autoGenerate = profile['auto_generate_quizzes'] == true;
        _selectedNodes.removeWhere(
          (id) => !_nodes.any((node) => node['node_id']?.toString() == id),
        );
        _selectedLanguages.removeWhere((lang) => !languages.contains(lang));
        _loading = false;
        _error = null;
      });
      _syncPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _syncPolling() {
    final hasActive = _runs.any((run) {
      final status = run['status']?.toString();
      return status == 'queued' || status == 'running';
    });
    if (hasActive) {
      _hadActiveRun = true;
    }
    if (hasActive && _pollTimer == null) {
      _pollTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _load(silent: true),
      );
    } else if (!hasActive) {
      _pollTimer?.cancel();
      _pollTimer = null;
      if (_hadActiveRun) {
        _hadActiveRun = false;
        // The run is marked completed just before the exploration aggregate
        // is updated. Fetch once more after that transaction settles so the
        // node card does not remain at zero until a full page navigation.
        _settleRefreshTimer?.cancel();
        _settleRefreshTimer = Timer(
          const Duration(milliseconds: 900),
          () => _load(silent: true),
        );
      }
    }
  }

  Future<void> _setAutoGenerate(bool value) async {
    setState(() {
      _savingAuto = true;
      _autoGenerate = value;
    });
    try {
      await apiClient.updateQuizProfileSettings(autoGenerateQuizzes: value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoGenerate = !value);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('자동 생성 설정 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingAuto = false);
    }
  }

  Future<void> _generate() async {
    final combinationCount = _selectedNodes.length * _selectedLanguages.length;
    if (combinationCount == 0) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('선택한 문제 생성'),
            content: Text(
              'Statement ${_selectedNodes.length}개 × Target 언어 '
              '${_selectedLanguages.length}개 = 총 $combinationCount개 조합을 '
              '생성합니다.\n\n각 조합에서 단어 문제와 작문 문제를 함께 만들며, '
              '기존 활성 문제는 생성 이력으로 보관됩니다.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('문제 생성'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _submitting = true);
    try {
      await apiClient.createQuizGenerationRun(
        nodeIds: _selectedNodes.toList(),
        languages: _selectedLanguages.toList(),
        idempotencyKey: newIdempotencyKey('manual'),
      );
      if (!mounted) return;
      _selectedNodes.clear();
      await _load(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('생성 실행을 시작했습니다.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('생성 시작 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _retry(Map<String, dynamic> run) async {
    final id = run['id']?.toString();
    if (id == null) return;
    try {
      await apiClient.retryQuizGenerationRun(
        id,
        idempotencyKey: newIdempotencyKey('retry-$id'),
      );
      await _load(silent: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('재시도 실패: $e')),
        );
      }
    }
  }

  bool get _allNodesSelected =>
      _nodes.isNotEmpty && _selectedNodes.length == _nodes.length;

  void _toggleAllNodes() {
    setState(() {
      if (_allNodesSelected) {
        _selectedNodes.clear();
      } else {
        _selectedNodes
          ..clear()
          ..addAll(_nodes.map((node) => node['node_id'].toString()));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final combinations = _selectedNodes.length * _selectedLanguages.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('그래프 노드 탐색 현황'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: () => _load(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const AppLoadingScreen(message: 'Statement 노드 불러오는 중…')
          : _error != null
              ? Center(
                  child: AppEmptyState(
                    icon: Icons.error_outline_rounded,
                    title: '탐색 현황을 불러오지 못했습니다',
                    subtitle: _error!,
                    action: FilledButton(
                      onPressed: _load,
                      child: const Text('다시 시도'),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(child: _buildControls()),
                      SliverToBoxAdapter(child: _buildRuns()),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.pageH,
                            AppSpacing.lg,
                            AppSpacing.pageH,
                            AppSpacing.sm,
                          ),
                          child: Row(
                            children: [
                              Checkbox(
                                value: _allNodesSelected,
                                onChanged: (_) => _toggleAllNodes(),
                              ),
                              Text(_allNodesSelected ? '전체 해제' : '전체 선택'),
                              const Spacer(),
                              Text(
                                '${_selectedNodes.length}/${_nodes.length}개 선택',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_nodes.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: AppEmptyState(
                            icon: Icons.account_tree_outlined,
                            title: 'Statement 노드가 없습니다',
                            subtitle: '그래프에서 Statement를 확정한 뒤 다시 확인하세요.',
                          ),
                        )
                      else
                        SliverList.separated(
                          itemCount: _nodes.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (context, index) =>
                              _buildNodeCard(_nodes[index]),
                        ),
                      const SliverToBoxAdapter(
                        child: SizedBox(height: AppSpacing.xxl),
                      ),
                    ],
                  ),
                ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageH,
            AppSpacing.sm,
            AppSpacing.pageH,
            AppSpacing.md,
          ),
          child: FilledButton.icon(
            onPressed: combinations == 0 || _submitting ? null : _generate,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(
              _selectedLanguages.isEmpty
                  ? 'Target 언어를 선택하세요'
                  : '문제 생성 · $combinations개 조합',
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageH,
        AppSpacing.md,
        AppSpacing.pageH,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSurfaceCard(
            tint: AppColors.hubQuiz,
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Statement 자동 문제 생성'),
              subtitle: const Text(
                '새로 확정되거나 내용이 변경된 Statement를 모든 활성 Target 언어로 한 번에 분석·생성합니다.',
              ),
              value: _autoGenerate,
              onChanged: _savingAuto ? null : _setAutoGenerate,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Target 언어', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final language in _languages)
                FilterChip(
                  label: Text(_languageLabels[language] ?? language),
                  selected: _selectedLanguages.contains(language),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      _selectedLanguages.add(language);
                    } else {
                      _selectedLanguages.remove(language);
                    }
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRuns() {
    if (_runs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageH,
        AppSpacing.lg,
        AppSpacing.pageH,
        0,
      ),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('생성 실행 이력'),
        subtitle: Text('${_runs.length}개 실행 · 앱을 다시 열어도 유지됩니다'),
        children: _runs.map(_buildRunCard).toList(),
      ),
    );
  }

  Widget _buildRunCard(Map<String, dynamic> run) {
    final status = run['status']?.toString() ?? 'queued';
    final total = (run['total_count'] as num?)?.toInt() ?? 0;
    final completed = (run['completed_count'] as num?)?.toInt() ?? 0;
    final failed = (run['failed_count'] as num?)?.toInt() ?? 0;
    final active = status == 'queued' || status == 'running';
    final items = (run['items'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ExpansionTile(
        leading: active
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                failed == 0
                    ? Icons.check_circle_rounded
                    : Icons.warning_amber_rounded,
                color: failed == 0 ? Colors.green : Colors.orange,
              ),
        title: Text('$completed/$total 완료${failed > 0 ? ' · $failed 실패' : ''}'),
        subtitle: Text(run['source'] == 'auto' ? '자동 생성' : '수동 생성'),
        trailing: failed > 0 && !active
            ? TextButton(
                onPressed: () => _retry(run),
                child: const Text('실패 재시도'),
              )
            : null,
        children: items.map(_buildRunItem).toList(),
      ),
    );
  }

  Widget _buildRunItem(Map<String, dynamic> item) {
    final status = item['status']?.toString() ?? 'queued';
    final quizIds = (item['quiz_ids'] as List<dynamic>? ?? [])
        .map((value) => value.toString())
        .toList();
    final counts = item['generated_counts'] is Map
        ? Map<String, dynamic>.from(item['generated_counts'] as Map)
        : <String, dynamic>{};
    return ListTile(
      dense: true,
      leading: Icon(
        status == 'completed'
            ? Icons.check_circle_outline_rounded
            : status == 'failed'
                ? Icons.error_outline_rounded
                : status == 'running'
                    ? Icons.pending_rounded
                    : Icons.schedule_rounded,
      ),
      title: Text(
        '${item['node_name'] ?? ''} · '
        '${_languageLabels[item['language']] ?? item['language']}',
      ),
      subtitle: status == 'failed'
          ? Text(item['error']?.toString() ?? '생성 실패')
          : Text(
              '단어 문제 ${counts['cloze'] ?? 0}개 · 작문 문제 ${counts['composition'] ?? 0}개',
            ),
      trailing: quizIds.isEmpty
          ? null
          : const Icon(Icons.account_tree_outlined, size: 20),
      onTap: quizIds.isEmpty
          ? null
          : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      QuizPipelineHubScreen(initialQuizId: quizIds.first),
                ),
              ),
    );
  }

  Future<void> _resetNode(Map<String, dynamic> node) async {
    final id = node['node_id']?.toString() ?? '';
    final name = node['node_name']?.toString() ?? '이름 없는 Statement';
    if (id.isEmpty) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('노드 초기화'),
            content: Text(
              "'$name'에서 만들어진 단어/작문 퀴즈와 표현을 전부 삭제합니다.\n"
              'Statement 자체는 그대로 남고, 다음 문제 생성부터 새로 시작합니다.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('초기화'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    try {
      await apiClient.resetNodeQuizMaterial(id);
      if (!mounted) return;
      await _load(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('초기화했습니다.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('초기화 실패: $e')),
        );
      }
    }
  }

  Widget _buildNodeCard(Map<String, dynamic> node) {
    final id = node['node_id']?.toString() ?? '';
    final selected = _selectedNodes.contains(id);
    final stats = (node['language_stats'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.pageH),
      child: Card(
        color: selected
            ? Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.4)
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CheckboxListTile(
              value: selected,
              onChanged: (value) => setState(() {
                if (value == true) {
                  _selectedNodes.add(id);
                } else {
                  _selectedNodes.remove(id);
                }
              }),
              title: Text(node['node_name']?.toString() ?? '이름 없는 Statement'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if ((node['content_ko']?.toString() ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      node['content_ko'].toString(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: stats.map((stat) {
                      final counts = stat['generated_counts'] is Map
                          ? Map<String, dynamic>.from(
                              stat['generated_counts'] as Map,
                            )
                          : <String, dynamic>{};
                      final language = stat['language']?.toString() ?? '';
                      return Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '${_languageLabels[language] ?? language} · '
                          '단어 ${counts['cloze'] ?? 0}개 · 작문 ${counts['composition'] ?? 0}개',
                          style: const TextStyle(fontSize: 11),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              controlAffinity: ListTileControlAffinity.leading,
              isThreeLine: true,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
                child: TextButton.icon(
                  onPressed: () => _resetNode(node),
                  icon: const Icon(Icons.restart_alt_rounded, size: 16),
                  label: const Text('이 노드 초기화'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
