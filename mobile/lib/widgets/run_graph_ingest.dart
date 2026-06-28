import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';

/// Trigger semantic-chunk graph ingest and poll until processing finishes.
Future<String?> runGraphIngestForEntry({
  required String entryId,
  required Future<void> Function({bool silent}) onRefresh,
  bool force = false,
}) async {
  await apiClient.buildGraph(entryId, force: force);
  for (var i = 0; i < 90; i++) {
    await onRefresh(silent: true);
    final fresh = await apiClient.getEntry(entryId);
    final status = fresh['status']?.toString() ?? '';
    if (status != 'graph_processing') return status;
    await Future.delayed(const Duration(seconds: 2));
  }
  final fresh = await apiClient.getEntry(entryId);
  return fresh['status']?.toString();
}

Future<void> showGraphIngestSnackBar(BuildContext context, String? status) {
  final messenger = ScaffoldMessenger.of(context);
  if (status == 'graph_ready') {
    messenger.showSnackBar(
      const SnackBar(content: Text('지식 그래프 생성 완료 (화자 · Statement · Concept)')),
    );
  } else if (status == 'graph_failed') {
    messenger.showSnackBar(
      const SnackBar(content: Text('지식 그래프 생성 실패 — 파이프라인 로그를 확인하세요')),
    );
  }
  return Future.value();
}

/// User-facing banner to manually add entry content to the knowledge graph.
class GraphManualAddBanner extends StatelessWidget {
  const GraphManualAddBanner({
    super.key,
    required this.onAdd,
    this.loading = false,
    this.speakersPending = false,
  });

  final VoidCallback onAdd;
  final bool loading;

  /// When true, speaker confirmation is still required — the generate button
  /// is disabled and a guidance message is shown instead.
  final bool speakersPending;

  @override
  Widget build(BuildContext context) {
    final blocked = speakersPending;
    return AppSurfaceCard(
      tint: AppColors.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.hub_outlined, color: AppColors.accent),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '지식 그래프에 추가',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            blocked
                ? '위 화자별 스크립트에서 화자를 먼저 확인해야 지식 그래프를 생성할 수 있습니다.'
                : '번역·화자 확인이 끝났다면 화자 · Statement · Concept 노드를 생성합니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: blocked ? AppColors.accentWarm : null,
                ),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: (loading || blocked) ? null : onAdd,
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(blocked ? Icons.lock_outline : Icons.play_arrow),
            label: Text(
              loading
                  ? '생성 중…'
                  : blocked
                      ? '화자 확인 필요'
                      : '지식 그래프 생성',
            ),
          ),
        ],
      ),
    );
  }
}
