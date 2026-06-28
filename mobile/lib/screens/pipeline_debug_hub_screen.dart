import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/entry_hub_layout.dart';
import '../widgets/journal_pipeline_panel.dart';

/// 개발자용 — 음성·텍스트 기록별 처리 파이프라인 trace 디버깅.
class PipelineDebugHubScreen extends StatelessWidget {
  const PipelineDebugHubScreen({super.key, this.initialEntryId});

  final String? initialEntryId;

  @override
  Widget build(BuildContext context) {
    return EntryHubNavigator(
      title: '파이프라인',
      initialEntryId: initialEntryId,
      emptyHint: '디버깅할 기록이 없습니다',
      emptySubtitle: '일기를 작성한 뒤 여기서 trace를 확인하세요',
      showEntrySourceBadge: true,
      detailBuilder: (context, entry, entryId, refresh) {
        final isText = entry['entry_source']?.toString() == 'precision_text';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageH,
                AppSpacing.sm,
                AppSpacing.pageH,
                0,
              ),
              child: AppSurfaceCard(
                tint: AppColors.hubQuiz,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bug_report_outlined, color: AppColors.hubQuiz, size: 20),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        isText
                            ? '텍스트 입력 경로 · precision_text'
                            : '음성 업로드 경로 · STT → 번역 → Semantic Chunk ingest',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: JournalPipelinePanel(
                entryId: entryId,
                entry: entry,
                isPrecisionText: isText,
                onRefresh: refresh,
              ),
            ),
          ],
        );
      },
    );
  }
}
