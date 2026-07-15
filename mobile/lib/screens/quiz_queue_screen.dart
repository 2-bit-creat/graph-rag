import 'package:flutter/material.dart';

import '../api/client.dart';
import 'quiz_session_screen.dart';

class QuizQueueScreen extends StatefulWidget {
  const QuizQueueScreen({super.key});

  @override
  State<QuizQueueScreen> createState() => _QuizQueueScreenState();
}

class _QuizQueueScreenState extends State<QuizQueueScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  String? _typeFilter;
  String? _languageFilter;
  bool _languageFilterInitialized = false;
  String _track = 'daily';
  bool _loading = true;
  bool _refilling = false;
  String? _error;
  List<dynamic> _items = [];
  final Set<String> _selectedIds = <String>{};
  int _total = 0;
  Map<String, dynamic>? _profile;

  static const _typeChips = [
    (null, '전체'),
    ('cloze', '단어완성'),
    ('composition', '작문'),
  ];

  static const _languageLabels = <String, String>{
    'english': '영어',
    'german': '독일어',
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
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      setState(() {});
      _load();
    });
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String get _queueKind => _tabController.index == 0 ? 'new' : 'review';

  List<String> get _targetLanguages {
    final p = _profile;
    final raw = p?['target_languages'];
    if (raw is List) {
      return raw.map((value) => value.toString().toLowerCase()).toList();
    }
    return const ['english'];
  }

  Map<String, int> get _dailyGoalSummary {
    final p = _profile;
    if (p == null) {
      return const {
        'clozeDone': 0,
        'clozeTarget': 0,
        'compositionDone': 0,
        'compositionTarget': 0
      };
    }
    final languages =
        _languageFilter == null ? _targetLanguages : [_languageFilter!];
    final rows = p['daily_progress_by_language'];
    final clozeTargetPerLanguage =
        (p['daily_cloze_target'] as num?)?.toInt() ?? 0;
    final compositionTargetPerLanguage =
        (p['daily_composition_target'] as num?)?.toInt() ?? 0;
    var clozeDone = 0;
    var compositionDone = 0;
    for (final language in languages) {
      final row = rows is Map ? rows[language] : null;
      if (row is Map) {
        clozeDone += (row['cloze_completed'] as num?)?.toInt() ?? 0;
        compositionDone += (row['composition_completed'] as num?)?.toInt() ?? 0;
      }
    }
    return {
      'clozeDone': clozeDone,
      'clozeTarget': clozeTargetPerLanguage * languages.length,
      'compositionDone': compositionDone,
      'compositionTarget': compositionTargetPerLanguage * languages.length,
    };
  }

  double get _dailyProgress {
    final summary = _dailyGoalSummary;
    final target = summary['clozeTarget']! + summary['compositionTarget']!;
    if (target <= 0) return 0;
    final completed = summary['clozeDone']!.clamp(0, summary['clozeTarget']!) +
        summary['compositionDone']!.clamp(0, summary['compositionTarget']!);
    return completed / target;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        apiClient.listQuizQueueItems(
          queueKind: _queueKind,
          quizType: _typeFilter,
          track: _track,
          limit: 200,
        ),
        apiClient.getQuizProfile(),
      ]);
      final data = results[0];
      final profile = results[1];
      if (mounted) {
        setState(() {
          if (!_languageFilterInitialized) {
            _languageFilter =
                profile['target_language']?.toString().toLowerCase();
            _languageFilterInitialized = true;
          }
          _items = ((data['items'] as List<dynamic>?) ?? []).where((item) {
            final type = (item as Map)['quiz_type']?.toString();
            final language = item['language']?.toString().toLowerCase();
            return (type == 'cloze' || type == 'composition') &&
                (_languageFilter == null || language == _languageFilter);
          }).toList();
          _selectedIds.clear();
          _total = _items.length;
          _profile = profile;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<bool> _confirmDelete(String quizId) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('큐에서 제거'),
            content: const Text('이 문제를 학습 큐에서 삭제할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deleteItem(String quizId) async {
    try {
      await apiClient.deleteQuizItem(quizId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('큐에서 제거했습니다')),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('삭제 실패: $e')),
        );
      }
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'cloze':
        return '단어완성';
      case 'composition':
        return '작문';
      default:
        return type;
    }
  }

  String _reviewLabel(String? iso) {
    if (iso == null || iso.isEmpty) return '복습 예정 없음';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final now = DateTime.now().toUtc();
    final diff = dt.difference(now);
    if (diff.isNegative) return '복습 가능';
    if (diff.inHours < 24) return '${diff.inHours}시간 후 복습';
    return '${diff.inDays}일 후 복습';
  }

  Future<void> _refillQueue() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('부족한 문제 채우기'),
            content: const Text(
              '부족한 퀴즈 유형만 지식그래프에서 탐색해 생성합니다. '
              '새로운 소스가 없거나 이미 탐색한 소스라면 추가 API 호출 없이 종료됩니다.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('생성'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _refilling = true);
    try {
      final result = await apiClient.refillQuizzes();
      if (!mounted) return;

      if (result['status'] == 'scheduled') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('문제 생성을 시작했습니다. 잠시 후 새로고침하면 결과가 표시됩니다.'),
          ),
        );
        return;
      }

      await _load();
      final batches = result['batches'];
      var generatedCloze = 0;
      if (batches is Map) {
        for (final value in batches.values) {
          if (value is Map) {
            generatedCloze += (value['cloze'] as num?)?.toInt() ?? 0;
          }
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            generatedCloze > 0
                ? '단어 문제 $generatedCloze개를 생성했습니다.'
                : '새 단어 문제를 만들 수 있는 미탐색 표현이 없습니다. 복습 문제를 이용해 보세요.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('문제 생성 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refilling = false);
    }
  }

  bool get _allSelected =>
      _items.isNotEmpty &&
      _items.every(
          (item) => _selectedIds.contains((item as Map)['id']?.toString()));

  void _toggleSelectAll(bool selected) {
    setState(() {
      if (selected) {
        _selectedIds
          ..clear()
          ..addAll(_items
              .map((item) => (item as Map)['id']?.toString() ?? '')
              .where((id) => id.isNotEmpty));
      } else {
        _selectedIds.clear();
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('선택한 문제 삭제'),
            content: Text('${ids.length}개 문제를 큐에서 제거할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    setState(() => _loading = true);
    try {
      await Future.wait(ids.map(apiClient.deleteQuizItem));
      if (!mounted) return;
      _selectedIds.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${ids.length}개 문제를 큐에서 제거했습니다')),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('일괄 삭제 실패: $e')),
        );
      }
    }
  }

  Future<void> _resetAllQueue() async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('퀴즈 큐 전체 초기화'),
            content: const Text(
              '모든 언어의 신규·복습 단어/작문 문제를 비우고, 보이지 않는 소스 탐색 이력도 초기화합니다. 계속할까요?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('전체 초기화'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    setState(() => _loading = true);
    try {
      final result = await apiClient.resetQuizQueue();
      if (!mounted) return;
      _selectedIds.clear();
      final archived = (result['archived'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$archived개 문제와 탐색 이력을 초기화했습니다')),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('전체 초기화 실패: $e')),
        );
      }
    }
  }

  Future<void> _showExplorationSheet() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (context, controller) => FutureBuilder<Map<String, dynamic>>(
          // This is a graph-wide audit view, so do not inherit the queue's
          // current language filter. The API returns one row per target language.
          future: apiClient.listQuizExplorations(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('탐색 이력을 불러오지 못했어요: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!;
            final items = (data['items'] as List<dynamic>? ?? []);
            final explored = (data['explored_count'] as num?)?.toInt() ?? 0;
            final partial = (data['partial_count'] as num?)?.toInt() ?? 0;
            final unexplored = (data['unexplored_count'] as num?)?.toInt() ?? 0;
            return SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.account_tree_outlined),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('그래프 노드 탐색 현황',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700)),
                        ),
                        IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _explorationCountChip(
                            '탐색 완료', explored, const Color(0xFF22C55E)),
                        if (partial > 0) ...[
                          _explorationCountChip(
                              '일부 완료', partial, const Color(0xFFF59E0B)),
                        ],
                        _explorationCountChip(
                            '미탐색', unexplored, const Color(0xFF64748B)),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: items.isEmpty
                        ? const Center(
                            child: Text('퀴즈에 사용할 Statement 노드가 아직 없습니다.'))
                        : ListView.separated(
                            controller: controller,
                            itemCount: items.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final node = Map<String, dynamic>.from(
                                  items[index] as Map);
                              final status =
                                  node['status']?.toString() ?? 'unexplored';
                              final done = status == 'explored';
                              final partiallyDone = status == 'partial';
                              final statusColor = done
                                  ? const Color(0xFF22C55E)
                                  : partiallyDone
                                      ? const Color(0xFFF59E0B)
                                      : const Color(0xFF64748B);
                              final languageStats =
                                  (node['language_stats'] as List<dynamic>? ??
                                          [])
                                      .whereType<Map>()
                                      .map(Map<String, dynamic>.from)
                                      .toList();
                              return ListTile(
                                leading: Icon(
                                    done
                                        ? Icons.check_circle_rounded
                                        : partiallyDone
                                            ? Icons.timelapse_rounded
                                            : Icons
                                                .radio_button_unchecked_rounded,
                                    color: statusColor),
                                title: Text(node['node_name']?.toString() ??
                                    '이름 없는 노드'),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if ((node['content_ko']?.toString() ?? '')
                                        .isNotEmpty)
                                      Text(node['content_ko'].toString(),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis),
                                    const SizedBox(height: 8),
                                    if (languageStats.isEmpty)
                                      Text('언어별 탐색 정보가 없습니다',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade600))
                                    else
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: languageStats
                                            .map(_explorationLanguageChip)
                                            .toList(),
                                      ),
                                  ],
                                ),
                                isThreeLine: true,
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Per-language generation audit.  Do not collapse types into one total: a
  /// source can have exhausted word-cloze generation while still needing a
  /// composition card (and vice versa).
  Widget _explorationLanguageChip(Map<String, dynamic> stat) {
    final language = stat['language']?.toString().toLowerCase() ?? '';
    final label = _languageLabels[language] ?? language;
    final explored = stat['status'] == 'explored';
    final generated = stat['generated_counts'] is Map
        ? Map<String, dynamic>.from(stat['generated_counts'] as Map)
        : const <String, dynamic>{};
    // Compatibility with API responses from before generated_counts was added.
    final cloze = (generated['cloze'] as num?)?.toInt() ??
        (stat['word_count'] as num?)?.toInt() ??
        0;
    final composition = (generated['composition'] as num?)?.toInt() ??
        (stat['composition_count'] as num?)?.toInt() ??
        0;
    final expressions = (stat['expression_count'] as num?)?.toInt() ?? 0;
    final color = explored ? const Color(0xFF22C55E) : const Color(0xFF64748B);

    return Container(
      width: 196,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label · ${explored ? '탐색 완료' : '미탐색'}',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 7),
          _generatedQuizTypeRow('단어 빈칸', cloze),
          const SizedBox(height: 3),
          _generatedQuizTypeRow('작문', composition),
          if (expressions > 0) ...[
            const SizedBox(height: 6),
            Text(
              '추출 표현 $expressions개',
              style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _generatedQuizTypeRow(String type, int count) => Row(
        children: [
          Expanded(child: Text(type, style: const TextStyle(fontSize: 11.5))),
          Text(
            '$count문제',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
          ),
        ],
      );

  Widget _legacyExplorationLanguageChip(Map<String, dynamic> stat) {
    final language = stat['language']?.toString().toLowerCase() ?? '';
    final label = _languageLabels[language] ?? language;
    final explored = stat['status'] == 'explored';
    final composition = (stat['composition_count'] as num?)?.toInt() ?? 0;
    final expressions = (stat['expression_count'] as num?)?.toInt() ?? 0;
    final words = (stat['word_count'] as num?)?.toInt() ?? 0;
    final color = explored ? const Color(0xFF22C55E) : const Color(0xFF64748B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label · 작문 $composition · 추출 표현 $expressions · 단어 퀴즈 $words',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _explorationCountChip(String label, int count, Color color) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20)),
        child: Text('$label $count',
            style: TextStyle(color: color, fontWeight: FontWeight.w700)),
      );

  String _batchMeta(Map<String, dynamic> item) {
    final batch = item['quiz_data'] is Map
        ? Map<String, dynamic>.from(item['quiz_data'] as Map)
        : <String, dynamic>{};
    final meta = batch['_batch'] is Map
        ? Map<String, dynamic>.from(batch['_batch'] as Map)
        : <String, dynamic>{};
    final created =
        DateTime.tryParse(item['created_at']?.toString() ?? '')?.toLocal();
    final date = meta['date']?.toString() ?? created?.toIso8601String();
    final dt = DateTime.tryParse(date ?? '')?.toLocal();
    final time = dt == null
        ? '생성 시각 알 수 없음'
        : '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} 생성';
    final sequence = meta['sequence']?.toString();
    final source = item['source_kind']?.toString();
    final sourceLabel = source == 'review'
        ? '복습'
        : source == 'exploration'
            ? '랜덤 탐험'
            : source == 'pin'
                ? '핀'
                : null;
    final batchLabel = sequence == null ? '' : '배치 #$sequence · ';
    return '$batchLabel$time${sourceLabel == null ? '' : ' · $sourceLabel'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 학습 큐 관리'),
        actions: [
          IconButton(
            tooltip: '노드 탐색 현황',
            onPressed: _showExplorationSheet,
            icon: const Icon(Icons.account_tree_outlined),
          ),
          if (_track == 'daily')
            TextButton.icon(
              onPressed: _refilling ? null : _refillQueue,
              icon: _refilling
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              label: const Text('문제 채우기'),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '새로 배울 문제 (NEW)'),
            Tab(text: '복습 대기 중 (REVIEW)'),
          ],
        ),
      ),
      body: AnimatedBuilder(
        animation: _tabController,
        builder: (context, _) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('오늘의 세트'),
                    selected: _track == 'daily',
                    onSelected: (_) {
                      setState(() => _track = 'daily');
                      _load();
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('📌 최우선 과제'),
                    selected: _track == 'pinned',
                    onSelected: (_) {
                      setState(() => _track = 'pinned');
                      _load();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  if (_items.isNotEmpty) ...[
                    Checkbox(
                      value: _allSelected
                          ? true
                          : (_selectedIds.isNotEmpty ? null : false),
                      tristate: true,
                      onChanged: (value) => _toggleSelectAll(value == true),
                    ),
                    Text(_allSelected ? '전체 해제' : '전체선택'),
                  ],
                  if (_selectedIds.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text('${_selectedIds.length}개 선택',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    OutlinedButton.icon(
                      onPressed: _deleteSelected,
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('선택 삭제'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: Colors.red.shade700,
                      ),
                    ),
                  ],
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _loading ? null : _resetAllQueue,
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: const Text('큐 전체 초기화'),
                  ),
                ],
              ),
            ),
            if (_track == 'daily')
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('오늘의 세트 진행률'),
                        Text(
                            '${(_dailyProgress * 100).round()}% · 단어 ${_dailyGoalSummary['clozeDone']}/${_dailyGoalSummary['clozeTarget']} · 작문 ${_dailyGoalSummary['compositionDone']}/${_dailyGoalSummary['compositionTarget']}'),
                      ],
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: LinearProgressIndicator(
                        value: _dailyProgress, minHeight: 6),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 2, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                          '오늘 실제로 푼 신규 문제 기준입니다. 문제 채우기를 누르면 부족한 유형만 생성합니다.'),
                    ),
                  ),
                ],
              ),
            if (_track == 'pinned')
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 6, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('핀 문제는 오늘의 세트와 별도로 즉시 생성됩니다.'),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('전체 언어'),
                      selected: _languageFilter == null,
                      onSelected: (_) {
                        setState(() => _languageFilter = null);
                        _load();
                      },
                    ),
                    const SizedBox(width: 6),
                    for (final language in _targetLanguages)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(_languageLabels[language] ?? language),
                          selected: _languageFilter == language,
                          onSelected: (_) {
                            setState(() => _languageFilter = language);
                            _load();
                          },
                        ),
                      ),
                    const SizedBox(width: 4),
                    for (final chip in _typeChips.where(
                      (chip) =>
                          chip.$1 == null ||
                          chip.$1 == 'cloze' ||
                          chip.$1 == 'composition',
                    ))
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(chip.$2),
                          selected: _typeFilter == chip.$1,
                          onSelected: (_) {
                            setState(() => _typeFilter = chip.$1);
                            _load();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_total > 0)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('$_total개',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text('불러오기 실패: $_error'))
                      : _items.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text('큐가 비어 있습니다 — 저널에서 퀴즈를 생성해 보세요'),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView.builder(
                                padding: const EdgeInsets.all(12),
                                itemCount: _items.length,
                                itemBuilder: (context, index) {
                                  final item =
                                      _items[index] as Map<String, dynamic>;
                                  final id = item['id']?.toString() ?? '';
                                  final lv = (item['difficulty_level'] as num?)
                                          ?.toInt() ??
                                      0;
                                  final target =
                                      item['target_node']?.toString() ?? '';
                                  final contextSentence =
                                      item['context_sentence']?.toString() ??
                                          '';
                                  final quizType =
                                      item['quiz_type']?.toString() ?? '';
                                  final sourceLabel =
                                      item['source_label']?.toString() ?? '';
                                  final streak =
                                      (item['streak'] as num?)?.toInt() ?? 0;
                                  final nextReview =
                                      item['next_review_at']?.toString();
                                  final reviewReason =
                                      item['review_reason']?.toString();
                                  final reviewPriority =
                                      (item['review_priority'] as num?)
                                          ?.toInt();
                                  final selected = _selectedIds.contains(id);

                                  return Dismissible(
                                    key: ValueKey(id),
                                    direction: DismissDirection.endToStart,
                                    background: Container(
                                      alignment: Alignment.centerRight,
                                      padding: const EdgeInsets.only(right: 20),
                                      color: Colors.red.shade400,
                                      child: const Icon(Icons.delete,
                                          color: Colors.white),
                                    ),
                                    confirmDismiss: (_) => _confirmDelete(id),
                                    onDismissed: (_) => _deleteItem(id),
                                    child: Card(
                                      child: ListTile(
                                        onTap: () async {
                                          await Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => QuizSessionScreen(
                                                quizType: quizType,
                                                quizIds: [id],
                                              ),
                                            ),
                                          );
                                          if (mounted) _load();
                                        },
                                        leading: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Checkbox(
                                              value: selected,
                                              onChanged: (value) {
                                                setState(() {
                                                  if (value == true) {
                                                    _selectedIds.add(id);
                                                  } else {
                                                    _selectedIds.remove(id);
                                                  }
                                                });
                                              },
                                            ),
                                            CircleAvatar(
                                              child: Text('Lv$lv',
                                                  style: const TextStyle(
                                                      fontSize: 10)),
                                            ),
                                          ],
                                        ),
                                        title: Text(
                                          target.isNotEmpty
                                              ? target
                                              : '(대상 없음)',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _batchMeta(item),
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              contextSentence,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 4),
                                            Wrap(
                                              spacing: 6,
                                              children: [
                                                Chip(
                                                  label: Text(
                                                      _typeLabel(quizType),
                                                      style: const TextStyle(
                                                          fontSize: 10)),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                ),
                                                if (sourceLabel.isNotEmpty)
                                                  Chip(
                                                    label: Text(sourceLabel,
                                                        style: const TextStyle(
                                                            fontSize: 10)),
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    padding: EdgeInsets.zero,
                                                    backgroundColor: Theme.of(
                                                            context)
                                                        .colorScheme
                                                        .surfaceContainerHighest,
                                                  ),
                                                if (_queueKind == 'review') ...[
                                                  if (reviewReason != null &&
                                                      reviewReason.isNotEmpty)
                                                    Container(
                                                      margin:
                                                          const EdgeInsets.only(
                                                              bottom: 4),
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 8,
                                                          vertical: 5),
                                                      decoration: BoxDecoration(
                                                        color: (reviewPriority ==
                                                                    1
                                                                ? Colors.orange
                                                                : Theme.of(
                                                                        context)
                                                                    .colorScheme
                                                                    .primary)
                                                            .withValues(
                                                                alpha: 0.10),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(8),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Icon(
                                                              reviewPriority ==
                                                                      1
                                                                  ? Icons
                                                                      .priority_high_rounded
                                                                  : Icons
                                                                      .sort_rounded,
                                                              size: 14,
                                                              color: reviewPriority ==
                                                                      1
                                                                  ? Colors
                                                                      .orange
                                                                      .shade800
                                                                  : Theme.of(
                                                                          context)
                                                                      .colorScheme
                                                                      .primary),
                                                          const SizedBox(
                                                              width: 4),
                                                          Flexible(
                                                              child: Text(
                                                                  reviewReason,
                                                                  style: const TextStyle(
                                                                      fontSize:
                                                                          11,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600))),
                                                        ],
                                                      ),
                                                    ),
                                                  Text(
                                                    _reviewLabel(nextReview),
                                                    style: TextStyle(
                                                        fontSize: 10,
                                                        color:
                                                            Colors.grey[600]),
                                                  ),
                                                  if (streak > 0)
                                                    Text(
                                                      '스트릭 $streak회',
                                                      style: TextStyle(
                                                          fontSize: 10,
                                                          color:
                                                              Colors.grey[600]),
                                                    ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                        trailing: IconButton(
                                          icon:
                                              const Icon(Icons.delete_outline),
                                          onPressed: () async {
                                            if (await _confirmDelete(id)) {
                                              await _deleteItem(id);
                                            }
                                          },
                                        ),
                                        isThreeLine: true,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
