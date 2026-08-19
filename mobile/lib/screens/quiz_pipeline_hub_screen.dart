import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/pipeline_step_list.dart';
import 'quiz_session_screen.dart';

const _kPageSize = 50;

/// Quiz generation history — cards that got created and node analyses that
/// rejected every candidate, interleaved by time in one list. Mirrors
/// KgDebugScreen's run-list/detail shape: a compact row per event, tap to
/// see its full step-by-step trace.
class QuizPipelineHubScreen extends StatefulWidget {
  const QuizPipelineHubScreen({
    super.key,
    this.initialQuizId,
    this.showAppBar = true,
  });

  final String? initialQuizId;

  /// False when embedded as a tab inside another Scaffold (e.g. DebugHubScreen).
  final bool showAppBar;

  @override
  State<QuizPipelineHubScreen> createState() => _QuizPipelineHubScreenState();
}

class _QuizPipelineHubScreenState extends State<QuizPipelineHubScreen> {
  List<dynamic> _events = [];
  int _total = 0;
  bool _loading = true;
  bool _loadFailed = false;
  bool _loadingMore = false;
  int _selectedIndex = 0;
  bool _showMobileDetail = false;
  Map<String, dynamic>? _trace;
  bool _traceLoading = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final data = await apiClient.listQuizGenerationHistory(limit: _kPageSize);
      final events = (data['items'] as List<dynamic>?) ?? [];
      if (!mounted) return;
      setState(() {
        _events = events;
        _total = (data['total'] as num?)?.toInt() ?? events.length;
        _loading = false;
      });
      if (widget.initialQuizId != null) {
        final index = _events.indexWhere((e) =>
            (e as Map)['kind'] == 'quiz' &&
            e['id']?.toString() == widget.initialQuizId);
        if (index >= 0) {
          setState(() => _selectedIndex = index);
        }
      }
      if (_events.isNotEmpty) await _loadTrace(_events[_selectedIndex] as Map);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _events.length >= _total) return;
    setState(() => _loadingMore = true);
    try {
      final data = await apiClient.listQuizGenerationHistory(
          limit: _kPageSize, offset: _events.length);
      if (!mounted) return;
      setState(() {
        _events = [..._events, ...(data['items'] as List<dynamic>? ?? [])];
        _total = (data['total'] as num?)?.toInt() ?? _total;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadTrace(Map event) async {
    setState(() {
      _traceLoading = true;
      _trace = null;
    });
    try {
      final id = event['id']?.toString() ?? '';
      final trace = event['kind'] == 'quiz'
          ? await apiClient.getQuizGenerationTrace(id)
          : await apiClient.getQuizMaterialAttemptTrace(id);
      if (mounted) {
        setState(() {
          _trace = trace;
          _traceLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _traceLoading = false);
    }
  }

  Future<void> _selectIndex(int index, {bool mobile = false}) async {
    setState(() {
      _selectedIndex = index;
      if (mobile) _showMobileDetail = true;
    });
    await _loadTrace(_events[index] as Map);
  }

  Future<void> _deleteSelected() async {
    final event = _events[_selectedIndex] as Map;
    final id = event['id']?.toString();
    if (id == null || event['kind'] != 'quiz') return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('문제 삭제'),
            content: const Text('이 문제를 완전히 삭제할까요?\n학습 큐에서도 제거됩니다.'),
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
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      await apiClient.deleteQuizItem(id, permanent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('문제를 삭제했습니다')));
      await _load();
      if (mounted) setState(() => _showMobileDetail = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < 720;
        if (mobile) {
          return PopScope(
            canPop: !_showMobileDetail,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && _showMobileDetail) {
                setState(() => _showMobileDetail = false);
              }
            },
            child: _showMobileDetail && _events.isNotEmpty
                ? _mobileDetail(context)
                : _eventList(context, mobile: true),
          );
        }
        final listWidth = (constraints.maxWidth * 0.32).clamp(280.0, 380.0);
        return Row(
          children: [
            SizedBox(width: listWidth, child: _eventList(context)),
            const VerticalDivider(width: 1),
            Expanded(child: _detailBody()),
          ],
        );
      },
    );
    if (!widget.showAppBar) return body;
    return Scaffold(
      appBar: const AppHubAppBar(
        title: '생성 이력',
        subtitle: '카드 생성 · 후보 거부 시도 · 시간순',
      ),
      body: body,
    );
  }

  Widget _eventList(BuildContext context, {bool mobile = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
          child: Row(
            children: [
              Text('생성 이력 ($_total)',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _load,
                tooltip: '새로고침',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _loadFailed
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('불러오지 못했습니다',
                                style: TextStyle(
                                    color: AppColors.textMuted, fontSize: 13)),
                            const SizedBox(height: AppSpacing.sm),
                            TextButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('다시 시도'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _events.isEmpty
                      ? Center(
                          child: Text('생성 이력 없음',
                              style: TextStyle(
                                  color: AppColors.textMuted, fontSize: 13)),
                        )
                      : ListView.separated(
                          itemCount: _events.length + 1,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            if (i == _events.length) {
                              if (_events.length >= _total) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.all(AppSpacing.md),
                                child: Center(
                                  child: TextButton.icon(
                                    onPressed: _loadingMore ? null : _loadMore,
                                    icon: _loadingMore
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2))
                                        : const Icon(Icons.expand_more_rounded,
                                            size: 18),
                                    label: const Text('더 보기'),
                                  ),
                                ),
                              );
                            }
                            return _eventTile(i, mobile);
                          },
                        ),
        ),
      ],
    );
  }

  Widget _eventTile(int index, bool mobile) {
    final event = _events[index] as Map;
    final ok = event['ok'] == true;
    final kind = event['kind']?.toString();
    final kindLabel = kind == 'material' ? '분석 시도' : _quizTypeLabel(event['quiz_type']?.toString());
    return ListTile(
      dense: !mobile,
      selected: _selectedIndex == index,
      selectedTileColor: AppColors.primary.withValues(alpha: 0.07),
      leading: Icon(
        ok ? Icons.check_circle_outline : Icons.error_outline,
        size: 18,
        color: ok ? AppColors.accent : Colors.redAccent,
      ),
      title: Text(
        event['title']?.toString() ?? '',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '$kindLabel · ${event['subtitle'] ?? ''} · ${_formatTs(event['timestamp']?.toString())}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: mobile ? const Icon(Icons.chevron_right_rounded) : null,
      onTap: () => _selectIndex(index, mobile: mobile),
    );
  }

  Widget _detailBody() {
    if (_events.isEmpty) {
      return Center(
        child: AppEmptyState(
          icon: Icons.route_outlined,
          title: '생성 이력 없음',
          subtitle: '문제를 생성하면 단계별 기록이 여기에 남습니다.',
        ),
      );
    }
    final event = _events[_selectedIndex] as Map;
    final trace = _trace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (event['kind'] == 'quiz')
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => QuizSessionScreen(
                          quizType: event['quiz_type']?.toString() ?? 'scramble',
                          quizIds: [event['id'].toString()],
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text('이 문제 풀기'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton.outlined(
                  tooltip: '삭제',
                  onPressed: _deleting ? null : _deleteSelected,
                  icon: _deleting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
          ),
        Expanded(
          child: _traceLoading || trace == null
              ? const AppLoadingScreen(message: '생성 단계 불러오는 중…')
              : PipelineStepList(trace: quizOnlyTrace(trace)),
        ),
      ],
    );
  }

  Widget _mobileDetail(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding:
              const EdgeInsets.fromLTRB(8, AppSpacing.sm, AppSpacing.md, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: '생성 이력',
                onPressed: () => setState(() => _showMobileDetail = false),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Text('생성 단계', style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _detailBody()),
      ],
    );
  }

  String _formatTs(String? iso) {
    if (iso == null) return '?';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return DateFormat('M/d HH:mm:ss').format(dt);
    } catch (_) {
      return iso.length >= 19 ? iso.substring(0, 19) : iso;
    }
  }

  String _quizTypeLabel(String? type) {
    switch (type) {
      case 'scramble':
        return '문장 배열';
      case 'composition':
        return '작문';
      default:
        return type ?? '문제';
    }
  }
}

/// A quiz's persisted trace may carry non-quiz phase steps (it's the same
/// PipelineTracer shape as the KG trace); keep only the quiz_path ones.
Map<String, dynamic> quizOnlyTrace(Map<String, dynamic> trace) {
  final copy = Map<String, dynamic>.from(trace);
  copy['steps'] = (trace['steps'] as List<dynamic>? ?? [])
      .where((s) => (s as Map)['phase']?.toString() == 'quiz_path')
      .toList();
  return copy;
}
