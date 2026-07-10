import 'package:flutter/material.dart';

import 'quiz_audio_button.dart';

class ClozeQuizCard extends StatefulWidget {
  const ClozeQuizCard({
    super.key,
    required this.quizData,
    required this.onSubmit,
    this.audioUrl,
    this.audioButtonKey,
    this.showCorrectAnswer = false,
    this.enabled = true,
  });

  final Map<String, dynamic> quizData;
  final Future<void> Function(String answer) onSubmit;
  final String? audioUrl;
  final GlobalKey<QuizAudioButtonState>? audioButtonKey;
  final bool showCorrectAnswer;
  final bool enabled;

  @override
  State<ClozeQuizCard> createState() => _ClozeQuizCardState();
}

class _ClozeQuizCardState extends State<ClozeQuizCard> {
  final _controller = TextEditingController();
  bool _submitting = false;
  bool _hintRevealed = false;
  bool _answerRevealed = false;

  @override
  void didUpdateWidget(covariant ClozeQuizCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showCorrectAnswer && !oldWidget.showCorrectAnswer) {
      _revealAnswer(fillField: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _blank =>
      (widget.quizData['blank']?.toString() ??
              (widget.quizData['accepted_answers'] as List?)?.first?.toString() ??
              '')
          .trim()
          .toLowerCase();

  String _parenReveal(String word) {
    final tokens = word.split(RegExp(r'\s+'));
    return tokens
        .map((t) => '( ${t.split('').join(' ')} )')
        .join('   ');
  }

  void _revealHint() {
    setState(() => _hintRevealed = true);
  }

  void _revealAnswer({bool fillField = false}) {
    final blank = _blank;
    setState(() {
      _answerRevealed = true;
      _hintRevealed = true;
      if (fillField && blank.isNotEmpty) {
        _controller.text = blank;
      }
    });
  }

  Future<void> _submit() async {
    if (_submitting || !widget.enabled) return;
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(_controller.text.trim());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _buildContextKo(String raw) {
    final spanRe = RegExp(
      "<span\\s+color=['\"]#FFA500['\"][^>]*>(.*?)</span>",
      caseSensitive: false,
      dotAll: true,
    );
    final match = spanRe.firstMatch(raw);
    if (match == null) {
      return Text(raw, style: TextStyle(fontSize: 14, color: Colors.grey[800]));
    }
    final before = raw.substring(0, match.start);
    final highlight = match.group(1) ?? '';
    final after = raw.substring(match.end);
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 14, color: Colors.grey[800]),
        children: [
          TextSpan(text: before),
          TextSpan(
            text: highlight,
            style: const TextStyle(
              color: Color(0xFFFFA500),
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: after),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.quizData['prompt_en']?.toString() ?? '';
    final hint = widget.quizData['blank_display']?.toString() ?? '';
    final contextKo = widget.quizData['context_ko']?.toString() ?? '';
    final hintKo = widget.quizData['hint_ko']?.toString() ?? '';
    final blank = _blank;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (contextKo.isNotEmpty) ...[
          _buildContextKo(contextKo),
          const SizedBox(height: 12),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                prompt,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(width: 8),
            QuizAudioButton(
              key: widget.audioButtonKey,
              audioUrl: widget.audioUrl,
            ),
          ],
        ),
        if (hint.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            hint,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  letterSpacing: 4,
                  fontFamily: 'monospace',
                ),
          ),
        ],
        if (_hintRevealed && blank.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _parenReveal(blank),
            style: TextStyle(
              fontSize: 18,
              letterSpacing: 3,
              fontWeight: FontWeight.w300,
              color: Colors.grey.shade500,
              fontFamily: 'monospace',
            ),
          ),
        ],
        if (_answerRevealed && blank.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '정답: $blank',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.green.shade700,
            ),
          ),
        ],
        if (hintKo.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(hintKo, style: TextStyle(fontSize: 13, color: context.subtleText)),
        ],
        if (widget.enabled && !_answerRevealed) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: _hintRevealed ? null : _revealHint,
                icon: const Icon(Icons.tips_and_updates_outlined, size: 18),
                label: const Text('힌트 보기'),
              ),
              TextButton.icon(
                onPressed: _answerRevealed ? null : () => _revealAnswer(fillField: true),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('정답 보기'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          enabled: widget.enabled && !_submitting,
          decoration: const InputDecoration(
            labelText: '영어 단어 입력',
            hintText: 'e.g. restaurant',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: widget.enabled && !_submitting ? _submit : null,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('확인'),
        ),
      ],
    );
  }
}
