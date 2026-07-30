import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'quiz_admin_detail_screen.dart';
import 'quiz_exploration_screen.dart';
import 'quiz_pipeline_hub_screen.dart';

class QuizQueueScreen extends StatefulWidget {
  const QuizQueueScreen({super.key});

  @override
  State<QuizQueueScreen> createState() => _QuizQueueScreenState();
}

class _QuizQueueScreenState extends State<QuizQueueScreen> {
  static const _pageSize = 50;
  final _queueKinds = <String>{};
  final _types = <String>{};
  final _languages = <String>{};
  final _tracks = <String>{};
  final _selectedIds = <String>{};

  List<Map<String, dynamic>> _items = [];
  List<String> _targetLanguages = const ['english'];
  bool _includeArchived = false;
  bool _loading = true;
  bool _autoGenerate = false;
  double _reviewRatio = .5;
  int _total = 0;
  int _offset = 0;
  String _sort = 'created_desc';
  Object? _error;

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

  Future<void> _load({bool resetPage = false}) async {
    if (resetPage) _offset = 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        apiClient.listAdminQuizItems(
          queueKinds: _queueKinds,
          quizTypes: _types,
          languages: _languages,
          tracks: _tracks,
          includeArchived: _includeArchived,
          sort: _sort,
          limit: _pageSize,
          offset: _offset,
        ),
        apiClient.getQuizProfile(),
      ]);
      final list = results[0];
      final profile = results[1];
      if (!mounted) return;
      setState(() {
        _items = (list['items'] as List? ?? const [])
            .whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList();
        _total = (list['total'] as num?)?.toInt() ?? _items.length;
        _targetLanguages = (profile['target_languages'] as List? ?? const ['english'])
            .map((value) => value.toString().toLowerCase())
            .toList();
        _autoGenerate = profile['auto_generate_quizzes'] == true;
        _reviewRatio = (profile['quiz_review_ratio'] as num?)?.toDouble() ?? .5;
        _selectedIds.clear();
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _setAutoGenerate(bool value) async {
    setState(() => _autoGenerate = value);
    try {
      await apiClient.updateQuizProfileSettings(autoGenerateQuizzes: value);
    } catch (error) {
      if (!mounted) return;
      setState(() => _autoGenerate = !value);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('자동 모드 변경 실패: $error')));
    }
  }

  Future<void> _saveReviewRatio(double value) async {
    setState(() => _reviewRatio = value);
    try {
      await apiClient.updateQuizProfileSettings(quizReviewRatio: value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('복습 비율 저장 실패: $error')));
      }
    }
  }

  Future<void> _chooseFilter({
    required String title,
    required Set<String> selected,
    required Map<String, String> options,
  }) async {
    final draft = Set<String>.from(selected);
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                CheckboxListTile(
                  value: draft.isEmpty,
                  title: const Text('전체'),
                  onChanged: (_) => setSheetState(draft.clear),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final option in options.entries)
                        CheckboxListTile(
                          value: draft.contains(option.key),
                          title: Text(option.value),
                          onChanged: (checked) => setSheetState(() {
                            if (checked == true) {
                              draft.add(option.key);
                            } else {
                              draft.remove(option.key);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, draft),
                  child: const Text('적용'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null) return;
    setState(() {
      selected
        ..clear()
        ..addAll(result);
    });
    await _load(resetPage: true);
  }

  String _selectionLabel(Set<String> selected, Map<String, String> options) {
    if (selected.isEmpty) return '전체';
    if (selected.length == 1) return options[selected.first] ?? selected.first;
    return '${options[selected.first] ?? selected.first} 외 ${selected.length - 1}';
  }

  Widget _filterButton({
    required String label,
    required Set<String> selected,
    required Map<String, String> options,
    required IconData icon,
  }) {
    return ActionChip(
      avatar: Icon(icon, size: 17),
      label: Text('$label · ${_selectionLabel(selected, options)}'),
      onPressed: () => _chooseFilter(
        title: '$label 선택',
        selected: selected,
        options: options,
      ),
    );
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('선택 문제 보관'),
            content: Text('${_selectedIds.length}개 문제를 활성 큐에서 제외할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('보관'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await Future.wait(_selectedIds.map(apiClient.deleteQuizItem));
    await _load();
  }

  Future<void> _permanentlyDeleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final ids = List<String>.from(_selectedIds);
    final previewFuture = apiClient.previewQuizDeletion(ids);
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => FutureBuilder<Map<String, dynamic>>(
            future: previewFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const AlertDialog(
                  title: Text('삭제 정보 계산 중'),
                  content: Row(
                    children: [
                      SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Expanded(child: Text('연결된 음성 파일을 확인하고 있습니다…')),
                    ],
                  ),
                );
              }
              if (snapshot.hasError || snapshot.data == null) {
                return AlertDialog(
                  title: const Text('삭제 정보를 불러오지 못했습니다'),
                  content: Text('${snapshot.error ?? '잠시 후 다시 시도해 주세요.'}'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('닫기'),
                    ),
                  ],
                );
              }
              final preview = snapshot.data!;
              final deletable = preview['audio_to_delete_count'] as int? ?? 0;
              final retained = preview['audio_retained_count'] as int? ?? 0;
              return AlertDialog(
                title: const Text('선택 문제 완전 삭제'),
                content: Text(
                  '${preview['quiz_count'] ?? ids.length}개 문제를 영구 삭제할까요? 이 작업은 되돌릴 수 없습니다.\n\n'
                  '삭제될 미사용 음성: $deletable개\n'
                  '다른 문제에서 계속 쓰는 공유 음성: $retained개',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('완전 삭제'),
                  ),
                ],
              );
            },
          ),
        ) ??
        false;
    if (!confirmed) return;

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        title: Text('문제 삭제 중'),
        content: Row(
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Expanded(child: Text('문제와 더 이상 쓰이지 않는 음성을 정리하고 있습니다…')),
          ],
        ),
      ),
    );
    try {
      final cleanup = await apiClient.deleteQuizItemsPermanently(ids);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      final deletedQuizCount = cleanup['deleted_quiz_count'] as int? ?? 0;
      final audioDeleted = cleanup['audio_deleted_count'] as int? ?? 0;
      final audioRetained = cleanup['audio_retained_count'] as int? ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$deletedQuizCount개 문제를 삭제했습니다.'
            '${audioDeleted > 0 ? ' 미사용 음성 $audioDeleted개도 삭제했습니다.' : ''}'
            '${audioRetained > 0 ? ' 공유 음성 $audioRetained개는 유지했습니다.' : ''}',
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('문제 삭제에 실패했습니다: $e')),
      );
    }
  }

  String _date(dynamic raw) {
    final value = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
    return value == null ? '생성일 미상' : DateFormat('MM.dd HH:mm').format(value);
  }

  Color _queueColor(String kind) {
    if (kind == 'review') return const Color(0xFFFF9F43);
    if (kind == 'archived') return AppColors.textMuted;
    return const Color(0xFF5B67F1);
  }

  @override
  Widget build(BuildContext context) {
    const queueOptions = {'new': '새로 배울 문제', 'review': '복습 대상 문제'};
    const typeOptions = {'cloze': '단어', 'composition': '작문'};
    const trackOptions = {'daily': 'Daily', 'pinned': 'Pinned'};
    final languageOptions = {
      for (final language in _targetLanguages)
        language: _languageLabels[language] ?? language,
    };
    final allSelected = _items.isNotEmpty &&
        _items.every((item) => _selectedIds.contains(item['id'].toString()));

    return Scaffold(
      appBar: AppBar(
        title: const Text('학습 큐 관리'),
        actions: [
          IconButton(
            tooltip: '생성 이력과 trace',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const QuizPipelineHubScreen()),
            ),
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
            tooltip: '새로고침',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const QuizExplorationScreen(),
                              ),
                            );
                            await _load();
                          },
                          icon: const Icon(Icons.account_tree_outlined),
                          label: const Text('문제 생성'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SwitchListTile.adaptive(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                          title: const Text('자동 모드'),
                          subtitle: Text(_autoGenerate ? '새 Statement 자동 생성' : '수동 생성만'),
                          value: _autoGenerate,
                          onChanged: _setAutoGenerate,
                        ),
                      ),
                    ],
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      '복습 ${(_reviewRatio * 100).round()}% · 신규 ${((1 - _reviewRatio) * 100).round()}%',
                    ),
                    subtitle: const Text('학습 세션의 문제 구성 비율'),
                    children: [
                      Slider(
                        value: _reviewRatio,
                        divisions: 20,
                        label: '${(_reviewRatio * 100).round()}%',
                        onChanged: (value) => setState(() => _reviewRatio = value),
                        onChangeEnd: _saveReviewRatio,
                      ),
                    ],
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _filterButton(
                          label: '상태',
                          selected: _queueKinds,
                          options: queueOptions,
                          icon: Icons.flag_outlined,
                        ),
                        const SizedBox(width: 6),
                        _filterButton(
                          label: '언어',
                          selected: _languages,
                          options: languageOptions,
                          icon: Icons.language_rounded,
                        ),
                        const SizedBox(width: 6),
                        _filterButton(
                          label: '유형',
                          selected: _types,
                          options: typeOptions,
                          icon: Icons.quiz_outlined,
                        ),
                        const SizedBox(width: 6),
                        _filterButton(
                          label: '트랙',
                          selected: _tracks,
                          options: trackOptions,
                          icon: Icons.route_outlined,
                        ),
                        const SizedBox(width: 6),
                        FilterChip(
                          label: const Text('보관 포함'),
                          selected: _includeArchived,
                          onSelected: (value) {
                            setState(() => _includeArchived = value);
                            _load(resetPage: true);
                          },
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      DropdownButton<String>(
                        value: _sort,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 'created_desc', child: Text('최신 생성순')),
                          DropdownMenuItem(value: 'created_asc', child: Text('오래된 생성순')),
                          DropdownMenuItem(value: 'studied_desc', child: Text('최근 학습순')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _sort = value);
                          _load(resetPage: true);
                        },
                      ),
                      const Spacer(),
                      Text('총 $_total개', style: const TextStyle(color: AppColors.textMuted)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_items.isNotEmpty)
            Row(
              children: [
                Checkbox(
                  tristate: true,
                  value: allSelected
                      ? true
                      : _selectedIds.isEmpty
                          ? false
                          : null,
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selectedIds.addAll(_items.map((item) => item['id'].toString()));
                    } else {
                      _selectedIds.clear();
                    }
                  }),
                ),
                Text(allSelected ? '전체 해제' : '현재 페이지 전체 선택'),
                const Spacer(),
                if (_selectedIds.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        onPressed: _deleteSelected,
                        icon: const Icon(Icons.archive_outlined),
                        label: Text('${_selectedIds.length}개 보관'),
                      ),
                      TextButton.icon(
                        onPressed: _permanentlyDeleteSelected,
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        icon: const Icon(Icons.delete_forever_outlined),
                        label: const Text('완전 삭제'),
                      ),
                    ],
                  ),
              ],
            ),
          Expanded(
            child: _loading
                ? const AppLoadingScreen(message: '생성된 문제를 불러오는 중…')
                : _error != null
                    ? AppEmptyState(
                        icon: Icons.error_outline,
                        title: '문제 목록을 불러오지 못했습니다',
                        subtitle: '$_error',
                        action: FilledButton(onPressed: _load, child: const Text('다시 시도')),
                      )
                    : _items.isEmpty
                        ? const AppEmptyState(
                            icon: Icons.inventory_2_outlined,
                            title: '조건에 맞는 문제가 없습니다',
                            subtitle: '필터를 변경하거나 문제 생성에서 Statement를 선택해 주세요.',
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final item = _items[index];
                                final id = item['id'].toString();
                                final kind = item['queue_kind']?.toString() ?? 'new';
                                final color = _queueColor(kind);
                                final type = item['quiz_type'] == 'composition' ? '작문' : '단어';
                                final queueLabel = kind == 'review'
                                    ? '복습 대상 문제'
                                    : kind == 'archived'
                                        ? '보관됨'
                                        : '새로 배울 문제';
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () async {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => QuizAdminDetailScreen(quizId: id),
                                        ),
                                      );
                                      await _load();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Checkbox(
                                            value: _selectedIds.contains(id),
                                            onChanged: (checked) => setState(() {
                                              checked == true
                                                  ? _selectedIds.add(id)
                                                  : _selectedIds.remove(id);
                                            }),
                                          ),
                                          CircleAvatar(
                                            backgroundColor: color.withValues(alpha: .14),
                                            child: Text(
                                              'L${item['difficulty_level'] ?? 0}',
                                              style: TextStyle(fontSize: 11, color: color),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item['target_node']?.toString().trim().isNotEmpty == true
                                                      ? item['target_node'].toString()
                                                      : item['context_sentence']?.toString() ?? '이름 없는 문제',
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                                ),
                                                const SizedBox(height: 3),
                                                Text(
                                                  item['context_sentence']?.toString() ?? '',
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                Wrap(
                                                  spacing: 6,
                                                  runSpacing: 5,
                                                  children: [
                                                    _Badge(label: queueLabel, color: color),
                                                    _Badge(label: type, color: AppColors.hubQuiz),
                                                    _Badge(
                                                      label: _languageLabels[
                                                              item['language']?.toString()] ??
                                                          item['language']?.toString() ??
                                                          '영어',
                                                      color: AppColors.hubGraph,
                                                    ),
                                                    Text(
                                                      _date(item['created_at']),
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                        color: AppColors.textMuted,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          const Icon(Icons.chevron_right_rounded),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
          ),
          if (!_loading && _total > _pageSize)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  children: [
                    OutlinedButton(
                      onPressed: _offset == 0
                          ? null
                          : () {
                              _offset = (_offset - _pageSize).clamp(0, _total);
                              _load();
                            },
                      child: const Text('이전'),
                    ),
                    Expanded(
                      child: Text(
                        '${_offset + 1}–${(_offset + _items.length).clamp(0, _total)} / $_total',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _offset + _items.length >= _total
                          ? null
                          : () {
                              _offset += _pageSize;
                              _load();
                            },
                      child: const Text('다음'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: color.withValues(alpha: .28)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color),
        ),
      );
}
