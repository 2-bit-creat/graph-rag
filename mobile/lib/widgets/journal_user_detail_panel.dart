import 'package:flutter/material.dart';

import '../api/client.dart';
import '../compose/compose_session_controller.dart';
import '../screens/graph_review_screen.dart';
import '../screens/knowledge_graph_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/translation_entry_panel.dart';

/// 사용자용 일기 상세 — 정제본·화자 확인 (파이프라인 trace 없음).
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
  bool get _isText => widget.entry['entry_source']?.toString() == 'precision_text';

  bool get _hasGraph {
    final graphStatus = widget.entry['graph_status']?.toString() ?? '';
    final status = widget.entry['status']?.toString() ?? '';
    return graphStatus == 'graph_ready' || status == 'graph_ready';
  }

  /// A draft graph has been generated and awaits the user's review/confirmation.
  bool get _isStagingReady {
    final graphStatus = widget.entry['graph_status']?.toString() ?? '';
    final status = widget.entry['status']?.toString() ?? '';
    if (_hasGraph) return false;
    return graphStatus == 'graph_staging_ready' || status == 'graph_staging_ready';
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
  ///
  /// 2026-07-04 통일: 텍스트도 음성과 동일하게 저장 후 화자 칩에서 지정한다
  /// (나/사람/외부 출처). 예전의 precision_text 예외는 확인 UI가 없어서였고,
  /// 이제 칩이 텍스트에도 렌더되므로 게이트를 동일하게 적용한다.
  bool get _speakersPending {
    final summaries = widget.entry['speaker_summaries'] as List<dynamic>? ?? [];
    for (final raw in summaries) {
      if (raw is! Map) continue;
      if (raw['needs_confirmation'] == true) return true;
    }
    return false;
  }

  /// 그래프 초안 생성을 세션에 위임한다 — 텍스트·음성과 동일하게 창이 우하단
  /// 미니 카드로 접히고 백그라운드에서 초안을 만든다. 초안이 준비되면 미니 카드가
  /// '그래프 검토 필요'로 바뀌고, 탭하면 창이 펼쳐져 검토·확정으로 이어진다.
  ///
  /// 전체화면 상세(타임라인 진입 등)에서 눌렀다면 그 라우트를 닫아 미니 카드만
  /// 남긴다. 작성 창 안(중첩 Navigator)이라면 pop할 라우트가 없어 접히기만 한다.
  void _openManualGraphAdd() {
    composeSession.startGraphBuild(widget.entryId);
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  /// Open the HITL review screen for the freshly-staged draft. On confirmation
  /// the entry is refreshed so the committed "지식그래프 보기" banner appears.
  Future<void> _openReview() async {
    final fresh = await apiClient.getEntry(widget.entryId);
    final staging = fresh['graph_staging'];
    if (staging is! Map) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('검토할 그래프 드래프트를 찾을 수 없습니다.')),
      );
      return;
    }
    if (!mounted) return;
    final committed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => GraphReviewScreen(
          entryId: widget.entryId,
          staging: Map<String, dynamic>.from(staging),
        ),
      ),
    );
    await widget.onRefresh();
    if (committed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('지식그래프 확정 완료')),
      );
    }
  }

  /// 기록 → 화자 확인 → 그래프 생성 → 검토·확정 여정에서 지금 어디인지 + 다음
  /// 행동 하나를 보여준다. (그래프 확정 후에는 _GraphViewBanner로 대체.)
  Widget _buildJourneyCard(BuildContext context) {
    final status = widget.entry['status']?.toString() ?? '';
    final graphStatus = widget.entry['graph_status']?.toString() ?? '';

    if (status == 'processing') {
      return const _EntryJourneyCard(
        currentStep: 0,
        inProgress: true,
        message: 'AI가 받아쓰기와 문장 정리를 진행하고 있어요. 잠시 후 아래로 당겨 새로고침해 보세요.',
      );
    }
    if (status == 'failed') {
      return const _EntryJourneyCard(
        currentStep: 0,
        error: true,
        message: '처리에 실패했어요. 이 기록을 삭제한 뒤 다시 시도해 주세요.',
      );
    }
    if (status == 'graph_processing' || graphStatus == 'graph_processing') {
      return const _EntryJourneyCard(
        currentStep: 2,
        inProgress: true,
        message: '기록에서 핵심 내용을 뽑아 지식그래프 초안을 만드는 중이에요…',
      );
    }
    if (_isStagingReady) {
      return _EntryJourneyCard(
        currentStep: 3,
        message: 'AI가 만든 그래프 초안이 준비됐어요. 내용을 확인하고 확정하면 지식그래프에 저장됩니다.',
        ctaLabel: '검토하고 확정하기',
        ctaIcon: Icons.rate_review_outlined,
        onCta: _openReview,
      );
    }
    if (_speakersPending) {
      return const _EntryJourneyCard(
        currentStep: 1,
        // ctaIcon만 지정하고 ctaLabel은 비워, 버튼 없이 리딩 아이콘만 '화자'로.
        ctaIcon: Icons.record_voice_over_rounded,
        message: '아래 화자 칩에서 누가 말했는지 지정해 주세요. 화자를 확정해야 그래프를 만들 수 있어요.',
      );
    }
    if (status == 'graph_failed' || graphStatus == 'graph_failed') {
      return _EntryJourneyCard(
        currentStep: 2,
        error: true,
        message: '그래프 생성에 실패했어요. 다시 시도해 주세요.',
        ctaLabel: '다시 시도',
        ctaIcon: Icons.refresh_rounded,
        onCta: _openManualGraphAdd,
      );
    }
    if (_canManualGraphAdd) {
      return _EntryJourneyCard(
        currentStep: 2,
        message: '기록이 준비됐어요! 이제 핵심 내용을 지식그래프로 정리할 수 있어요. 확정 전에 검토할 수 있으니 부담 없이 만들어 보세요.',
        ctaLabel: '지식그래프 만들기',
        ctaIcon: Icons.account_tree_outlined,
        onCta: _openManualGraphAdd,
      );
    }
    // 정제 텍스트/세그먼트가 아직 없는 등 그래프 생성 조건 미충족 — 여정만 표시.
    return const _EntryJourneyCard(
      currentStep: 1,
      message: '기록이 저장됐어요. 처리가 끝나면 그래프를 만들 수 있어요.',
    );
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
          ] else ...[
            _buildJourneyCard(context),
            const SizedBox(height: AppSpacing.md),
          ],
          TranslationEntryPanel(
            entry: widget.entry,
            entryId: widget.entryId,
            onRefresh: widget.onRefresh,
            isPrecisionText: _isText,
            locked: _hasGraph,
          ),
        ],
      ),
    );
  }
}

/// 기록 → 화자 확인 → 그래프 생성 → 검토·확정 4단계 진행 카드.
/// 현재 단계 하나와 다음 행동(CTA) 하나만 보여준다 — 화면당 하나의 주 행동 원칙.
class _EntryJourneyCard extends StatelessWidget {
  const _EntryJourneyCard({
    required this.currentStep,
    required this.message,
    this.inProgress = false,
    this.error = false,
    this.ctaLabel,
    this.ctaIcon,
    this.onCta,
  });

  static const _steps = ['기록', '화자 확인', '그래프 생성', '검토·확정'];

  /// 0-based index into [_steps]; 이전 단계는 완료로 표시.
  final int currentStep;
  final String message;
  final bool inProgress;
  final bool error;
  final String? ctaLabel;
  final IconData? ctaIcon;
  final VoidCallback? onCta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accent = error ? colorScheme.error : AppColors.accent;

    // 리딩 상태 아이콘 — 4점 스텝퍼 대신 현재 상태 하나만 표현(정보 과부하 제거).
    final Widget leadingIcon;
    if (inProgress) {
      leadingIcon = SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.4, color: accent),
      );
    } else {
      leadingIcon = Icon(
        error
            ? Icons.error_outline_rounded
            : (ctaIcon ?? Icons.check_circle_outline_rounded),
        color: accent,
        size: 24,
      );
    }

    // 진행 단계 문맥 — 눈에 안 띄는 eyebrow 한 줄로만.
    final eyebrow = error
        ? '문제가 생겼어요'
        : inProgress
            ? '진행 중 · ${_steps[currentStep]}'
            : '지금 할 일 · ${_steps[currentStep]}';

    return AppSurfaceCard(
      tint: error ? colorScheme.error : AppColors.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.12),
                ),
                child: leadingIcon,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      eyebrow,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (ctaLabel != null) ...[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onCta,
                icon: Icon(ctaIcon ?? Icons.arrow_forward_rounded),
                label: Text(ctaLabel!),
              ),
            ),
          ],
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
