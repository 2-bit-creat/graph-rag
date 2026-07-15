import 'package:flutter/material.dart';

import '../api/client.dart';
import '../app_navigator.dart';
import '../chat/journal_task_controller.dart';
import '../compose/journal_phase.dart';
import '../screens/graph_review_screen.dart';
import '../screens/journal_hub_screen.dart';
import '../theme/app_theme.dart';
import 'graph_review_panel.dart';
import 'transcript_speaker_view.dart';

/// Inline journal pipeline card in the chat message stream.
///
/// Live when [journalTask] owns [entryId]; otherwise a one-shot [getEntry]
/// snapshot for historical cards after room reload.
class JournalProgressCard extends StatefulWidget {
  const JournalProgressCard({super.key, required this.entryId});

  final String entryId;

  @override
  State<JournalProgressCard> createState() => _JournalProgressCardState();
}

class _JournalProgressCardState extends State<JournalProgressCard> {
  Map<String, dynamic>? _staticEntry;
  bool _loadingStatic = false;
  String? _staticError;

  bool get _isLive => journalTask.entryId == widget.entryId;

  @override
  void initState() {
    super.initState();
    if (!_isLive) _loadStatic();
  }

  @override
  void didUpdateWidget(covariant JournalProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entryId != widget.entryId && !_isLive) {
      _loadStatic();
    }
  }

  Future<void> _loadStatic() async {
    setState(() {
      _loadingStatic = true;
      _staticError = null;
    });
    try {
      final entry = await apiClient.getEntry(widget.entryId);
      if (!mounted) return;
      setState(() {
        _staticEntry = entry;
        _loadingStatic = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _staticError = e.toString();
        _loadingStatic = false;
      });
    }
  }

  Future<void> _openSpeakerConfirm() async {
    // Live entry whose speakers need no per-speaker assignment (single "나" or
    // already-resolved): acknowledging is all that's needed — it kicks off the
    // graph build immediately, with no detour to a separate screen and no
    // lingering "graph pending" waiting state.
    if (_isLive && !speakersPending(journalTask.entry)) {
      await journalTask.confirmSpeakers();
      return;
    }
    // Multiple / unassigned speakers still need the chip-assignment UI. Once
    // they're assigned, acknowledging continues the pipeline into the auto-build.
    final nav = appNavigatorKey.currentContext;
    if (nav == null) return;
    await JournalHubScreen.openEntryDetail(nav, widget.entryId);
    if (_isLive) {
      await journalTask.refresh();
      if (!speakersPending(journalTask.entry)) {
        await journalTask.confirmSpeakers();
      }
    } else if (mounted) {
      await _loadStatic();
    }
  }

  Future<void> _openGraphReview() async {
    final navCtx = appNavigatorKey.currentContext;
    if (navCtx == null) return;
    Map<String, dynamic> fresh;
    try {
      fresh = await apiClient.getEntry(widget.entryId);
    } catch (_) {
      return;
    }
    final staging = fresh['graph_staging'];
    if (staging is! Map) return;
    final committed = await Navigator.of(navCtx).push<bool>(
      MaterialPageRoute(
        builder: (_) => GraphReviewScreen(
          entryId: widget.entryId,
          staging: Map<String, dynamic>.from(staging),
        ),
      ),
    );
    if (_isLive) {
      if (journalTask.phase != ComposePhase.working) {
        await journalTask.refresh();
      }
    } else if (mounted) {
      await _loadStatic();
    }
    if (committed == true && navCtx.mounted) {
      ScaffoldMessenger.of(navCtx).showSnackBar(
        const SnackBar(content: Text('지식그래프 확정 완료')),
      );
    }
  }

  void _dismiss() {
    if (_isLive) journalTask.dismiss();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLive) {
      return AnimatedBuilder(
        animation: journalTask,
        builder: (context, _) {
          final phase = journalTask.phase;
          // Speaker step wins over the graph-review step whenever the user has
          // gone back to re-check speakers (reopenSpeakerConfirm keeps the stale
          // staging around, so isGraphReviewPending(entry) would otherwise still
          // be true).
          final showSpeaker = phase == ComposePhase.needsInput &&
              (journalTask.speakerReviewOverride ||
                  journalTask.awaitingSpeakerAck);
          final showGraph = phase == ComposePhase.needsInput &&
              !showSpeaker &&
              isGraphReviewPending(journalTask.entry);
          return _CardBody(
            entryId: widget.entryId,
            isLive: true,
            phase: phase,
            label: journalTask.stageLabel,
            entry: journalTask.entry,
            showSpeakerConfirm: showSpeaker,
            showGraphReview: showGraph,
            onRefresh: () => journalTask.refresh(),
            onConfirmSpeakers: () => journalTask.confirmSpeakers(),
            onReopenSpeakers: () => journalTask.reopenSpeakerConfirm(),
            onSpeakerFallback: _openSpeakerConfirm,
            onGraphFallback: _openGraphReview,
            onDismiss: _dismiss,
          );
        },
      );
    }

    if (_loadingStatic) {
      return const _Shell(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    if (_staticError != null || _staticEntry == null) {
      return _Shell(
        child: Text(
          _staticError ?? '일기 상태를 불러오지 못했어요.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    // Use the chat-aware derivation (speakersAcknowledged: false) so a reloaded
    // room shows the "화자 확인" action for an un-built entry instead of a
    // phantom "완성" — matching the live card's gating.
    final derived =
        deriveChatJournalPhase(_staticEntry, speakersAcknowledged: false);
    return _CardBody(
      entryId: widget.entryId,
      isLive: false,
      phase: derived.phase,
      label: derived.label,
      entry: _staticEntry,
      showSpeakerConfirm:
          derived.phase == ComposePhase.needsInput && derived.awaitingSpeakerAck,
      showGraphReview: derived.phase == ComposePhase.needsInput &&
          derived.graphReviewPending,
      onRefresh: () => _loadStatic(),
      onConfirmSpeakers: null,
      onReopenSpeakers: null,
      onSpeakerFallback: _openSpeakerConfirm,
      onGraphFallback: _openGraphReview,
      onDismiss: null,
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.shell.subtleSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.shell.panelBorder),
      ),
      child: child,
    );
  }
}

class _CardBody extends StatelessWidget {
  const _CardBody({
    required this.entryId,
    required this.isLive,
    required this.phase,
    required this.label,
    required this.entry,
    required this.showSpeakerConfirm,
    required this.showGraphReview,
    required this.onRefresh,
    required this.onConfirmSpeakers,
    required this.onReopenSpeakers,
    required this.onSpeakerFallback,
    required this.onGraphFallback,
    required this.onDismiss,
  });

  final String entryId;
  final bool isLive;
  final ComposePhase phase;
  final String label;
  final Map<String, dynamic>? entry;

  /// Which review step (if any) is active right now.
  final bool showSpeakerConfirm;
  final bool showGraphReview;

  /// Reload the entry after an inline edit (chip assignment, etc.).
  final Future<void> Function() onRefresh;

  /// Acknowledge speakers → triggers the auto-build. Null for static cards.
  final Future<void> Function()? onConfirmSpeakers;

  /// Go back from graph review to re-check speakers. Null for static cards.
  final VoidCallback? onReopenSpeakers;

  /// Navigation fallbacks (used for static/reloaded cards where the live task
  /// no longer owns the entry).
  final VoidCallback onSpeakerFallback;
  final VoidCallback onGraphFallback;

  final VoidCallback? onDismiss;

  static const _steps = [
    '받아쓰기',
    '화자 확인',
    '그래프 생성',
    '완료',
  ];

  int get _activeStep {
    switch (phase) {
      case ComposePhase.working:
        final status = entry?['status']?.toString() ?? '';
        final graphStatus = entry?['graph_status']?.toString() ?? '';
        if (status == 'graph_processing' ||
            graphStatus == 'graph_processing' ||
            label.contains('그래프')) {
          return 2;
        }
        return 0;
      case ComposePhase.needsInput:
        if (showGraphReview) return 2;
        return 1;
      case ComposePhase.done:
        return 3;
      case ComposePhase.error:
        return _inferErrorStep();
      case ComposePhase.composing:
        return 0;
    }
  }

  int _inferErrorStep() {
    final status = entry?['status']?.toString() ?? '';
    final graphStatus = entry?['graph_status']?.toString() ?? '';
    if (status == 'graph_failed' || graphStatus == 'graph_failed') return 2;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final step = _activeStep;
    final showDismiss =
        onDismiss != null &&
        (phase == ComposePhase.done || phase == ComposePhase.error);

    return _Shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_stories_rounded,
                  size: 16, color: AppColors.hubVoice),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label.isEmpty ? '일기 처리' : label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: context.shell.primaryText,
                  ),
                ),
              ),
              if (showDismiss)
                InkWell(
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded,
                        size: 16, color: context.shell.primaryText),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (var i = 0; i < _steps.length; i++) ...[
                if (i > 0)
                  Expanded(
                    child: Container(
                      height: 1.5,
                      color: i <= step
                          ? AppColors.hubVoice.withValues(alpha: 0.7)
                          : context.shell.panelBorder,
                    ),
                  ),
                _StepDot(
                  label: _steps[i],
                  state: i < step
                      ? _StepState.done
                      : i == step
                          ? (phase == ComposePhase.working
                              ? _StepState.busy
                              : phase == ComposePhase.error && i == step
                                  ? _StepState.error
                                  : _StepState.active)
                          : _StepState.todo,
                ),
              ],
            ],
          ),
          if (showSpeakerConfirm) ...[
            const SizedBox(height: 12),
            _InlineSpeakerConfirm(
              entryId: entryId,
              entry: entry,
              isLive: isLive,
              onConfirm: onConfirmSpeakers,
              onRefresh: onRefresh,
              onFallback: onSpeakerFallback,
            ),
          ],
          if (showGraphReview) ...[
            const SizedBox(height: 12),
            _InlineGraphReview(
              entryId: entryId,
              entry: entry,
              onReopenSpeakers: onReopenSpeakers,
              onFallback: onGraphFallback,
            ),
          ],
          if (phase == ComposePhase.error) ...[
            const SizedBox(height: 8),
            Text(
              '처리에 실패했어요. 닫은 뒤 다시 시도해 주세요.',
              style: TextStyle(
                fontSize: 11.5,
                color: Colors.red.shade300,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline speaker-confirmation, rendered right in the chat card — the user
/// reviews the speaker script and confirms (or taps a chip to reassign) without
/// leaving the feed. Confirming acknowledges speakers and kicks the auto-build.
class _InlineSpeakerConfirm extends StatelessWidget {
  const _InlineSpeakerConfirm({
    required this.entryId,
    required this.entry,
    required this.isLive,
    required this.onConfirm,
    required this.onRefresh,
    required this.onFallback,
  });

  final String entryId;
  final Map<String, dynamic>? entry;
  final bool isLive;
  final Future<void> Function()? onConfirm;
  final Future<void> Function() onRefresh;
  final VoidCallback onFallback;

  @override
  Widget build(BuildContext context) {
    final segments = entry?['transcript_segments'] as List<dynamic>? ?? [];
    final summaries = entry?['speaker_summaries'] as List<dynamic>? ?? [];
    final pending = speakersPending(entry);
    final canConfirmInline = isLive && onConfirm != null;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.shell.panelBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.shell.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            pending
                ? '누가 쓴/말한 글인지 화자를 지정하세요.'
                : '화자를 확인하고 그래프를 만들어요. 필요하면 화자를 탭해 바꿀 수 있어요.',
            style: TextStyle(
              fontSize: 11.5,
              color: context.shell.mutedText,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          if (segments.isNotEmpty)
            TranscriptSpeakerView(
              entryId: entryId,
              segments: segments,
              speakerSummaries: summaries,
              onConfirmed: onRefresh,
              readOnly: false,
              showHeader: false,
              wrapInCard: false,
            )
          else
            _plainScript(context),
          const SizedBox(height: 10),
          if (canConfirmInline)
            FilledButton.icon(
              onPressed: pending ? null : () => onConfirm!(),
              icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
              label: Text(pending ? '화자를 먼저 지정하세요' : '확인하고 그래프 만들기'),
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onFallback,
                child: const Text('화자 확인'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _plainScript(BuildContext context) {
    final clean = entry?['transcript_clean_ko']?.toString().trim() ?? '';
    final raw = entry?['transcript_ko']?.toString().trim() ?? '';
    final text = clean.isNotEmpty ? clean : raw;
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.shell.subtleSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.4,
          color: context.shell.primaryText,
        ),
      ),
    );
  }
}

/// Inline graph-draft review, rendered in the chat card. Reuses the chat-mode
/// [GraphReviewPanel] so the user edits/confirms claims in the feed instead of a
/// pushed screen. The [ValueKey] keeps edits across the card's rebuilds.
class _InlineGraphReview extends StatelessWidget {
  const _InlineGraphReview({
    required this.entryId,
    required this.entry,
    required this.onReopenSpeakers,
    required this.onFallback,
  });

  final String entryId;
  final Map<String, dynamic>? entry;
  final VoidCallback? onReopenSpeakers;
  final VoidCallback onFallback;

  @override
  Widget build(BuildContext context) {
    final staging = entry?['graph_staging'];
    if (staging is! Map) {
      // Draft not in the current payload (brief race) — fall back to fetch+review.
      return Align(
        alignment: Alignment.centerRight,
        child: FilledButton.tonal(
          onPressed: onFallback,
          child: const Text('그래프 검토'),
        ),
      );
    }
    return GraphReviewPanel(
      key: ValueKey('graph-review-$entryId'),
      entryId: entryId,
      staging: Map<String, dynamic>.from(staging),
      presentation: GraphReviewPresentation.chat,
      maxBodyHeight: 420,
      onReopenSpeakers: onReopenSpeakers,
    );
  }
}

enum _StepState { todo, active, busy, done, error }

class _StepDot extends StatelessWidget {
  const _StepDot({required this.label, required this.state});
  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    Widget icon;
    switch (state) {
      case _StepState.done:
        icon = const Icon(Icons.check_circle, size: 16, color: Color(0xFF4CAF50));
        break;
      case _StepState.busy:
        icon = const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        break;
      case _StepState.error:
        icon = Icon(Icons.error_outline, size: 16, color: Colors.red.shade300);
        break;
      case _StepState.active:
        icon = Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.hubVoice,
          ),
        );
        break;
      case _StepState.todo:
        icon = Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: context.shell.panelBorder,
          ),
        );
        break;
    }
    return Column(
      children: [
        SizedBox(width: 18, height: 18, child: Center(child: icon)),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 9.5,
            color: state == _StepState.todo
                ? context.shell.mutedText
                : context.shell.primaryText.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }
}
