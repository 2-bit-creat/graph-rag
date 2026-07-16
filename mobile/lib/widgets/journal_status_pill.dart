import 'package:flutter/material.dart';

import '../chat/journal_task_controller.dart';
import '../theme/app_theme.dart';

/// Floating status pill for the journal pipeline (Feature C).
///
/// Replaces the old full-width lock bar that blocked the composer. Chat stays
/// usable; this compact pill floats at the top of the chat feed, showing a
/// spinner + stage label while the AI works, and pulsing with a touch icon when
/// the pipeline needs the user (speaker/graph review). Tapping it opens review.
class JournalStatusPill extends StatefulWidget {
  const JournalStatusPill({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<JournalStatusPill> createState() => _JournalStatusPillState();
}

class _JournalStatusPillState extends State<JournalStatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: journalTask,
      builder: (context, _) {
        if (!journalTask.showsPill) return const SizedBox.shrink();
        final needsInput = journalTask.needsInput;
        final label = journalTask.stageLabel.isNotEmpty
            ? journalTask.stageLabel
            : (needsInput ? '검토가 필요해요' : '처리 중…');
        final shell = context.shell;
        final accent = needsInput ? AppColors.accentWarm : AppColors.hubGraph;

        final pill = Material(
          color: shell.barBackground,
          elevation: 4,
          shadowColor: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: accent.withValues(alpha: 0.45)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (needsInput)
                    Icon(Icons.touch_app_rounded, size: 15, color: accent)
                  else
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(accent),
                      ),
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: shell.primaryText.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.chevron_right_rounded,
                      size: 16, color: shell.mutedText),
                ],
              ),
            ),
          ),
        );

        if (!needsInput) return pill;
        // Pulse when the user's attention is needed.
        return ScaleTransition(
          scale: Tween<double>(begin: 1.0, end: 1.04).animate(
            CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
          ),
          child: pill,
        );
      },
    );
  }
}
