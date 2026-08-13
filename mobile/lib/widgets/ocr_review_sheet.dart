import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'mention_editor_core.dart'
    show CaretStableField, NoTextScaling, colorForSpeaker, textScaleBakedIn;

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
      // Without this the sheet is capped at half the screen, which on a phone
      // with the keyboard up leaves the text field a couple of lines tall.
      constraints: const BoxConstraints(maxWidth: 640),
      useSafeArea: true,
      builder: (_) => OcrReviewSheet(
        initialText: initialText,
        speakers: speakers,
      ),
    );
  }

  @override
  State<OcrReviewSheet> createState() => _OcrReviewSheetState();
}

/// One recognised speaker, in the color it will wear in the composer.
class _SpeakerPill extends StatelessWidget {
  const _SpeakerPill({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        name == '나' ? selfSpeakerLabel : name,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
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
    //
    // Padding deflates the constraints it passes down, so subtracting the inset
    // here is also what bounds the Column below — the field is `Flexible`, and
    // takes whatever the fixed rows leave rather than a fraction of the *full*
    // screen. Sizing it at 42% of the screen regardless of the keyboard is what
    // made this sheet overflow by ~200px the moment the keyboard came up, with
    // the text under the fold unreachable because nothing here scrolled.
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final keyboardOpen = inset > 0;
    // What is actually left to lay out in, once the keyboard and the sheet's
    // own bottom gap are gone. Every optional row below is sized against this
    // rather than against the screen, so a short phone under a tall keyboard
    // sheds chrome instead of overflowing.
    final available =
        MediaQuery.sizeOf(context).height - inset - AppSpacing.lg;
    final roomy = available > 420;
    // Landscape, a split-screen browser, or a keyboard with a suggestion strip
    // on a small phone. The title is the first thing to go: the drag handle
    // above it already reads as a sheet, and the field is what the learner came
    // for.
    final tiny = available < 260;
    final pillCap = roomy ? 108.0 : (available * 0.14).clamp(24.0, 64.0);

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
          if (!tiny) ...[
            Text(tr('ocr.reviewTitle'), style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
          ],
          // The speakers the photo produced, in the colors they will carry in
          // the composer and on the graph. Text alone ("화자 2명 인식: 제니, 나")
          // makes the reader match names to "@제니:" prefixes by eye; the color
          // is the thread that survives into the composer badges, so showing it
          // here is what makes a wrong split obvious at a glance.
          if (widget.speakers.isNotEmpty) ...[
            // A group chat screenshot can name a dozen people. Cap the rail and
            // let it scroll rather than let it eat the field's height.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: pillCap),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final name in widget.speakers)
                      _SpeakerPill(
                        name: name,
                        color: colorForSpeaker(name, widget.speakers),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          // Unconditional, unlike the old confidence-gated warning. A vision
          // model returns no calibrated per-line score to gate on, and its own
          // stated confidence is not that measurement — so the honest UI says
          // "check this" every time rather than implying a number it does not
          // have.
          //
          // It does step aside once the keyboard is up: by then it has been
          // read, and the room it occupies is room the text being corrected
          // needs more.
          if (!keyboardOpen && roomy) Container(
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
          // Flexible, not a fixed fraction: it grows to fill the sheet when
          // there is room and shrinks under the keyboard instead of pushing the
          // buttons off the bottom.
          //
          // The scrolling belongs to [CaretStableField], NOT to the field. A
          // bounded height plus `maxLines: null` does keep a long transcript
          // reachable, but it also gives `EditableText` its own scroll viewport
          // — and `_scheduleShowCaretOnScreen` drags that viewport to the caret
          // on every focus gain and every keyboard-inset change. On web the
          // tapped offset arrives from the hidden DOM input a frame *after*
          // focus, so the reveal still saw the OLD caret and scrolled back to
          // it: tapping a line high up in a photographed conversation looked
          // ignored, then jumped. This is the same bug the chat and journal
          // composers fought; the fix is the same three pieces, and all three
          // are load-bearing.
          //
          // The fill and border moved out to this box so they stay put instead
          // of scrolling away with the text — the field inside is now taller
          // than what is visible.
          Flexible(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                border: Border.all(color: scheme.outline),
              ),
              child: CaretStableField(
                maxHeight: MediaQuery.sizeOf(context).height * 0.42,
                // Scale baked into the style, scaling switched off below it:
                // the canvas paints with `MediaQuery.textScalerOf`, while the
                // hidden DOM input that resolves a tap into an offset gets the
                // raw `style.fontSize`. At any scale but 1.0 the two disagree
                // and the caret lands to the right of the press, further right
                // the longer the line.
                child: NoTextScaling(
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: false,
                    autofocus: false,
                    keyboardType: TextInputType.multiline,
                    style: textScaleBakedIn(
                      context,
                      (theme.textTheme.bodyLarge ??
                              const TextStyle(fontSize: 16))
                          .copyWith(height: 1.5),
                    ),
                    decoration: InputDecoration(
                      hintText: tr('ocr.emptyResultHint'),
                      filled: false,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: keyboardOpen ? AppSpacing.md : AppSpacing.lg),
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
