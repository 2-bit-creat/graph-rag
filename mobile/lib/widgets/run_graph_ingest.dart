import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
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
      SnackBar(content: Text(tr('ingest.done'))),
    );
  } else if (status == 'graph_failed') {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('ingest.failed'))),
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
                  tr('ingest.addToGraph'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            blocked
                ? tr('ingest.needSpeakers')
                : tr('ingest.ready'),
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
                  ? tr('ingest.running')
                  : blocked
                      ? tr('ingest.speakerNeeded')
                      : tr('ingest.build'),
            ),
          ),
        ],
      ),
    );
  }
}
