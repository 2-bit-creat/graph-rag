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
    this.meanConfidence,
    this.lowConfidence = false,
  });

  final String initialText;
  final double? meanConfidence;
  final bool lowConfidence;

  /// Returns the confirmed text, or null when dismissed.
  static Future<String?> show(
    BuildContext context, {
    required String initialText,
    double? meanConfidence,
    bool lowConfidence = false,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => OcrReviewSheet(
        initialText: initialText,
        meanConfidence: meanConfidence,
        lowConfidence: lowConfidence,
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
              if (widget.meanConfidence != null)
                Text(
                  tr('ocr.confidenceLabel', {
                    'percent': widget.meanConfidence!.toStringAsFixed(0),
                  }),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (widget.lowConfidence)
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
                      tr('ocr.lowConfidenceWarning'),
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
