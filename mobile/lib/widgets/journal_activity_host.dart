import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_navigator.dart';
import '../chat/journal_task_controller.dart';
import '../compose/journal_activity.dart';
import '../compose/journal_phase.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'journal_progress_card.dart';

/// App-wide, non-blocking journal status. Processing never occupies the chat
/// feed; the full review UI opens only when the learner asks for it.
class JournalActivityHost extends StatefulWidget {
  const JournalActivityHost({super.key});

  @override
  State<JournalActivityHost> createState() => _JournalActivityHostState();
}

/// Opens the single detailed surface shared by the global activity tab and the
/// small contextual status card left in the chat that started the journal.
Future<void> openJournalActivityDetails() async {
  final navContext = appNavigatorKey.currentContext;
  if (navContext == null || !navContext.mounted) return;
  final id = journalTask.entryId;
  await showModalBottomSheet<void>(
    context: navContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(navContext).colorScheme.surface,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: id == null
              ? _WaitingDetails(
                  summary: journalTaskSummary(
                    entryId: journalTask.entryId,
                    entry: journalTask.entry,
                    phase: journalTask.phase,
                    stageLabel: journalTask.stageLabel,
                    awaitingSpeakerAck: journalTask.awaitingSpeakerAck,
                    speakerReviewOverride: journalTask.speakerReviewOverride,
                  ),
                )
              : JournalProgressCard(entryId: id),
        ),
      ),
    ),
  );
}

class _JournalActivityHostState extends State<JournalActivityHost> {
  JournalAttention _lastAttention = JournalAttention.none;
  String? _lastEntryId;
  bool _dismissedTerminal = false;
  Timer? _completeTimer;

  @override
  void initState() {
    super.initState();
    journalTask.addListener(_onTaskChanged);
  }

  @override
  void dispose() {
    _completeTimer?.cancel();
    journalTask.removeListener(_onTaskChanged);
    super.dispose();
  }

  JournalTaskSummary get _summary => journalTaskSummary(
        entryId: journalTask.entryId,
        entry: journalTask.entry,
        phase: journalTask.phase,
        stageLabel: journalTask.stageLabel,
        awaitingSpeakerAck: journalTask.awaitingSpeakerAck,
        speakerReviewOverride: journalTask.speakerReviewOverride,
      );

  void _onTaskChanged() {
    final summary = _summary;
    if (_lastEntryId != summary.entryId) {
      _lastEntryId = summary.entryId;
      _dismissedTerminal = false;
      _completeTimer?.cancel();
    }
    if (summary.attention == JournalAttention.reviewRequired &&
        _lastAttention != JournalAttention.reviewRequired) {
      HapticFeedback.mediumImpact();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = appNavigatorKey.currentContext;
        if (context == null || !context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(summary.label),
            action: SnackBarAction(
              label: tr('journalActivity.open'),
              onPressed: _openDetails,
            ),
          ),
        );
      });
    }
    if (summary.stage == JournalActivityStage.complete) {
      _completeTimer ??= Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _dismissedTerminal = true);
      });
    } else {
      _completeTimer?.cancel();
      _completeTimer = null;
    }
    _lastAttention = summary.attention;
    if (mounted) setState(() {});
  }

  Future<void> _openDetails() async {
    await openJournalActivityDetails();
  }

  @override
  Widget build(BuildContext context) {
    final active = (journalTask.phase != ComposePhase.composing &&
            journalTask.entryId != null) ||
        journalTask.systemProcessing;
    if (!active || _dismissedTerminal) return const SizedBox.shrink();
    final summary = _summary;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bottom = keyboard > 0 ? keyboard + 70.0 : 74.0;
    final attention = summary.attention != JournalAttention.none;
    final scheme = Theme.of(context).colorScheme;

    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom,
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 390),
            child: Material(
              elevation: 10,
              shadowColor: Colors.black.withValues(alpha: .28),
              color: attention
                  ? scheme.tertiaryContainer
                  : context.shell.barBackground,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _openDetails,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                  child: Row(
                    children: [
                      _ActivityIcon(summary: summary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              summary.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              attention
                                  ? tr('journalActivity.tapToReview')
                                  : tr('journalActivity.keepUsing'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: context.shell.mutedText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.expand_less_rounded,
                          size: 20, color: context.shell.mutedText),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityIcon extends StatelessWidget {
  const _ActivityIcon({required this.summary});
  final JournalTaskSummary summary;

  @override
  Widget build(BuildContext context) {
    if (summary.working) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      );
    }
    final IconData icon;
    final Color color;
    if (summary.stage == JournalActivityStage.complete) {
      icon = Icons.check_circle_rounded;
      color = Colors.green;
    } else if (summary.stage == JournalActivityStage.failed) {
      icon = Icons.error_rounded;
      color = Theme.of(context).colorScheme.error;
    } else {
      icon = Icons.touch_app_rounded;
      color = Theme.of(context).colorScheme.tertiary;
    }
    return Icon(icon, size: 21, color: color);
  }
}

class _WaitingDetails extends StatelessWidget {
  const _WaitingDetails({required this.summary});
  final JournalTaskSummary summary;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            const CircularProgressIndicator(strokeWidth: 2.4),
            const SizedBox(height: 16),
            Text(summary.label,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(tr('journalActivity.keepUsing'),
                textAlign: TextAlign.center,
                style: TextStyle(color: context.shell.mutedText)),
          ],
        ),
      );
}
