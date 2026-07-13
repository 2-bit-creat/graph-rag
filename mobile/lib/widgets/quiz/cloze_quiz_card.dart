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
  });

  final Map<String, dynamic> quizData;

  /// First-attempt grading — hits the backend and reports whether it was correct.
  final Future<bool> Function(String answer) onSubmit;

  /// Fired once the blank has been answered correctly, whether on the first
  /// try or after retyping the revealed answer.
  final VoidCallback onSolved;

  final String? audioUrl;
  final GlobalKey<QuizAudioButtonState>? audioButtonKey;

  @override
  State<ClozeQuizCard> createState() => _ClozeQuizCardState();
}

class _ClozeQuizCardState extends State<ClozeQuizCard> {
  final _controller = TextEditingController();
  bool _submitting = false;
  bool _hintRevealed = false;
  bool _answerRevealed = false;

  /// null = not graded yet; true/false = result of the first attempt.
  bool? _graded;
  bool _solved = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _locked => _solved;

  // Reveal the speaker once the first attempt has been graded (or the user
  // gave up and asked to see the answer) — hearing it beforehand gives the
  // blank away.
  bool get _showAudio => _graded != null || _answerRevealed;

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
    widget.audioButtonKey?.currentState?.play(showError: false);
  }

  Future<void> _submit() async {
    if (_submitting || _locked) return;
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
        _hintRevealed = true;
        _solved = correct;
        if (!correct) _controller.clear();
      });
      widget.audioButtonKey?.currentState?.play(showError: false);
      if (correct) widget.onSolved();
      return;
    }

    // First attempt was wrong — check the retype locally. No second grading
    // call: re-submitting to the backend would double-count the SM2 review.
    if (text.toLowerCase() == _blank) {
      setState(() => _solved = true);
      widget.onSolved();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('아직 정답과 달라요. 다시 입력해보세요.'),
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
      return Text(raw, style: TextStyle(fontSize: 14, color: mutedColor));
    }
    final before = raw.substring(0, match.start);
    final highlight = match.group(1) ?? '';
    final after = raw.substring(match.end);
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 14, color: mutedColor),
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
    final scheme = Theme.of(context).colorScheme;
    final prompt = widget.quizData['prompt_en']?.toString() ?? '';
    final hint = widget.quizData['blank_display']?.toString() ?? '';
    final contextKo = widget.quizData['context_ko']?.toString() ?? '';
    final hintKo = widget.quizData['hint_ko']?.toString() ?? '';
    final blank = _blank;
    final wrongFirstTry = _graded == false && !_solved;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                prompt,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Offstage(
              offstage: !_showAudio,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: QuizAudioButton(
                  key: widget.audioButtonKey,
                  audioUrl: widget.audioUrl,
                ),
              ),
            ),
          ],
        ),
        if (contextKo.isNotEmpty && !_isAnswerOnlyContext(contextKo)) ...[
          const SizedBox(height: 12),
          _buildContextKo(contextKo),
        ],
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
              color: scheme.onSurfaceVariant,
              fontFamily: 'monospace',
            ),
          ),
        ],
        if (_answerRevealed && blank.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '정답: $blank',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.green,
            ),
          ),
        ],
        if (wrongFirstTry) ...[
          const SizedBox(height: 4),
          Text(
            '오답이에요. 위 정답을 보고 직접 입력해서 완성해보세요.',
            style: TextStyle(fontSize: 12.5, color: Colors.redAccent.shade100),
          ),
        ],
        if (hintKo.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(hintKo, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ],
        if (_graded == null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: _hintRevealed ? null : _revealHint,
                icon: const Icon(Icons.tips_and_updates_outlined, size: 18),
                label: const Text('힌트 보기'),
              ),
              TextButton.icon(
                onPressed: _answerRevealed
                    ? null
                    : () => _revealAnswer(fillField: true),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('정답 보기'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          enabled: !_locked && !_submitting,
          decoration: InputDecoration(
            labelText: '영어 단어 입력',
            hintText: 'e.g. restaurant',
            border: const OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: !_locked && !_submitting ? _submit : null,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(wrongFirstTry ? '다시 확인' : '확인'),
        ),
      ],
    );
  }
}
