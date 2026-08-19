import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/pipeline_step_list.dart';

// ─── Screen ───────────────────────────────────────────────────────────────────

class KgDebugScreen extends StatefulWidget {
  const KgDebugScreen({super.key});

  @override
  State<KgDebugScreen> createState() => _KgDebugScreenState();
}

class _KgDebugScreenState extends State<KgDebugScreen> {
  List<dynamic> _runs = [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _resetting = false;
  int _selectedIndex = 0;
  bool _showMobileDetail = false;

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
      final runs = await apiClient.getKgDebugRuns();
      if (mounted) {
        setState(() {
          _runs = runs;
          if (_runs.isEmpty) {
            _selectedIndex = 0;
            _showMobileDetail = false;
          } else if (_selectedIndex >= _runs.length) {
            _selectedIndex = 0;
            _showMobileDetail = false;
          }
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
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
            child: _showMobileDetail && _runs.isNotEmpty
                ? _mobileDetail(context)
                : _runList(context, mobile: true),
          );
        }
        final listWidth = (constraints.maxWidth * 0.30).clamp(260.0, 360.0);
        return Row(
          children: [
            SizedBox(width: listWidth, child: _runList(context)),
            const VerticalDivider(width: 1),
            Expanded(child: _detailBody()),
          ],
        );
      },
    );
  }

  Widget _runList(BuildContext context, {bool mobile = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
          child: Row(
            children: [
              Text('최근 실행', style: Theme.of(context).textTheme.titleSmall),
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
                  : _runs.isEmpty
                      ? Center(
                          child: Text('실행 기록 없음',
                              style: TextStyle(
                                  color: AppColors.textMuted, fontSize: 13)),
                        )
                      : ListView.separated(
                          itemCount: _runs.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) => _runTile(i, mobile),
                        ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('DB 샌드박스',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: AppColors.textMuted,
                      )),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _resetting ? null : _confirmReset,
                icon: _resetting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 16),
                label: const Text('그래프 초기화', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent, width: 0.8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _runTile(int index, bool mobile) {
    final run = _runs[index] as Map<String, dynamic>;
    final ok = run['status'] == 'ok' || run['status'] == 'completed';
    final mode = run['kind'] == 'journal_pipeline'
        ? '저장된 KG 파이프라인'
        : run['mode'] == 'diary'
            ? '일기 추출'
            : '외부 텍스트 추출';
    return ListTile(
      dense: !mobile,
      selected: _selectedIndex == index,
      selectedTileColor: AppColors.primary.withValues(alpha: 0.07),
      leading: Icon(
        ok ? Icons.check_circle_outline : Icons.error_outline,
        size: 18,
        color: ok ? AppColors.accent : Colors.redAccent,
      ),
      title: Text('$mode 모드',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${_formatTs(run['timestamp']?.toString())} · ${run['latency_ms'] ?? '?'}ms',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: mobile ? const Icon(Icons.chevron_right_rounded) : null,
      onTap: () => setState(() {
        _selectedIndex = index;
        if (mobile) _showMobileDetail = true;
      }),
    );
  }

  Widget _detailBody() {
    if (_loadFailed) {
      return Center(
        child: AppEmptyState(
          icon: Icons.error_outline_rounded,
          title: '불러오지 못했습니다',
          action: FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('다시 시도'),
          ),
        ),
      );
    }
    if (_runs.isEmpty) {
      return Center(
        child: AppEmptyState(
          icon: Icons.terminal_rounded,
          title: '실행 기록 없음',
          subtitle: '일기를 저장하거나 그래프를 생성하면 단계별 기록이 여기에 남습니다.',
        ),
      );
    }
    return _RunDetail(run: _runs[_selectedIndex] as Map<String, dynamic>);
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
                tooltip: '최근 실행 목록',
                onPressed: () => setState(() => _showMobileDetail = false),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Text('실행 상세', style: Theme.of(context).textTheme.titleSmall),
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
      // Includes the date: HH:mm:ss-only made a correctly time-sorted list
      // look shuffled once it crossed midnight.
      return DateFormat('M/d HH:mm:ss').format(dt);
    } catch (_) {
      return iso.substring(0, 19);
    }
  }

  Future<void> _confirmReset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('그래프 초기화'),
        content: const Text('모든 노드와 엣지가 삭제됩니다. 계속하시겠습니까?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      await apiClient.clearGraph();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('그래프가 초기화되었습니다.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('초기화에 실패했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }
}

// ─── Run detail panel ─────────────────────────────────────────────────────────

class _RunDetail extends StatelessWidget {
  const _RunDetail({required this.run});
  final Map<String, dynamic> run;

  @override
  Widget build(BuildContext context) {
    final trace = run['trace'];
    if (trace is Map) {
      return PipelineStepList(trace: Map<String, dynamic>.from(trace));
    }
    final ok = run['status'] == 'ok';
    final tokenIn = run['token_in'];
    final tokenOut = run['token_out'];
    final latency = run['latency_ms'];
    final rawResponse = run['raw_response']?.toString() ?? '';

    Map<String, dynamic>? parsedResponse;
    try {
      final decoded = jsonDecode(rawResponse);
      if (decoded is Map<String, dynamic>) parsedResponse = decoded;
    } catch (_) {}

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Meta row
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.sm,
            children: [
              PipelineMetaChip(
                icon: ok ? Icons.check_circle_outline : Icons.error_outline,
                label: ok ? '성공' : run['status']?.toString() ?? 'error',
                color: ok ? AppColors.accent : Colors.redAccent,
              ),
              PipelineMetaChip(
                icon: Icons.access_time,
                label: '${latency ?? '?'}ms',
                color: AppColors.textMuted,
              ),
              if (tokenIn != null)
                PipelineMetaChip(
                  icon: Icons.input_rounded,
                  label: 'in $tokenIn tok',
                  color: AppColors.textMuted,
                ),
              if (tokenOut != null)
                PipelineMetaChip(
                  icon: Icons.output_rounded,
                  label: 'out $tokenOut tok',
                  color: AppColors.textMuted,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // System prompt
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('System Prompt',
                style: Theme.of(context).textTheme.titleSmall),
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: SelectableText(
                  run['system_prompt']?.toString() ?? '',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),

          // User prompt
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('User Prompt',
                style: Theme.of(context).textTheme.titleSmall),
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: SelectableText(
                  run['user_prompt']?.toString() ?? '',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),

          // Raw response
          const SizedBox(height: AppSpacing.sm),
          Text('Raw Response', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          AppSurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: parsedResponse != null
                ? JsonTree(data: parsedResponse)
                : SelectableText(
                    rawResponse,
                    style:
                        const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
          ),
        ],
      ),
    );
  }
}

// PipelineStepList (widgets/pipeline_step_list.dart) renders the persisted
// journal/KG trace — shared with the quiz generation history tab, since both
// are the same PipelineTracer step shape.
