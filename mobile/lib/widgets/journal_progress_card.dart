import 'package:flutter/material.dart';

import '../api/client.dart';
import '../app_navigator.dart';
import '../chat/journal_task_controller.dart';
import '../compose/journal_phase.dart';
import '../screens/graph_review_screen.dart';
import '../screens/journal_hub_screen.dart';
import '../theme/app_theme.dart';

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
        builder: (context, _) => _CardBody(
          phase: journalTask.phase,
          label: journalTask.stageLabel,
          entry: journalTask.entry,
          onSpeakerConfirm: _openSpeakerConfirm,
          onGraphReview: _openGraphReview,
          onDismiss: _dismiss,
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
          _staticError ?? '일기 상태를 불러오지 못했어요.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final derived = deriveJournalPhase(_staticEntry);
    return _CardBody(
      phase: derived.phase,
      label: derived.label,
      entry: _staticEntry,
      onSpeakerConfirm: _openSpeakerConfirm,
      onGraphReview: _openGraphReview,
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
    required this.phase,
    required this.label,
    required this.entry,
    required this.onSpeakerConfirm,
    required this.onGraphReview,
    required this.onDismiss,
  });

  final ComposePhase phase;
  final String label;
  final Map<String, dynamic>? entry;
  final VoidCallback onSpeakerConfirm;
  final VoidCallback onGraphReview;
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
        if (isGraphReviewPending(entry)) return 2;
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
    final needsSpeaker =
        phase == ComposePhase.needsInput && !isGraphReviewPending(entry);
    final needsGraph =
        phase == ComposePhase.needsInput && isGraphReviewPending(entry);
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
          if (needsSpeaker || needsGraph) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: needsGraph ? onGraphReview : onSpeakerConfirm,
                child: Text(needsGraph ? '그래프 검토' : '화자 확인'),
              ),
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
