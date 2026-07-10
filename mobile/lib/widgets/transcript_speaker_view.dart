import 'package:flutter/material.dart';

import 'speaker_identity_sheet.dart';
import ../theme/app_theme.dart

/// STT segments with tappable speaker chips — opens identity confirmation sheet.
class TranscriptSpeakerView extends StatelessWidget {
  const TranscriptSpeakerView({
    super.key,
    required this.entryId,
    required this.segments,
    required this.speakerSummaries,
    this.onConfirmed,
    this.readOnly = false,
  });

  final String entryId;
  final List<dynamic> segments;
  final List<dynamic> speakerSummaries;
  final Future<void> Function()? onConfirmed;
  final bool readOnly;

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

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.record_voice_over, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('화자별 스크립트', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              readOnly
                  ? '화자별 STT 결과 (읽기 전용 — 일기 쓰기에서 화자를 지정하세요)'
                  : '목소리가 비슷하면 이름이 추천됩니다. 탭해서 확인하거나 수정하세요.',
              style: TextStyle(fontSize: 12, color: context.mutedText),
            ),
            const SizedBox(height: 12),
            ...segments.map((raw) {
              if (raw is! Map) return const SizedBox.shrink();
              final label = raw['speaker']?.toString() ?? 'Speaker';
              final text = raw['text']?.toString() ?? '';
              final summary = summaries[label];
              final pid = raw['speaker_profile_id']?.toString()
                  ?? summary?['speaker_profile_id']?.toString();
              final confirmed = summary?['confirmed_node'] as Map<String, dynamic>?;
              final suggested = summary?['suggested_node'] as Map<String, dynamic>?;
              final needsPick = summary?['needs_confirmation'] == true;
              final isConfirmed = confirmed != null && !needsPick;
              final hasSuggestion = suggested != null && needsPick;
              final displayName = confirmed?['name']?.toString()
                  ?? suggested?['name']?.toString();

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (pid != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 8),
                        child: ActionChip(
                          avatar: Icon(
                            isConfirmed
                                ? Icons.person
                                : hasSuggestion
                                    ? Icons.auto_awesome
                                    : Icons.help_outline,
                            size: 16,
                            color: isConfirmed
                                ? Colors.green[700]
                                : hasSuggestion
                                    ? Colors.orange[800]
                                    : Colors.orange[800],
                          ),
                          label: Text(
                            hasSuggestion ? '${displayName ?? label} (추천)' : (displayName ?? label),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isConfirmed ? null : Colors.orange[900],
                            ),
                          ),
                          backgroundColor: isConfirmed
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.orange.withValues(alpha: 0.12),
                          onPressed: readOnly ? null : () => _openSheet(context, label, pid),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 4, right: 8),
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(text, style: const TextStyle(fontSize: 14)),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
