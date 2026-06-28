import 'package:flutter/material.dart';

import '../screens/knowledge_graph_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/run_graph_ingest.dart';
import '../widgets/translation_entry_panel.dart';

/// 사용자용 일기 상세 — 번역·화자 확인 (파이프라인 trace 없음).
class JournalUserDetailPanel extends StatefulWidget {
  const JournalUserDetailPanel({
    super.key,
    required this.entryId,
    required this.entry,
    required this.onRefresh,
  });

  final String entryId;
  final Map<String, dynamic> entry;
  final Future<void> Function({bool silent}) onRefresh;

  @override
  State<JournalUserDetailPanel> createState() => _JournalUserDetailPanelState();
}

class _JournalUserDetailPanelState extends State<JournalUserDetailPanel> {
  bool _manualLoading = false;

  bool get _isText => widget.entry['entry_source']?.toString() == 'precision_text';

  bool get _hasGraph {
    final graphStatus = widget.entry['graph_status']?.toString() ?? '';
    final status = widget.entry['status']?.toString() ?? '';
    return graphStatus == 'graph_ready' || status == 'graph_ready';
  }

  void _openKnowledgeGraph() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const KnowledgeGraphScreen()),
    );
  }

  bool get _canManualGraphAdd {
    final status = widget.entry['status']?.toString() ?? '';
    if (!{'ready', 'ready_no_graph'}.contains(status)) return false;
    final hasTranslation = (widget.entry['translation_en']?.toString() ?? '').trim().isNotEmpty;
    final hasSegments = (widget.entry['transcript_segments'] as List?)?.isNotEmpty == true;
    return hasTranslation || hasSegments;
  }

  /// True when any speaker still needs human confirmation. Graph generation is
  /// gated until every speaker is confirmed ('나' is auto-confirmed server-side).
  bool get _speakersPending {
    final summaries = widget.entry['speaker_summaries'] as List<dynamic>? ?? [];
    for (final raw in summaries) {
      if (raw is! Map) continue;
      if (raw['needs_confirmation'] == true) return true;
    }
    return false;
  }

  Future<void> _openManualGraphAdd() async {
    setState(() => _manualLoading = true);
    try {
      final status = await runGraphIngestForEntry(
        entryId: widget.entryId,
        onRefresh: widget.onRefresh,
      );
      if (!mounted) return;
      await showGraphIngestSnackBar(context, status);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _manualLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => widget.onRefresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageH,
          AppSpacing.md,
          AppSpacing.pageH,
          AppSpacing.xxl,
        ),
        children: [
          if (_isText)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: AppSurfaceCard(
                tint: AppColors.accent,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.edit_note_rounded, color: AppColors.accent, size: 20),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '직접 입력한 일기',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_hasGraph) ...[
            _GraphViewBanner(onTap: _openKnowledgeGraph),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_canManualGraphAdd) ...[
            GraphManualAddBanner(
              onAdd: _openManualGraphAdd,
              loading: _manualLoading,
              speakersPending: _speakersPending,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          TranslationEntryPanel(
            entry: widget.entry,
            entryId: widget.entryId,
            onRefresh: widget.onRefresh,
            showProgress: true,
            isPrecisionText: _isText,
          ),
        ],
      ),
    );
  }
}

class _GraphViewBanner extends StatelessWidget {
  const _GraphViewBanner({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      tint: AppColors.hubGraph,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Row(
          children: [
            const Icon(Icons.account_tree_rounded, color: AppColors.hubGraph, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '지식그래프 보기',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.hubGraph,
                    ),
                  ),
                  Text(
                    '이 일기에서 생성된 노드를 그래프에서 확인',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.hubGraph),
          ],
        ),
      ),
    );
  }
}
