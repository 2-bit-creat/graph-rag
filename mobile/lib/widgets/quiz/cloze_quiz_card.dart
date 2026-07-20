import 'package:flutter/material.dart';

import 'quiz_audio_button.dart';

class ClozeQuizCard extends StatefulWidget {
  const ClozeQuizCard({
    super.key,
    required this.quizData,
    required this.onSubmit,
    required this.onSolved,
    this.audioUrl,
    this.audioButtonKey,
    this.externalInput = false,
    this.externalResult,
    this.externalSolved = false,
    this.externalCompletedWords = const [],
    this.externalLiveDraft = '',
    this.onHintRequested,
  });

  final Map<String, dynamic> quizData;
  final Future<bool> Function(String answer) onSubmit;
  final VoidCallback onSolved;
  final String? audioUrl;
  final GlobalKey<QuizAudioButtonState>? audioButtonKey;
  final bool externalInput;
  final Map<String, dynamic>? externalResult;
  final bool externalSolved;

  /// externalInput only: words matched live so far (in order), and the
  /// in-progress text for the word currently being typed in the composer.
  final List<String> externalCompletedWords;
  final String externalLiveDraft;

  /// externalInput only: fired after the hint or "정답 보기" buttons are
  /// tapped — both steal keyboard focus from the shared chat composer, which
  /// is the only place this mode actually accepts typing. The callback both
  /// clears a stale mismatched attempt (so a hint isn't hidden behind it) and
  /// returns focus to the composer so typing keeps working afterward.
  final VoidCallback? onHintRequested;

  @override
  State<ClozeQuizCard> createState() => _ClozeQuizCardState();
}

class _ClozeQuizCardState extends State<ClozeQuizCard> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _submitting = false;
  // Hint is scoped to whichever box is currently active: 0 = none,
  // 1 = first letter, 2 = the whole word (still has to be typed in).
  // Reset in didUpdateWidget whenever the active box advances.
  int _hintLevel = 0;
  bool _answerRevealed = false;
  bool? _graded;
  bool _solved = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ClozeQuizCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The live word-by-word matcher (ChatSessionController.updateClozeDraft)
    // flips externalSolved the instant every word matches, with no button
    // press involved — play the same confirmation sound the button-driven
    // (non-external) path plays on a correct answer.
    if (widget.externalInput && !oldWidget.externalSolved && widget.externalSolved) {
      widget.audioButtonKey?.currentState?.play(showError: false);
    }
    if (widget.externalInput &&
        oldWidget.externalCompletedWords.length !=
            widget.externalCompletedWords.length) {
      // Moved to a new blank — hints don't carry over from the last one.
      _hintLevel = 0;
    }
  }

  bool? get _effectiveGrade => widget.externalInput
      ? (widget.externalSolved
          ? true
          : widget.externalResult?['is_correct'] as bool?)
      : _graded;

  bool get _effectiveSolved =>
      widget.externalInput ? widget.externalSolved : _solved;

  // Revealing the blank is either an explicit "정답 보기" tap or having solved
  // it correctly — a wrong attempt must never auto-reveal the answer, so the
  // learner keeps guessing (with hints) instead of just being handed it.
  bool get _effectiveAnswerRevealed => _answerRevealed || _effectiveSolved;

  bool get _showAudio => _effectiveGrade != null || _effectiveAnswerRevealed;

  String get _blank => (widget.quizData['blank']?.toString() ??
          (widget.quizData['accepted_answers'] as List?)?.first?.toString() ??
          '')
      .trim()
      .toLowerCase();

  /// One box per word, sized off that word's letter count, so the learner
  /// can see how many words the answer has (and roughly how long each is)
  /// before typing anything — mirrors 말해보카's multi-slot blank. A word
  /// already matched (live, externalInput mode only) turns green; the word
  /// currently being typed shows the live draft text plus a blinking cursor
  /// and grows if the attempt runs longer than the real word.
  Widget _wordSlot({
    required String display,
    required String targetWord,
    required bool completed,
    required bool active,
    required ColorScheme scheme,
    String? hintText,
  }) {
    final sizingLength =
        active && display.length > targetWord.length ? display.length : targetWord.length;
    final width = (sizingLength * 11.0 + 20.0).clamp(36.0, 200.0);
    final showHint = active && display.isEmpty && hintText != null;
    return InkWell(
      onTap: widget.externalInput ? null : () => _focusNode.requestFocus(),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: width,
        height: 32,
        margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
        padding: active ? const EdgeInsets.only(left: 8) : EdgeInsets.zero,
        // The active (currently-typed) box aligns its content — cursor,
        // hint letter, typed text — to the left like a real text caret,
        // not centered; completed/upcoming boxes keep a centered look.
        alignment: active ? Alignment.centerLeft : Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: completed ? 0.10 : 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: scheme.primary.withValues(alpha: completed ? 0.2 : 0.36),
          ),
        ),
        child: display.isEmpty && !active
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (display.isNotEmpty)
                    Text(
                      display,
                      style: TextStyle(
                        color: completed
                            ? const Color(0xFF22C55E)
                            : scheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    )
                  else if (showHint)
                    Text(
                      hintText,
                      style: TextStyle(
                        color: scheme.primary.withValues(alpha: 0.45),
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                  if (active) ...[
                    if (display.isNotEmpty || showHint) const SizedBox(width: 2),
                    _BlinkingCursor(color: scheme.primary, height: 18),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildClozeSentence(String prompt, String blank) {
    final match = RegExp(r'_{3,}').firstMatch(prompt);
    if (match == null) {
      return Text(prompt,
          style:
              Theme.of(context).textTheme.titleLarge?.copyWith(height: 1.42));
    }
    final scheme = Theme.of(context).colorScheme;
    final visible = _effectiveAnswerRevealed;
    final baseStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
          height: 1.42,
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        );
    final maxBlankWidth =
        (MediaQuery.sizeOf(context).width * 0.68).clamp(180.0, 340.0);
    final words = blank.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

    final List<InlineSpan> blankSpans;
    if (visible) {
      blankSpans = [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            constraints: BoxConstraints(
              minWidth: 132,
              maxWidth: maxBlankWidth,
            ),
            margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.5)),
            ),
            child: Text(
              blank,
              softWrap: true,
              textAlign: TextAlign.center,
              style: baseStyle?.copyWith(color: scheme.primary, height: 1.28),
            ),
          ),
        ),
      ];
    } else if (widget.externalInput) {
      // Composer keystrokes are matched word-by-word live (see
      // ChatSessionController.updateClozeDraft) — show real progress.
      final completedWords = widget.externalCompletedWords;
      final liveDraft = widget.externalLiveDraft;
      final activeIndex = completedWords.length;
      blankSpans = [
        for (var i = 0; i < words.length; i++) ...[
          if (i > 0) const TextSpan(text: ' '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _wordSlot(
              display: i < activeIndex
                  ? completedWords[i]
                  : (i == activeIndex ? liveDraft : ''),
              targetWord: words[i],
              completed: i < activeIndex,
              active: i == activeIndex,
              scheme: scheme,
              hintText: i == activeIndex && words[i].isNotEmpty
                  ? (_hintLevel == 1
                      ? words[i][0]
                      : (_hintLevel >= 2 ? words[i] : null))
                  : null,
            ),
          ),
        ],
      ];
    } else {
      // Internal mode types the whole phrase into the field below and
      // submits it at once — just show each word's shape up front.
      blankSpans = [
        for (var i = 0; i < words.length; i++) ...[
          if (i > 0) const TextSpan(text: ' '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _wordSlot(
              display: '',
              targetWord: words[i],
              completed: false,
              active: false,
              scheme: scheme,
            ),
          ),
        ],
      ];
    }

    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: prompt.substring(0, match.start)),
          ...blankSpans,
          TextSpan(text: prompt.substring(match.end)),
        ],
      ),
    );
  }

  bool _isAnswerOnlyContext(String raw) {
    final plain = raw
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
    if (plain.isEmpty) return true;
    final accepted = (widget.quizData['accepted_answers'] as List?)
            ?.map((e) => e.toString().trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        <String>{};
    return plain == _blank || accepted.contains(plain);
  }

  void _revealHint() {
    setState(() => _hintLevel = (_hintLevel + 1).clamp(0, 2).toInt());
    // Tapping this button steals keyboard focus from the chat composer below —
    // the only place externalInput mode actually types. Always ping the
    // callback (which clears a stale mismatched attempt AND returns focus to
    // the composer) so typing keeps working after the tap, not just when a
    // draft happened to be sitting in the box.
    if (widget.externalInput) {
      widget.onHintRequested?.call();
    }
  }

  void _revealAnswer({bool fillField = false}) {
    final blank = _blank;
    setState(() {
      _answerRevealed = true;
      if (fillField && blank.isNotEmpty) _controller.text = blank;
    });
    widget.audioButtonKey?.currentState?.play(showError: false);
    // Same focus-stealing issue as the hint button — hand focus back to the
    // composer so the learner can retype the revealed answer immediately.
    if (widget.externalInput) {
      widget.onHintRequested?.call();
    }
  }

  Future<void> _submit() async {
    if (_submitting || _solved) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    if (_graded == null) {
      setState(() => _submitting = true);
      bool correct = false;
      try {
        correct = await widget.onSubmit(text);
      } finally {
        if (mounted) setState(() => _submitting = false);
      }
      if (!mounted) return;
      setState(() {
        _graded = correct;
        _solved = correct;
        // Only reveal on a correct answer — a wrong first try should still
        // let the learner use hints/retype rather than being handed it.
        if (correct) {
          _answerRevealed = true;
        } else {
          _controller.clear();
        }
      });
      widget.audioButtonKey?.currentState?.play(showError: false);
      if (correct) widget.onSolved();
      return;
    }

    if (text.toLowerCase() == _blank) {
      setState(() => _solved = true);
      widget.onSolved();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('오답이에요. 힌트를 참고하거나 정답 보기를 눌러 확인해 보세요.'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Widget _buildContextKo(String raw) {
    final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final spanRe = RegExp(
      "<span\\s+color=['\"]#FFA500['\"][^>]*>(.*?)</span>",
      caseSensitive: false,
      dotAll: true,
    );
    final match = spanRe.firstMatch(raw);
    if (match == null) {
      return Text(raw,
          style: TextStyle(fontSize: 14, height: 1.45, color: mutedColor));
    }
    // Older cards used a full-sentence orange span when target alignment was
    // missing. Never present that fallback as if the whole translation were
    // the answer. Rebuild the highlight from stored target_ko when possible.
    if (match.start == 0 && match.end == raw.length) {
      final sentenceKo =
          (widget.quizData['sentence_ko']?.toString() ?? match.group(1) ?? '')
              .trim();
      final targetKo = (widget.quizData['target_ko']?.toString() ?? '').trim();
      if (targetKo.isEmpty || !sentenceKo.contains(targetKo)) {
        return Text(sentenceKo,
            style: TextStyle(fontSize: 14, height: 1.45, color: mutedColor));
      }
      final start = sentenceKo.indexOf(targetKo);
      return RichText(
        text: TextSpan(
          style: TextStyle(fontSize: 14, height: 1.45, color: mutedColor),
          children: [
            TextSpan(text: sentenceKo.substring(0, start)),
            TextSpan(
              text: targetKo,
              style: const TextStyle(
                color: Color(0xFFFFB020),
                fontWeight: FontWeight.w800,
              ),
            ),
            TextSpan(text: sentenceKo.substring(start + targetKo.length)),
          ],
        ),
      );
    }
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 14, height: 1.45, color: mutedColor),
        children: [
          TextSpan(text: raw.substring(0, match.start)),
          TextSpan(
            text: match.group(1) ?? '',
            style: const TextStyle(
              color: Color(0xFFFFB020),
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: raw.substring(match.end)),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.45)),
      ),
    );
  }

  Widget _answerPanel({required String blank, required bool wrongFirstTry}) {
    final scheme = Theme.of(context).colorScheme;
    final isCorrect = _effectiveGrade == true;
    final color = isCorrect
        ? const Color(0xFF22C55E)
        : (wrongFirstTry ? const Color(0xFFFF6B6B) : scheme.primary);
    final label = isCorrect ? '정답' : (wrongFirstTry ? '정답 확인' : '정답 보기');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  isCorrect
                      ? Icons.check_circle_rounded
                      : Icons.lightbulb_outline_rounded,
                  size: 18,
                  color: color),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  blank,
                  softWrap: true,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w800,
                        height: 1.35,
                      ),
                ),
              ),
              if (_showAudio) ...[
                const SizedBox(width: 8),
                QuizAudioButton(
                  key: widget.audioButtonKey,
                  audioUrl: widget.audioUrl,
                  iconSize: 18,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final prompt = widget.quizData['prompt_en']?.toString() ?? '';
    final contextKo = widget.quizData['context_ko']?.toString() ?? '';
    final hintKo = widget.quizData['hint_ko']?.toString() ?? '';
    final blank = _blank;
    final wrongFirstTry = _effectiveGrade == false && !_effectiveSolved;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildClozeSentence(prompt, blank),
        if (contextKo.isNotEmpty && !_isAnswerOnlyContext(contextKo)) ...[
          const SizedBox(height: 14),
          Text(
            '문장 뜻',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 4),
          _buildContextKo(contextKo),
        ],
        if (_effectiveAnswerRevealed && blank.isNotEmpty) ...[
          const SizedBox(height: 14),
          _answerPanel(blank: blank, wrongFirstTry: wrongFirstTry),
        ],
        if (wrongFirstTry) ...[
          const SizedBox(height: 7),
          Text(
            _effectiveAnswerRevealed
                ? (widget.externalInput
                    ? '위 정답을 보고 아래 채팅 입력창에 다시 입력해 완료해 보세요.'
                    : '위 정답을 보고 직접 입력해 완료해 보세요.')
                : (widget.externalInput
                    ? '오답이에요. 힌트를 참고해서 아래 채팅 입력창에 다시 입력해 보세요.'
                    : '오답이에요. 힌트를 참고해서 다시 입력해 보세요.'),
            style: const TextStyle(fontSize: 13, color: Color(0xFFFF8A80)),
          ),
        ],
        if (hintKo.isNotEmpty && !_effectiveAnswerRevealed) ...[
          const SizedBox(height: 8),
          Text(hintKo,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ],
        if (!_effectiveAnswerRevealed) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _actionButton(
                icon: Icons.tips_and_updates_outlined,
                label: _hintLevel == 0
                    ? '글자 힌트'
                    : (_hintLevel == 1 ? '단어 보기' : '힌트 확인됨'),
                onPressed: _hintLevel >= 2 ? null : _revealHint,
              ),
              _actionButton(
                icon: Icons.visibility_outlined,
                label: '정답 보기',
                onPressed: _effectiveAnswerRevealed
                    ? null
                    : () => _revealAnswer(fillField: true),
              ),
              if (_showAudio)
                QuizAudioButton(
                  key: widget.audioButtonKey,
                  audioUrl: widget.audioUrl,
                  iconSize: 18,
                ),
            ],
          ),
        ],
        if (!widget.externalInput && !_solved) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            enabled: !_submitting,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: '빈칸에 들어갈 표현을 입력하세요',
              prefixIcon: const Icon(Icons.edit_rounded, size: 20),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.24),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    BorderSide(color: scheme.outline.withValues(alpha: 0.55)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: scheme.primary, width: 1.5),
              ),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: _submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(wrongFirstTry ? '다시 확인' : '확인'),
          ),
        ],
      ],
    );
  }
}

/// A simple blinking text-cursor bar for the word currently being typed.
class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor({required this.color, required this.height});

  final Color color;
  final double height;

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(width: 2, height: widget.height, color: widget.color),
    );
  }
}
