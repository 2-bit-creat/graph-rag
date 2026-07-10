import 'package:flutter/material.dart';

import '../api/client.dart';
import ../theme/app_theme.dart

class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key, required this.entryId});
  final String entryId;

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  List<dynamic> _cards = [];
  int _index = 0;
  bool _showAnswer = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cards = await apiClient.generateQuiz(widget.entryId);
      if (mounted) setState(() { _cards = cards; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Quiz error: $e')));
      }
    }
  }

  void _next() {
    setState(() {
      _showAnswer = false;
      if (_index < _cards.length - 1) _index++;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(appBar: AppBar(title: const Text('퀴즈')), body: const Center(child: CircularProgressIndicator()));
    }
    if (_cards.isEmpty) {
      return Scaffold(appBar: AppBar(title: const Text('퀴즈')), body: const Center(child: Text('퀴즈를 생성할 수 없습니다')));
    }

    final card = _cards[_index] as Map<String, dynamic>;
    final isLast = _index >= _cards.length - 1;

    return Scaffold(
      appBar: AppBar(title: Text('퀴즈 ${_index + 1}/${_cards.length}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: (_index + 1) / _cards.length),
            const Spacer(),
            Text('Question', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Text(card['question'] ?? '', style: Theme.of(context).textTheme.headlineSmall),
            if (card['hint'] != null && card['hint'].toString().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Hint: ${card['hint']}', style: TextStyle(color: context.mutedText, fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 24),
            if (_showAnswer) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(card['answer'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    if (card['grammar_note'] != null && card['grammar_note'].toString().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(card['grammar_note'], style: TextStyle(color: context.subtleText)),
                    ],
                  ],
                ),
              ),
            ],
            const Spacer(),
            if (!_showAnswer)
              FilledButton(onPressed: () => setState(() => _showAnswer = true), child: const Text('정답 보기'))
            else
              FilledButton(onPressed: isLast ? () => Navigator.pop(context) : _next, child: Text(isLast ? '완료' : '다음')),
          ],
        ),
      ),
    );
  }
}
