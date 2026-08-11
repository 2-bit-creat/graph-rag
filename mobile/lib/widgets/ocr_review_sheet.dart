import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Review and correct OCR output before it becomes graph input.
///
/// A dedicated sheet rather than dropping straight into the docked composer:
/// a photographed page is many lines long, and the composer pill is sized for a
/// sentence. This is also the human-in-the-loop step that lets OCR feed
/// `/kg/extract` at all — recognition errors get fixed here, before any claim
/// is drafted from the text.
class OcrReviewSheet extends StatefulWidget {
  const OcrReviewSheet({
    super.key,
    required this.initialText,
    this.speakers = const [],
  });

  final String initialText;

  /// Speakers the vision model found, when the photo was a conversation. Shown
  /// so the split is visible *here* — once this text reaches the composer the
  /// names become "@배지" mentions, and a wrong one is far cheaper to fix now.
  final List<String> speakers;

  /// Returns the confirmed text, or null when dismissed.
  static Future<String?> show(
    BuildContext context, {
    required String initialText,
    List<String> speakers = const [],
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => OcrReviewSheet(
        initialText: initialText,
        speakers: speakers,
      ),
    );
  }

  @override
  State<OcrReviewSheet> createState() => _OcrReviewSheetState();
}

class _OcrReviewSheetState extends State<OcrReviewSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Leave room for the keyboard: the field is the whole point of the sheet.
    final inset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.pageH,
        0,
        AppSpacing.pageH,
        inset + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(tr('ocr.reviewTitle'), style: theme.textTheme.titleMedium),
              const Spacer(),
              if (widget.speakers.isNotEmpty)
                Text(
                  tr('ocr.speakersLabel', {
                    'count': '${widget.speakers.length}',
                    'names': widget.speakers.join(', '),
                  }),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Unconditional, unlike the old confidence-gated warning. A vision
          // model returns no calibrated per-line score to gate on, and its own
          // stated confidence is not that measurement — so the honest UI says
          // "check this" every time rather than implying a number it does not
          // have.
          Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.accentWarm.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: AppColors.accentWarm,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    tr('ocr.checkHint'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.42,
            ),
            child: TextField(
              controller: _controller,
              maxLines: null,
              expands: false,
              autofocus: false,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: tr('ocr.emptyResultHint'),
                filled: true,
                fillColor: scheme.surfaceContainerLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('ocr.cancel')),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 2,
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) => FilledButton(
                    // Confirming empty text would drop the learner into a
                    // composer with nothing in it and no explanation.
                    onPressed: value.text.trim().isEmpty
                        ? null
                        : () => Navigator.pop(context, value.text.trim()),
                    child: Text(tr('ocr.useText')),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
