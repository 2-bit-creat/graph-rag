import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

// ─── Screen ───────────────────────────────────────────────────────────────────

class KgDebugScreen extends StatefulWidget {
  const KgDebugScreen({super.key});

  @override
  State<KgDebugScreen> createState() => _KgDebugScreenState();
}

class _KgDebugScreenState extends State<KgDebugScreen> {
  List<dynamic> _runs = [];
  bool _loading = true;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final runs = await apiClient.getKgDebugRuns();
      if (mounted) setState(() { _runs = runs; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // ── Left panel: run list ───────────────────────────────────────────
        SizedBox(
          width: 220,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
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
                    : _runs.isEmpty
                        ? Center(
                            child: Text('실행 기록 없음',
                                style: TextStyle(color: context.mutedText, fontSize: 13)),
                          )
                        : ListView.separated(
                            itemCount: _runs.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final r = _runs[i] as Map<String, dynamic>;
                              final ok = r['status'] == 'ok';
                              final ts = _formatTs(r['timestamp']?.toString());
                              final latency = r['latency_ms'];
                              final mode = r['mode'] == 'diary' ? '일기' : '외부';
                              return ListTile(
                                dense: true,
                                selected: _selectedIndex == i,
                                selectedTileColor: AppColors.primary.withValues(alpha: 0.07),
                                leading: Icon(
                                  ok ? Icons.check_circle_outline : Icons.error_outline,
                                  size: 16,
                                  color: ok ? AppColors.accent : Colors.redAccent,
                                ),
                                title: Text('$mode 모드',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                subtitle: Text('$ts · ${latency ?? '?'}ms',
                                    style: const TextStyle(fontSize: 11)),
                                onTap: () => setState(() => _selectedIndex = i),
                              );
                            },
                          ),
              ),
              const Divider(height: 1),
              // DB sandbox actions
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('DB 샌드박스', style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: context.mutedText,
                    )),
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton.icon(
                      onPressed: _confirmReset,
                      icon: const Icon(Icons.refresh, size: 16),
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
          ),
        ),
        const VerticalDivider(width: 1),
        // ── Right panel: run detail ────────────────────────────────────────
        Expanded(
          child: _runs.isEmpty
              ? Center(
                  child: AppEmptyState(
                    icon: Icons.terminal_rounded,
                    title: '실행 기록 없음',
                    subtitle: '기록 탭에서 텍스트를 추출하면 여기에 나타납니다.',
                  ),
                )
              : _RunDetail(run: _runs[_selectedIndex] as Map<String, dynamic>),
        ),
      ],
    );
  }

  String _formatTs(String? iso) {
    if (iso == null) return '?';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return DateFormat('HH:mm:ss').format(dt);
    } catch (_) { return iso.substring(0, 19); }
  }

  Future<void> _confirmReset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('그래프 초기화'),
        content: const Text('모든 노드와 엣지가 삭제됩니다. 계속하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await apiClient.clearGraph();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('그래프가 초기화되었습니다.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('초기화 실패: $e')),
        );
      }
    }
  }
}

// ─── Run detail panel ─────────────────────────────────────────────────────────

class _RunDetail extends StatelessWidget {
  const _RunDetail({required this.run});
  final Map<String, dynamic> run;

  @override
  Widget build(BuildContext context) {
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
              _MetaChip(
                icon: ok ? Icons.check_circle_outline : Icons.error_outline,
                label: ok ? '성공' : run['status']?.toString() ?? 'error',
                color: ok ? AppColors.accent : Colors.redAccent,
              ),
              _MetaChip(
                icon: Icons.access_time,
                label: '${latency ?? '?'}ms',
                color: context.mutedText,
              ),
              if (tokenIn != null)
                _MetaChip(
                  icon: Icons.input_rounded,
                  label: 'in $tokenIn tok',
                  color: context.mutedText,
                ),
              if (tokenOut != null)
                _MetaChip(
                  icon: Icons.output_rounded,
                  label: 'out $tokenOut tok',
                  color: context.mutedText,
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
                ? _JsonTree(data: parsedResponse)
                : SelectableText(
                    rawResponse,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
          ),
        ],
      ),
    );
  }

}

// ─── JSON tree viewer ─────────────────────────────────────────────────────────

class _JsonTree extends StatelessWidget {
  const _JsonTree({required this.data, this.indent = 0});
  final dynamic data;
  final int indent;

  @override
  Widget build(BuildContext context) {
    if (data is Map<String, dynamic>) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: (data as Map<String, dynamic>).entries.map((e) {
          return Padding(
            padding: EdgeInsets.only(left: indent * 12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '▸ ${e.key}:',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                _JsonTree(data: e.value, indent: indent + 1),
              ],
            ),
          );
        }).toList(),
      );
    } else if (data is List) {
      final list = data as List;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: list.asMap().entries.map((e) {
          return Padding(
            padding: EdgeInsets.only(left: indent * 12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('[${e.key}] ', style: TextStyle(fontSize: 11, color: context.mutedText)),
                Expanded(child: _JsonTree(data: e.value, indent: 0)),
              ],
            ),
          );
        }).toList(),
      );
    } else {
      return Padding(
        padding: EdgeInsets.only(left: indent * 12.0, bottom: 2),
        child: SelectableText(
          data?.toString() ?? 'null',
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        ),
      );
    }
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
