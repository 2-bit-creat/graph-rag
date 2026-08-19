import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/quiz/cloze_quiz_card.dart';
import '../widgets/quiz/mcq_quiz_card.dart';
import '../widgets/quiz/quiz_audio_button.dart';
import '../widgets/quiz/quiz_result.dart';
import '../widgets/quiz/quiz_viewport_scope.dart';
import '../widgets/quiz/scramble_quiz_card.dart';
import '../widgets/measure_size.dart';
import '../widgets/scale_to_fit.dart';

/// Light "sheet" wrapper so the light-themed quiz/draft cards stay legible
/// inside the dark chat panel.
class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.child,
    this.title,
    this.progress,
    this.onClose,
    this.fillKeyboardViewport = false,
    this.onContentHeightChanged,
  });

  final Widget child;
  final String? title;

  /// Short "3 / 8" style position within the current quiz queue, shown next
  /// to the close button. Null hides it (e.g. while the queue is refilling).
  final String? progress;
  final VoidCallback? onClose;
  final bool fillKeyboardViewport;
  final ValueChanged<double>? onContentHeightChanged;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final availableHeight = QuizViewportScope.maybeHeightOf(context);
    final heightCompact = availableHeight != null && availableHeight < 280;
    final compact = MediaQuery.sizeOf(context).width < 600;
    // Do not gate the bounded layout on MediaQuery.viewInsets. Mobile web
    // browsers can resize the visual viewport before reporting an inset (or
    // keep reporting zero), which briefly leaves the card at natural height
    // and produces tiny 1–2 px overflows. QuizViewportScope is derived from
    // the parent's real constraints, so it is the authoritative measurement.
    final fillAvailableArea = fillKeyboardViewport && availableHeight != null;
    final useKeyboardCompactStyle = keyboardOpen && !fillKeyboardViewport;
    final topMargin = compact ? 2.0 : 4.0;
    final bottomMargin = fillAvailableArea
        ? 2.0
        : (heightCompact ? 2.0 : (keyboardOpen ? 4.0 : 8.0));
    // The surrounding quiz panel has already removed its header, padding, and
    // docked composer from this height. Use the remaining area as a maximum,
    // not a fixed height: short cards keep their natural size while long cards
    // scroll internally instead of shrinking text or overflowing.
    // CSS visualViewport values often land between logical pixels. Floor the
    // result and retain a small cross-browser gutter so rounding in Safari,
    // Chrome, different DPRs, and OS keyboard variants cannot exceed the
    // parent constraint.
    const viewportSafetyGutter = 4.0;
    final viewportHeight = fillAvailableArea
        ? (availableHeight - topMargin - bottomMargin - viewportSafetyGutter)
            .floorToDouble()
            .clamp(0.0, double.infinity)
        : null;
    final measuredChild = onContentHeightChanged == null
        ? child
        : MeasureSize(
            onChange: (size) => onContentHeightChanged!(size.height),
            child: child,
          );
    final header = title == null
        ? null
        : Row(
            children: [
              Expanded(
                child: Text(title!,
                    // w800 breaks CanvasKit's Korean fallback glyphs on web.
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              if (progress != null) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    progress!,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.shell.mutedText),
                  ),
                ),
              ],
              if (onClose != null)
                InkWell(
                  onTap: onClose,
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded, size: 18),
                  ),
                ),
            ],
          );
    final titleGap = title == null
        ? null
        : SizedBox(
            height: heightCompact
                ? 2
                : (useKeyboardCompactStyle ? 4 : (compact ? 6 : 10)));

    return Container(
      key: const ValueKey('quiz-card-shell'),
      constraints: viewportHeight == null
          ? null
          : BoxConstraints(maxHeight: viewportHeight),
      margin: EdgeInsets.fromLTRB(0, topMargin, 0, bottomMargin),
      padding: EdgeInsets.all(heightCompact
          ? 6
          : (useKeyboardCompactStyle ? 8 : (compact ? 10 : 14))),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.shell.panelBorder),
      ),
      child: viewportHeight == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (header != null) header,
                if (titleGap != null) titleGap,
                measuredChild,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (header != null) header,
                if (titleGap != null) titleGap,
                Flexible(
                  fit: FlexFit.loose,
                  // Shrink to fit before scrolling. Scrolling never hides the
                  // wrong thing by accident — it hides whatever is at the
                  // bottom, which for a quiz is the verdict, the hint, and the
                  // Korean gloss. A uniformly smaller card keeps all of it on
                  // screen at once, which is the trade worth making. The scroll
                  // view stays underneath for the questions too long to rescue
                  // without making the text unreadable.
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      primary: false,
                      child: ScaleToFit(
                        maxHeight: constraints.maxHeight,
                        child: measuredChild,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

// ── 대화 → 일기 정제 ──────────────────────────────────────────────────────────

class DistillDraftCard extends StatelessWidget {
  const DistillDraftCard({
    super.key,
    required this.sentences,
    required this.loading,
    required this.onToggle,
    required this.onSave,
    required this.onCancel,
  });

  final List<Map<String, dynamic>> sentences;
  final bool loading;
  final void Function(int index, bool included) onToggle;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (loading && sentences.isEmpty) {
      return _CardShell(
        title: tr('chat.distillCardTitle'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text(tr('chat.distillProcessing'),
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }

    final includedCount = sentences.where((s) => s['included'] == true).length;
    return _CardShell(
      title: tr('chat.distillCardTitle'),
      onClose: onCancel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sentences.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(tr('chat.distillEmpty'),
                  style: const TextStyle(fontSize: 13)),
            )
          else
            for (var i = 0; i < sentences.length; i++)
              _SentenceRow(
                data: sentences[i],
                onChanged: (v) => onToggle(i, v),
              ),
          const SizedBox(height: 6),
          Text(
            tr('chat.distillEditHint'),
            style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (loading) ...[
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              TextButton(onPressed: onCancel, child: Text(tr('common.cancel'))),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: includedCount > 0 ? onSave : null,
                icon: const Icon(Icons.auto_stories_rounded, size: 16),
                label: Text(tr('chat.saveAsJournal', {'count': includedCount})),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SentenceRow extends StatelessWidget {
  const _SentenceRow({required this.data, required this.onChanged});

  final Map<String, dynamic> data;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final included = data['included'] == true;
    final duplicate = data['duplicate'] == true;
    final matched = (data['matched_statement'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Checkbox(
              value: included,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((data['text'] ?? '').toString(),
                    style: const TextStyle(fontSize: 13.5, height: 1.35)),
                if (duplicate) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 12, color: AppColors.textMuted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          matched.isEmpty
                              ? tr('chat.alreadyInGraph')
                              : tr('chat.alreadyInGraphMatched',
                                  {'matched': matched}),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: AppColors.textMuted),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 작문 퀴즈 (composition drill) ─────────────────────────────────────────────

class CompositionDrillCard extends StatefulWidget {
  const CompositionDrillCard({
    super.key,
    required this.quiz,
    required this.feedback,
    required this.busy,
    required this.onNext,
    required this.onExit,
    this.progress,
  });

  final Map<String, dynamic> quiz;
  final Map<String, dynamic>? feedback;
  final bool busy;
  final VoidCallback onNext;
  final VoidCallback onExit;

  /// Short "3 / 8" style position within the current quiz queue.
  final String? progress;

  @override
  State<CompositionDrillCard> createState() => _CompositionDrillCardState();
}

class _CompositionDrillCardState extends State<CompositionDrillCard> {
  // A fresh card is a new widget instance (the parent keys it by quiz id),
  // so this always starts hidden for a new sentence.
  bool _hintsRevealed = false;

  @override
  Widget build(BuildContext context) {
    final qd =
        (widget.quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final prompt =
        (widget.quiz['question_native'] ?? widget.quiz['question_ko'])
                ?.toString() ??
            '';
    final glossary = (qd['glossary'] as List?) ?? [];
    final hints = ((qd['hints'] as List?) ?? [])
        .whereType<Map>()
        .where((h) => (h['note']?.toString() ?? '').isNotEmpty)
        .toList();
    final fb = widget.feedback;

    return _CardShell(
      title: tr('chat.compositionQuizTitle'),
      progress: widget.progress,
      onClose: widget.onExit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(prompt,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (glossary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in glossary.take(6))
                  Chip(
                    label: Text(
                      g is Map
                          ? '${g['term'] ?? g['expression'] ?? ''}'
                          : g.toString(),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          if (hints.isNotEmpty && fb == null) ...[
            const SizedBox(height: 8),
            if (!_hintsRevealed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _hintsRevealed = true),
                  icon: const Icon(Icons.lightbulb_outline_rounded, size: 16),
                  label: Text(tr('chat.compositionHintsShow')),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final h in hints.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.lightbulb_outline_rounded,
                              size: 14, color: AppColors.textMuted),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              [
                                h['note']?.toString() ?? '',
                                if ((h['snippet']?.toString() ?? '').isNotEmpty)
                                  '"${h['snippet']}"',
                              ].where((v) => v.isNotEmpty).join('  '),
                              style: TextStyle(
                                  fontSize: 12.5, color: AppColors.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
          ],
          const SizedBox(height: 10),
          if (fb == null)
            Row(
              children: [
                if (widget.busy) ...[
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(tr('chat.grading'),
                      style: const TextStyle(fontSize: 12.5)),
                ] else
                  Expanded(
                    child: Text(tr('chat.compositionHint'),
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.textMuted)),
                  ),
              ],
            )
          else
            _FeedbackBody(feedback: fb),
          if (fb != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                // The scramble twin drills the same sentence, so its clip is
                // handed down here (see _pair_scrambles_with_compositions)
                // instead of synthesizing the identical audio twice. Only
                // after grading — hearing it earlier is the answer.
                if ((widget.quiz['audio_url']?.toString().isNotEmpty ?? false))
                  QuizAudioButton(
                    audioUrl: widget.quiz['audio_url'].toString(),
                    iconSize: 20,
                  ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: widget.onNext,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                  label: Text(tr('chat.nextSentence')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FeedbackBody extends StatelessWidget {
  const _FeedbackBody({required this.feedback});

  final Map<String, dynamic> feedback;

  @override
  Widget build(BuildContext context) {
    final verdictLabel = feedback['verdict_label']?.toString() ?? '';
    final naturalVersions = (feedback['natural_versions'] as List?) ?? [];
    final translationNotes = (feedback['translation_notes'] as List?) ?? [];
    final saveSuggestions = (feedback['save_suggestions'] as List?) ?? [];
    final attemptNote = feedback['attempt_note']?.toString() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (verdictLabel.isNotEmpty)
          Text(verdictLabel,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent)),
        if (attemptNote.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(attemptNote,
              style: const TextStyle(fontSize: 12.5, height: 1.35)),
        ],
        if (saveSuggestions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(tr('chat.usefulExpressions'),
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          for (final item in saveSuggestions)
            if (item is Map &&
                (item['expression'] ?? '').toString().trim().isNotEmpty)
              _SaveSuggestionRow(
                expression: item['expression'].toString().trim(),
                meaning: item['meaning']?.toString() ?? '',
              ),
        ],
        if (naturalVersions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(tr('chat.alsoSaySo'),
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          for (final v in naturalVersions)
            _NaturalRow(
              text: v is Map ? (v['text'] ?? '').toString() : v.toString(),
            ),
        ],
        if (translationNotes.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final item in translationNotes)
            if (item is Map &&
                (item['note'] ?? '').toString().trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 14, color: AppColors.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(item['note'].toString(),
                          style: TextStyle(
                              fontSize: 12.5, color: AppColors.textMuted)),
                    ),
                  ],
                ),
              ),
        ],
      ],
    );
  }
}

class _NaturalRow extends StatelessWidget {
  const _NaturalRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(text, style: const TextStyle(fontSize: 13, height: 1.35)),
    );
  }
}

class _SaveSuggestionRow extends StatelessWidget {
  const _SaveSuggestionRow({
    required this.expression,
    required this.meaning,
  });

  final String expression;
  final String meaning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(expression,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          if (meaning.trim().isNotEmpty)
            Text(meaning,
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

// ── Sentence quiz cards (scramble now, legacy cloze still readable) ──────────

class WordQuizCard extends StatefulWidget {
  const WordQuizCard({
    super.key,
    required this.quiz,
    required this.onSubmit,
    required this.onNext,
    required this.onExit,
    this.onHint,
    this.externalResult,
    this.clozeSolved = false,
    this.clozeCompletedWords = const [],
    this.clozeLiveDraft = '',
    this.onClozeHintRequested,
    this.onClozeInputTap,
    this.clozeCardKey,
    this.onContentHeightChanged,
    this.progress,
  });

  final Map<String, dynamic> quiz;

  /// Short "3 / 8" style position within the current quiz queue.
  final String? progress;

  /// Grades the answer and returns the raw result (or null on error).
  final Future<Map<String, dynamic>?> Function({
    String? answer,
    List<String>? order,
    int? selectedIndex,
    int hintLevel,
  }) onSubmit;

  /// Scramble order hint — see ScrambleQuizCard.onHint.
  final Future<Map<String, dynamic>?> Function(int hintLevel)? onHint;
  final VoidCallback onNext;
  final VoidCallback onExit;
  final Map<String, dynamic>? externalResult;
  final bool clozeSolved;

  /// Words already matched live from the composer, in order (see
  /// ChatSessionController.updateClozeDraft), and the in-progress text for
  /// the word currently being typed.
  final List<String> clozeCompletedWords;
  final String clozeLiveDraft;

  /// Fired after the hint or reveal-answer buttons are tapped — clears a
  /// stale mismatched attempt from the shared composer and returns keyboard
  /// focus to it (those buttons otherwise steal focus with nowhere for it to
  /// go back to, breaking further typing).
  final VoidCallback? onClozeHintRequested;
  final VoidCallback? onClozeInputTap;
  final GlobalKey<ClozeQuizCardState>? clozeCardKey;
  final ValueChanged<double>? onContentHeightChanged;

  @override
  State<WordQuizCard> createState() => _WordQuizCardState();
}

class _WordQuizCardState extends State<WordQuizCard> {
  Map<String, dynamic>? _result;
  bool _solved = false;
  final _audioKey = GlobalKey<QuizAudioButtonState>();

  /// mcq / scramble: single-shot grading — the correct choice/order isn't
  /// known client-side, so there's no way to let the learner retry locally.
  /// Right or wrong, the attempt is final and "다음 문제" unlocks immediately.
  Future<void> _grade({
    List<String>? order,
    int? selectedIndex,
    int hintLevel = 0,
  }) async {
    final res = await widget.onSubmit(
        order: order, selectedIndex: selectedIndex, hintLevel: hintLevel);
    if (res == null || !mounted) return;
    setState(() => _result = res);
    // A scramble's clip only exists in the *graded* payload (the session
    // withholds it so the audio cannot give the word order away), and that
    // payload reaches the audio button one frame later. Playing right here
    // would hit a button that still has a null url and silently do nothing.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _audioKey.currentState?.play(showError: false),
    );
  }

  /// cloze: first attempt goes to the backend; the card itself then allows
  /// the learner to retype the revealed answer until it matches, without
  /// hitting the backend again (a second submit would double-grade the SM2
  /// review).
  Future<bool> _gradeCloze(String answer) async {
    final res = await widget.onSubmit(answer: answer);
    if (res == null) return false;
    if (mounted) setState(() => _result = res);
    return quizResultIsCorrect(res);
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.quiz['quiz_type']?.toString() ?? 'scramble';
    final qd =
        (widget.quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {};
    final effectiveResult = widget.externalResult ?? _result;
    final answered = effectiveResult != null;
    final audioUrl =
        widget.quiz['audio_url']?.toString() ?? qd['audio_url']?.toString();
    final answerAudioUrl = widget.quiz['answer_audio_url']?.toString() ??
        qd['answer_audio_url']?.toString();
    final question =
        (widget.quiz['question_native'] ?? widget.quiz['question_ko'])
                ?.toString() ??
            '';

    if (type == 'composition') {
      return CompositionDrillCard(
        quiz: widget.quiz,
        feedback: widget.externalResult,
        busy: false,
        onNext: widget.onNext,
        onExit: widget.onExit,
        progress: widget.progress,
      );
    }

    Widget card;
    switch (type) {
      case 'scramble':
        card = ScrambleQuizCard(
          quizData: qd,
          enabled: !answered,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          questionKo: question,
          onHint: widget.onHint,
          onSubmit: (order, hintLevel) =>
              _grade(order: order, hintLevel: hintLevel),
        );
        break;
      case 'mcq_nuance':
      case 'mcq':
        card = McqQuizCard(
          quizData: qd,
          enabled: !answered,
          audioUrl: audioUrl,
          audioButtonKey: _audioKey,
          onSubmit: (i) => _grade(selectedIndex: i),
        );
        break;
      case 'cloze':
      default:
        card = ClozeQuizCard(
          key: widget.clozeCardKey,
          quizData: qd,
          audioUrl: audioUrl,
          answerAudioUrl: answerAudioUrl,
          audioButtonKey: _audioKey,
          onSubmit: _gradeCloze,
          onSolved: () => setState(() => _solved = true),
          externalInput: true,
          externalResult: widget.externalResult,
          externalSolved: widget.clozeSolved,
          externalCompletedWords: widget.clozeCompletedWords,
          externalLiveDraft: widget.clozeLiveDraft,
          onHintRequested: widget.onClozeHintRequested,
          onExternalInputTap: widget.onClozeInputTap,
        );
    }

    // cloze retries locally until correct; mcq/scramble grade once and move on
    // regardless of the outcome (see _grade above).
    final isCloze = type == 'cloze';
    final clozeComplete = widget.clozeSolved || _solved;
    final isCorrect =
        isCloze ? clozeComplete : quizResultIsCorrect(effectiveResult);
    final readyForNext = isCloze ? clozeComplete : answered;

    return _CardShell(
      title: tr('chat.wordQuizTitle'),
      progress: widget.progress,
      onClose: widget.onExit,
      fillKeyboardViewport: true,
      onContentHeightChanged: widget.onContentHeightChanged,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          card,
          if (isCloze && readyForNext) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: widget.onNext,
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(tr('chat.nextQuestion')),
            ),
          ] else if (answered && !isCloze) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  isCorrect
                      ? Icons.check_circle_rounded
                      : (isCloze
                          ? Icons.edit_note_rounded
                          : Icons.cancel_rounded),
                  size: 18,
                  color: isCorrect
                      ? Colors.green
                      : (isCloze ? Colors.orange : Colors.redAccent),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isCorrect
                        ? tr('chat.correctAnswer')
                        : (isCloze
                            ? tr('chat.typeAnswerToComplete')
                            : tr('chat.incorrectAnswer')),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                if (readyForNext)
                  FilledButton.icon(
                    onPressed: widget.onNext,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                    label: Text(tr('chat.nextQuestion')),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
