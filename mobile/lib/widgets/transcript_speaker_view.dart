import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import 'mention_editor_core.dart' show colorForSpeaker, speakerColorOrder;
import 'speaker_identity_sheet.dart';
import 'speaker_bar.dart';

/// An entry's transcript with one speaker chip per *speaker*.
///
/// This used to draw a chip on every segment. Confirmation applies to the
/// speaker label, not the line, so a 30-turn chat screenshot produced 30 chips
/// that all opened the same sheet and all did the same thing. Short-turn
/// conversations — exactly what OCR imports produce — were the worst case.
///
/// The speakers are now a single bar, and the transcript below carries identity
/// in the same colors the composer used, so the eye can follow one speaker down
/// the page without reading names.
class TranscriptSpeakerView extends StatelessWidget {
  const TranscriptSpeakerView({
    super.key,
    required this.entryId,
    required this.segments,
    required this.speakerSummaries,
    this.onConfirmed,
    this.readOnly = false,
    this.showHeader = true,
    this.wrapInCard = true,
  });

  final String entryId;
  final List<dynamic> segments;
  final List<dynamic> speakerSummaries;
  final Future<void> Function()? onConfirmed;
  final bool readOnly;

  /// 접이식 섹션 안에 넣을 때는 상위가 제목을 그리므로 내부 헤더를 숨긴다.
  final bool showHeader;

  /// 접이식 섹션 안에 넣을 때는 Card 중첩을 피하기 위해 false.
  final bool wrapInCard;

  Map<String, Map<String, dynamic>> _summaryByLabel() {
    final map = <String, Map<String, dynamic>>{};
    for (final raw in speakerSummaries) {
      if (raw is! Map) continue;
      final label = raw['session_label']?.toString();
      if (label != null && label.isNotEmpty) {
        map[label] = Map<String, dynamic>.from(raw);
      }
    }
    return map;
  }

  /// Speaker labels in first-appearance order, with their turn counts.
  ({List<String> order, Map<String, int> turns}) _speakers() {
    final order = <String>[];
    final turns = <String, int>{};
    for (final raw in segments) {
      if (raw is! Map) continue;
      final label = raw['speaker']?.toString().trim() ?? '';
      if (label.isEmpty) continue;
      if (!turns.containsKey(label)) order.add(label);
      turns[label] = (turns[label] ?? 0) + 1;
    }
    return (order: order, turns: turns);
  }

  Future<void> _openSheet(
    BuildContext context,
    String speakerLabel,
    String profileId,
  ) async {
    final changed = await showSpeakerIdentitySheet(
      context: context,
      entryId: entryId,
      speakerLabel: speakerLabel,
      speakerProfileId: profileId,
    );
    if (changed == true && context.mounted) {
      await Future<void>.delayed(Duration.zero);
      if (context.mounted) await onConfirmed?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (segments.isEmpty) return const SizedBox.shrink();

    final summaries = _summaryByLabel();
    final theme = Theme.of(context);
    final speakers = _speakers();
    // The same ordering rule the composer badges use, so a speaker's color
    // survives the save instead of being reassigned by this view.
    final colorOrder = speakerColorOrder(speakers.order);

    final chips = <SpeakerChipData>[];
    for (final label in speakers.order) {
      final summary = summaries[label];
      final confirmed = summary?['confirmed_node'] as Map<String, dynamic>?;
      final suggested = summary?['suggested_node'] as Map<String, dynamic>?;
      final needsPick = summary?['needs_confirmation'] == true;
      final pid = summary?['speaker_profile_id']?.toString() ??
          _profileIdFromSegments(label);
      chips.add(
        SpeakerChipData(
          label: label,
          displayName: confirmed?['name']?.toString() ??
              suggested?['name']?.toString() ??
              label,
          turns: speakers.turns[label] ?? 0,
          color: colorForSpeaker(label, colorOrder),
          resolved: !needsPick,
          suggested: suggested != null && needsPick,
          onTap: (readOnly || pid == null)
              ? null
              : () => _openSheet(context, label, pid),
        ),
      );
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) ...[
          Row(
            children: [
              Icon(Icons.record_voice_over, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(tr('transcriptSpeaker.title'),
                  style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            readOnly
                ? tr('transcriptSpeaker.readOnlySubtitle')
                : tr('transcriptSpeaker.editableSubtitle'),
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 12),
        ],
        SpeakerBar(chips: chips, showLabel: !showHeader),
        const SizedBox(height: 12),
        ...segments.map((raw) {
          if (raw is! Map) return const SizedBox.shrink();
          final label = raw['speaker']?.toString().trim() ?? '';
          final text = raw['text']?.toString() ?? '';
          final summary = summaries[label];
          final confirmed = summary?['confirmed_node'] as Map<String, dynamic>?;
          final name = confirmed?['name']?.toString() ?? label;
          final color = colorForSpeaker(label, colorOrder);

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: color,
                  ),
                ),
                const SizedBox(height: 3),
                Text(text, style: const TextStyle(fontSize: 14)),
              ],
            ),
          );
        }),
      ],
    );

    if (!wrapInCard) return content;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(padding: const EdgeInsets.all(14), child: content),
    );
  }

  /// Voice entries carry the profile id on the segment; text entries get it from
  /// the summary. Fall back so a chip stays tappable either way.
  String? _profileIdFromSegments(String label) {
    for (final raw in segments) {
      if (raw is! Map) continue;
      if ((raw['speaker']?.toString().trim() ?? '') != label) continue;
      final pid = raw['speaker_profile_id']?.toString();
      if (pid != null && pid.isNotEmpty) return pid;
    }
    return null;
  }
}
