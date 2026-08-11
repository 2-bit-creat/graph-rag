import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// One row of speaker chips — the single surface for "who is in this entry".
///
/// Every path that produces speakers renders this same bar: text written with
/// @mentions, a voice recording split by diarization, and a chat screenshot read
/// by OCR. Only the initial state differs — voice arrives with unresolved chips,
/// the other two arrive resolved — so the learner sees one vocabulary instead of
/// three.
///
/// Two rules hold the design together:
///
///  * **Color means identity, never status.** The hue comes from
///    `colorForSpeaker`, the same function the composer badges and the graph
///    canvas use, so a speaker keeps one color from typing through to the graph.
///    Status is carried by the icon, which also keeps the distinction legible
///    without relying on color.
///  * **The turn count is always shown.** A bad split is almost always "many
///    speakers with one turn each" — that is exactly the shape a pasted glossary
///    took when it became a 23-speaker conversation. Printing the number makes
///    that visible before it reaches the graph.
class SpeakerChipData {
  const SpeakerChipData({
    required this.label,
    required this.displayName,
    required this.turns,
    required this.color,
    this.resolved = true,
    this.suggested = false,
    this.onTap,
  });

  /// Stable key for this speaker — the session label or the badge name.
  final String label;

  /// What the learner sees: a confirmed node's name when there is one.
  final String displayName;
  final int turns;
  final Color color;

  /// False while this speaker still needs a human answer (voice diarization).
  final bool resolved;

  /// Unresolved, but the server has a candidate to offer.
  final bool suggested;

  final VoidCallback? onTap;
}

class SpeakerBar extends StatelessWidget {
  const SpeakerBar({
    super.key,
    required this.chips,
    this.showLabel = true,
    this.dense = false,
  });

  final List<SpeakerChipData> chips;

  /// The leading "화자" caption. Off inside a section that already says so.
  final bool showLabel;

  /// Tighter metrics for the composer, where vertical space is scarce.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showLabel)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Text(
              tr('speakerBar.label'),
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: context.shell.mutedText),
            ),
          ),
        for (final chip in chips) _SpeakerChip(data: chip, dense: dense),
      ],
    );
  }
}

class _SpeakerChip extends StatelessWidget {
  const _SpeakerChip({required this.data, required this.dense});

  final SpeakerChipData data;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = data.color;
    // Status lives in the icon so the chip stays readable for anyone who cannot
    // separate the palette hues, and so color is free to mean identity alone.
    final icon = data.resolved
        ? Icons.person_rounded
        : data.suggested
            ? Icons.auto_awesome_rounded
            : Icons.help_outline_rounded;

    final body = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(
          color: color.withValues(alpha: data.resolved ? 0.4 : 0.75),
          // An unresolved chip reads as "not settled yet" from its heavier edge
          // even before the icon is parsed.
          width: data.resolved ? 1 : 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 12 : 14, color: color),
          SizedBox(width: dense ? 3 : 4),
          Text(
            data.displayName,
            style: TextStyle(
              fontSize: dense ? 11.5 : 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          if (data.turns > 0) ...[
            SizedBox(width: dense ? 3 : 4),
            Text(
              '${data.turns}',
              style: TextStyle(
                fontSize: dense ? 10.5 : 11,
                fontWeight: FontWeight.w500,
                color: color.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );

    if (data.onTap == null) return body;
    return InkWell(
      onTap: data.onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: body,
    );
  }
}
