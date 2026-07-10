import 'package:flutter/material.dart';

import '../api/client.dart';
import '../app_navigator.dart';
import '../chat/journal_task_controller.dart';
import '../compose/journal_phase.dart';
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
    final nav = appNavigatorKey.currentContext;
    if (nav == null) return;
    await JournalHubScreen.openEntryDetail(nav, widget.entryId);
    if (_isLive) await journalTask.refresh();
    if (!_isLive && mounted) await _loadStatic();
  }

  Future<void> _confirmSpeakersInline() async {
    await journalTask.confirmSpeakers();
  }

  void _dismiss() {
    if (_isLive) journalTask.dismiss();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLive) {
      return AnimatedBuilder(
        animation: journalTask,
        builder: (context, _) => _CardBody(
          entryId: widget.entryId,
          phase: journalTask.phase,
          label: journalTask.stageLabel,
          entry: journalTask.entry,
          awaitingSpeakerAck: journalTask.awaitingSpeakerAck,
          speakerReviewOverride: journalTask.speakerReviewOverride,
          onConfirmSpeakers: _confirmSpeakersInline,
          onReopenSpeakers: journalTask.reopenSpeakerConfirm,
          onRefreshEntry: journalTask.refresh,
          onDismiss: _dismiss,
          onRetryGraph: journalTask.retryGraphBuild,
          onOpenFullDetail: _openSpeakerConfirm,
        ),
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
          _staticError ?? '?źę¸° ?íëĽ?ëśëŹ?¤ě? ëŞťí?´ě.',
          style: const TextStyle(fontSize: 12.5, color: context.mutedText),
        ),
      );
    }
    final derived = deriveChatJournalPhase(
      _staticEntry,
      speakersAcknowledged: true,
    );
    return _CardBody(
      entryId: widget.entryId,
      phase: derived.phase,
      label: derived.label,
      entry: _staticEntry,
      awaitingSpeakerAck: false,
      speakerReviewOverride: false,
      onConfirmSpeakers: null,
      onReopenSpeakers: null,
      onRefreshEntry: null,
      onDismiss: null,
      onRetryGraph: null,
      onOpenFullDetail: _openSpeakerConfirm,
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: shell.subtleSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: shell.panelBorder),
      ),
      child: child,
    );
  }
}

class _CardBody extends StatelessWidget {
  const _CardBody({
    required this.entryId,
    required this.phase,
    required this.label,
    required this.entry,
    required this.awaitingSpeakerAck,
    required this.speakerReviewOverride,
    required this.onConfirmSpeakers,
    this.onReopenSpeakers,
    required this.onRefreshEntry,
    this.onDismiss,
    this.onRetryGraph,
    this.onOpenFullDetail,
  });

  final String entryId;
  final ComposePhase phase;
  final String label;
  final Map<String, dynamic>? entry;
  final bool awaitingSpeakerAck;
  final bool speakerReviewOverride;
  final Future<void> Function()? onConfirmSpeakers;
  final VoidCallback? onReopenSpeakers;
  final Future<void> Function()? onRefreshEntry;
  final VoidCallback? onDismiss;
  final VoidCallback? onRetryGraph;
  final VoidCallback? onOpenFullDetail;

  static const _steps = [
    'ë°ě?°ę¸°',
    '?ě ?ě¸',
    'ęˇ¸ë???ěą',
    '?ëŁ',
  ];

  int get _activeStep {
    switch (phase) {
      case ComposePhase.working:
        final status = entry?['status']?.toString() ?? '';
        final graphStatus = entry?['graph_status']?.toString() ?? '';
        if (status == 'processing') return 0;
        if (status == 'graph_processing' ||
            graphStatus == 'graph_processing' ||
            label.contains('ęˇ¸ë??) ||
            label.contains('?ě ')) {
          return 2;
        }
        return 0;
      case ComposePhase.needsInput:
        if (speakerReviewOverride) return 1;
        if (isGraphReviewPending(entry)) return 2;
        if (awaitingSpeakerAck || speakersPending(entry)) return 1;
        return 1;
      case ComposePhase.done:
        return 3;
      case ComposePhase.error:
        return _inferErrorStep();
      case ComposePhase.composing:
        return 0;
    }
  }

  String? get _hint {
    switch (phase) {
      case ComposePhase.working:
        final status = entry?['status']?.toString() ?? '';
        if (status == 'processing') {
          return 'ë°ě?°ę¸°Âˇ?ě ę° ?ë  ?ęšě§ ? ěë§?ę¸°ë¤??ěŁźě¸??';
        }
        if (label.contains('?ě ')) {
          return 'ęˇ¸ë?ë? ?ě ?ęł  ?ě´?? ? ěë§?ę¸°ë¤??ěŁźě¸??';
        }
        return 'ęˇ¸ë??ě´ě??ë§ë¤ęł??ě´?? ?ëŁ?ëŠ´ ?ë??ę˛???ëŠ´???í??Šë??';
      case ComposePhase.needsInput:
        if (isGraphReviewPending(entry)) {
          return '?ěą??ęˇ¸ë??ě´ě???ě¸Âˇ?ě ?????ě ??ěŁźě¸??';
        }
        if (speakersPending(entry)) {
          return '?ě ěšŠě ??´ ë§¤ěš­???ě ???? ?ě¸ ?ëŁëĽ??ëŹ ěŁźě¸??';
        }
        return '?ě ???¤íŹëŚ˝í¸? ?ě ë§¤ěš­???ě¸???? ?ě¸ ?ëŁëĽ??ëŹ ěŁźě¸??';
      case ComposePhase.done:
        return 'ëŞ¨ë  ?¨ęłę° ?ëŹ?´ě. ?Ťę¸°ëĄ?ěš´ëëĽ??ëŚŹ?????ě´??';
      case ComposePhase.error:
        return 'ě˛ëŚŹ???¤í¨?ě´?? ?Ťě? ???¤ě ?ë??ěŁźě¸??';
      case ComposePhase.composing:
        return null;
    }
  }

  bool get _needsGraphKick {
    if (phase != ComposePhase.error) return false;
    final graphStatus = entry?['graph_status']?.toString() ?? '';
    final status = entry?['status']?.toString() ?? '';
    return status == 'graph_failed' || graphStatus == 'graph_failed';
  }

  int _inferErrorStep() {
    final status = entry?['status']?.toString() ?? '';
    final graphStatus = entry?['graph_status']?.toString() ?? '';
    if (status == 'graph_failed' || graphStatus == 'graph_failed') return 2;
    return 0;
  }

  Widget _graphReviewPanel(BuildContext context) {
    final staging = entry?['graph_staging'];
    if (staging is! Map) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          'ęˇ¸ë??ě´ě??ëśëŹ?¤ë ě¤â?,
          style: TextStyle(
            fontSize: 12,
            color: context.shell.mutedText,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: GraphReviewPanel(
        entryId: entryId,
        staging: Map<String, dynamic>.from(staging),
        presentation: GraphReviewPresentation.chat,
        maxBodyHeight: 360,
        onReopenSpeakers: onReopenSpeakers,
        onApplied: () {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('ě§?ęˇ¸?í ?ě  ?ëŁ')),
            );
          }
        },
      ),
    );
  }

  Widget _speakerScriptPanel(BuildContext context) {
    final segments = entry?['transcript_segments'] as List<dynamic>? ?? [];
    final summaries = entry?['speaker_summaries'] as List<dynamic>? ?? [];
    if (segments.isEmpty) return const SizedBox.shrink();

    return Theme(
      data: ThemeData.light(useMaterial3: true),
      child: Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.black12),
        ),
        child: TranscriptSpeakerView(
          entryId: entryId,
          segments: segments,
          speakerSummaries: summaries,
          showHeader: true,
          wrapInCard: false,
          onConfirmed: onRefreshEntry,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final step = _activeStep;
    final showSpeakerPanel =
        speakerReviewOverride ||
        awaitingSpeakerAck ||
        (phase == ComposePhase.needsInput && !isGraphReviewPending(entry));
    final speakersStillPending = speakersPending(entry);
    final needsGraph =
        !speakerReviewOverride &&
        phase == ComposePhase.needsInput &&
        isGraphReviewPending(entry);
    final showDismiss =
        onDismiss != null &&
        (phase == ComposePhase.done || phase == ComposePhase.error);
    final hint = _hint;
    final canConfirmSpeakers =
        onConfirmSpeakers != null && !speakersStillPending;

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
                  label.isEmpty ? '?źę¸° ě˛ëŚŹ' : label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: shell.primaryText,
                  ),
                ),
              ),
              if (showDismiss)
                InkWell(
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded,
                        size: 16, color: shell.primaryText),
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
                          : shell.panelBorder,
                    ),
                  ),
                _StepDot(
                  label: _steps[i],
                  state: _stepState(i, step),
                ),
              ],
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 10),
            Text(
              hint,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: shell.mutedText,
              ),
            ),
          ],
          if (showSpeakerPanel) _speakerScriptPanel(context),
          if (showSpeakerPanel && onConfirmSpeakers != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: canConfirmSpeakers ? () => onConfirmSpeakers!() : null,
                icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                label: Text(
                  speakersStillPending
                      ? 'ëŻ¸í???ěę° ?ě´??
                      : '?ě ?ě¸ ?ëŁ Âˇ ęˇ¸ë??ë§ë¤ę¸?,
                ),
              ),
            ),
            if (onOpenFullDetail != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onOpenFullDetail,
                  child: const Text('?ě˛´ ?ëŠ´?ě ëł´ę¸°'),
                ),
              ),
          ],
          if (needsGraph) _graphReviewPanel(context),
          if (_needsGraphKick && onRetryGraph != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onRetryGraph,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('ęˇ¸ë???¤ě ë§ë¤ę¸?),
              ),
            ),
          ],
          if (phase == ComposePhase.done && onDismiss != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onDismiss, child: const Text('?Ťę¸°')),
            ),
          ],
        ],
      ),
    );
  }

  _StepState _stepState(int i, int step) {
    if (i < step) return _StepState.done;
    if (i > step) return _StepState.todo;
    if (phase == ComposePhase.working) return _StepState.busy;
    if (phase == ComposePhase.error) return _StepState.error;
    return _StepState.active;
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
            color: context.shell.mutedText.withValues(alpha: 0.5),
          ),
        );
        break;
    }
    final shell = context.shell;
    return Column(
      children: [
        SizedBox(width: 18, height: 18, child: Center(child: icon)),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 9.5,
            color: state == _StepState.todo
                ? shell.mutedText
                : shell.primaryText.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }
}
