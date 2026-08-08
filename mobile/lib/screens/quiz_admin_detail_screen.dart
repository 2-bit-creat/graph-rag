import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'quiz_pipeline_hub_screen.dart';

class QuizAdminDetailScreen extends StatefulWidget {
  const QuizAdminDetailScreen({super.key, required this.quizId});

  final String quizId;

  @override
  State<QuizAdminDetailScreen> createState() => _QuizAdminDetailScreenState();
}

class _QuizAdminDetailScreenState extends State<QuizAdminDetailScreen> {
  Map<String, dynamic>? _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await apiClient.getAdminQuizItem(widget.quizId);
      if (mounted) setState(() => _data = data);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  String _date(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    return parsed == null ? '기록 없음' : DateFormat('yyyy.MM.dd HH:mm').format(parsed);
  }

  String _pretty(dynamic value) {
    if (value == null) return '기록 없음';
    if (value is String) return value.isEmpty ? '기록 없음' : value;
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  Widget _row(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(label, style: const TextStyle(color: AppColors.textMuted)),
          ),
          Expanded(child: SelectableText(_pretty(value))),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => AppSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                )),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_data == null && _error == null) {
      return const Scaffold(body: AppLoadingScreen(message: '문제 정보를 불러오는 중…'));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('문제 상세')),
        body: AppEmptyState(
          icon: Icons.error_outline,
          title: '상세 정보를 불러오지 못했습니다',
          subtitle: _error.toString().replaceFirst('Exception: ', ''),
          action: FilledButton(onPressed: _load, child: const Text('다시 시도')),
        ),
      );
    }
    final data = _data!;
    final item = Map<String, dynamic>.from(data['item'] as Map);
    final quizData =
        Map<String, dynamic>.from((item['quiz_data'] as Map?) ?? const {});
    final attempts = (data['attempts'] as List? ?? const [])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final type = item['quiz_type'] == 'composition' ? '작문' : '단어';

    return Scaffold(
      appBar: AppBar(
        title: Text('$type 문제 상세'),
        actions: [
          IconButton(
            tooltip: '생성 trace',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => QuizPipelineHubScreen(initialQuizId: widget.quizId),
              ),
            ),
            icon: const Icon(Icons.route_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.pageH),
          children: [
            _section('문제 정의', [
              _row('유형 / 언어', '$type · ${item['language'] ?? 'english'}'),
              _row('질문', item['question_native']),
              _row('Target 문장', item['sentence_target']),
              _row('원본 Statement', item['target_node']),
              _row('빈칸 정답', quizData['blank']),
              _row('허용 답안', quizData['accepted_answers']),
              _row('Target 표현', quizData['target_expressions']),
              _row('힌트', quizData['hint_ko'] ?? quizData['hints']),
            ]),
            const SizedBox(height: 12),
            _section('생성 및 학습 상태', [
              _row('생성일', _date(item['created_at'])),
              _row('최초 학습', _date(item['first_answered_at'])),
              _row('마지막 학습', _date(item['last_answered_at'])),
              _row('큐 상태', item['queue_kind']),
              _row('난이도', item['difficulty_level']),
              _row('정답 / 오답', '${item['times_correct'] ?? 0} / ${item['times_wrong'] ?? 0}'),
              _row('마지막 quality', item['last_quality']),
              _row('다음 복습', _date(item['next_review_at'])),
              _row('생성 identity', data['generation_key']),
              _row('생성 실행 ID', quizData['_generation_run_id']),
            ]),
            const SizedBox(height: 18),
            Text(
              '학습 시도 ${attempts.length}회',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            if (attempts.isEmpty)
              const AppEmptyState(
                icon: Icons.history_toggle_off,
                title: '학습 기록 없음',
                subtitle: '이 문제가 제출되면 답안과 힌트 사용 기록이 여기에 쌓입니다.',
              )
            else
              for (final attempt in attempts) ...[
                Card(
                  child: ExpansionTile(
                    leading: CircleAvatar(
                      backgroundColor: (attempt['correct'] == true
                              ? Colors.green
                              : Colors.orange)
                          .withValues(alpha: .14),
                      child: Icon(
                        attempt['correct'] == true
                            ? Icons.check_rounded
                            : Icons.close_rounded,
                        color: attempt['correct'] == true
                            ? Colors.green
                            : Colors.orange,
                      ),
                    ),
                    title: Text(_date(attempt['answered_at'])),
                    subtitle: Text(
                      'quality ${attempt['quality']} · +${attempt['xp_awarded'] ?? 0} XP'
                      '${attempt['source'] == 'legacy' ? ' · 이전 기록' : ''}',
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      _row('제출 답안', attempt['answer_payload']),
                      _row('힌트 단계', attempt['hint_level']),
                      _row('공개된 단어', attempt['revealed_tokens']),
                      _row('정답 공개', attempt['answer_revealed'] == true ? '사용' : '미사용'),
                      _row('튜터 피드백', attempt['tutor_feedback']),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ],
          ],
        ),
      ),
    );
  }
}
