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
  });

  final Map<String, dynamic> quizData;
  final Future<bool> Function(String answer) onSubmit;
  final VoidCallback onSolved;
  final String? audioUrl;
  final GlobalKey<QuizAudioButtonState>? audioButtonKey;
  final bool externalInput;
  final Map<String, dynamic>? externalResult;
  final bool externalSolved;

  @override
  State<ClozeQuizCard> createState() => _ClozeQuizCardState();
}

class _ClozeQuizCardState extends State<ClozeQuizCard> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _submitting = false;
  int _hintStep = 0;
  bool _answerRevealed = false;
  bool? _graded;
  bool _solved = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool? get _effectiveGrade => widget.externalInput
      ? (widget.externalSolved
          ? true
          : widget.externalResult?['is_correct'] as bool?)
      : _graded;

  bool get _effectiveSolved =>
      widget.externalInput ? widget.externalSolved : _solved;

  bool get _effectiveAnswerRevealed =>
      _answerRevealed ||
      (widget.externalInput && widget.externalResult != null) ||
      _effectiveSolved;

  bool get _showAudio => _effectiveGrade != null || _effectiveAnswerRevealed;

  String get _blank => (widget.quizData['blank']?.toString() ??
          (widget.quizData['accepted_answers'] as List?)?.first?.toString() ??
          '')
      .trim()
      .toLowerCase();

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
    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: prompt.substring(0, match.start)),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: InkWell(
              onTap: visible || widget.externalInput
                  ? null
                  : () => _focusNode.requestFocus(),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                constraints: BoxConstraints(
                  minWidth: 132,
                  maxWidth: maxBlankWidth,
                ),
                margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color:
                      scheme.primary.withValues(alpha: visible ? 0.14 : 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color:
                        scheme.primary.withValues(alpha: visible ? 0.5 : 0.36),
                  ),
                ),
                child: visible
                    ? Text(
                        blank,
                        softWrap: true,
                        textAlign: TextAlign.center,
                        style: baseStyle?.copyWith(
                          color: scheme.primary,
                          height: 1.28,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.edit_rounded,
                              size: 17, color: scheme.primary),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '정답 입력',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
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

  void _revealHint() =>
      setState(() => _hintStep = (_hintStep + 1).clamp(0, 2).toInt());

  List<String> _letterHintTokens(String answer) {
    final revealCount = _hintStep == 1 ? 1 : 2;
    return answer
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .map((word) {
      final visible =
          word.substring(0, revealCount.clamp(1, word.length).toInt());
      final concealed = word.length - visible.length;
      // The sentence already shows exact blank lengths. Keep this hint
      // compact so a long phrase does not turn into a second wall of lines.
      return '$visible${concealed > 0 ? '·' * concealed.clamp(1, 3).toInt() : ''}';
    }).toList();
  }

  void _revealAnswer({bool fillField = false}) {
    final blank = _blank;
    setState(() {
      _answerRevealed = true;
      if (fillField && blank.isNotEmpty) _controller.text = blank;
    });
    widget.audioButtonKey?.currentState?.play(showError: false);
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
        _answerRevealed = true;
        _solved = correct;
        if (!correct) _controller.clear();
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
          content: Text('정답과 철자를 비교한 뒤 다시 입력해 보세요.'),
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
          Text(
            blank,
            softWrap: true,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                  height: 1.35,
                ),
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
        if (_hintStep > 0 && !_effectiveAnswerRevealed && blank.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _hintStep == 1 ? '철자 힌트 · 첫 글자' : '철자 힌트 · 앞 글자',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final token in _letterHintTokens(blank))
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          token,
                          style: TextStyle(
                            color: scheme.primary,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_effectiveAnswerRevealed && blank.isNotEmpty) ...[
          const SizedBox(height: 14),
          _answerPanel(blank: blank, wrongFirstTry: wrongFirstTry),
        ],
        if (wrongFirstTry) ...[
          const SizedBox(height: 7),
          Text(
            widget.externalInput
                ? '오답이에요. 위 정답을 확인한 뒤 아래 채팅 입력창에 다시 입력해 보세요.'
                : '오답이에요. 위 정답을 보고 직접 입력해 완료해 보세요.',
            style: const TextStyle(fontSize: 13, color: Color(0xFFFF8A80)),
          ),
        ],
        if (hintKo.isNotEmpty && !_effectiveAnswerRevealed) ...[
          const SizedBox(height: 8),
          Text(hintKo,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ],
        if (_effectiveGrade == null) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _actionButton(
                icon: Icons.tips_and_updates_outlined,
                label: _hintStep == 0
                    ? '글자 힌트'
                    : (_hintStep == 1 ? '글자 하나 더' : '힌트 확인됨'),
                onPressed: _hintStep >= 2 ? null : _revealHint,
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
        ] else if (_showAudio) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: QuizAudioButton(
              key: widget.audioButtonKey,
              audioUrl: widget.audioUrl,
              iconSize: 18,
            ),
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
