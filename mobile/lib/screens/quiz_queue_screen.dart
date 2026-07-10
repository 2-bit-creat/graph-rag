import 'package:flutter/material.dart';

import '../api/client.dart';

class QuizQueueScreen extends StatefulWidget {
  const QuizQueueScreen({super.key});

  @override
  State<QuizQueueScreen> createState() => _QuizQueueScreenState();
}

class _QuizQueueScreenState extends State<QuizQueueScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  String? _typeFilter;
  bool _loading = true;
  String? _error;
  List<dynamic> _items = [];
  int _total = 0;

  static const _typeChips = [
    (null, '전체'),
    ('cloze', '단어완성'),
    ('scramble', '문장배열'),
    ('mcq_nuance', '뉘앙스선다'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String get _queueKind => _tabController.index == 0 ? 'new' : 'review';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await apiClient.listQuizQueueItems(
        queueKind: _queueKind,
        quizType: _typeFilter,
      );
      if (mounted) {
        setState(() {
          _items = data['items'] as List<dynamic>? ?? [];
          _total = (data['total'] as num?)?.toInt() ?? _items.length;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<bool> _confirmDelete(String quizId) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('큐에서 제거'),
            content: const Text('이 문제를 학습 큐에서 삭제할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deleteItem(String quizId) async {
    try {
      await apiClient.deleteQuizItem(quizId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('큐에서 제거했습니다')),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('삭제 실패: $e')),
        );
      }
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'cloze':
        return '단어완성';
      case 'scramble':
        return '문장배열';
      case 'mcq_nuance':
        return '뉘앙스선다';
      default:
        return type;
    }
  }

  String _reviewLabel(String? iso) {
    if (iso == null || iso.isEmpty) return '복습 예정 없음';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final now = DateTime.now().toUtc();
    final diff = dt.difference(now);
    if (diff.isNegative) return '복습 가능';
    if (diff.inHours < 24) return '${diff.inHours}시간 후 복습';
    return '${diff.inDays}일 후 복습';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 학습 큐 관리'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '새로 배울 문제 (NEW)'),
            Tab(text: '복습 대기 중 (REVIEW)'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final chip in _typeChips)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(chip.$2),
                        selected: _typeFilter == chip.$1,
                        onSelected: (_) {
                          setState(() => _typeFilter = chip.$1);
                          _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_total > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('$_total개', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text('불러오기 실패: $_error'))
                    : _items.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('큐가 비어 있습니다 — 저널에서 퀴즈를 생성해 보세요'),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              padding: const EdgeInsets.all(12),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final item = _items[index] as Map<String, dynamic>;
                                final id = item['id']?.toString() ?? '';
                                final lv = (item['difficulty_level'] as num?)?.toInt() ?? 0;
                                final target = item['target_node']?.toString() ?? '';
                                final contextSentence =
                                    item['context_sentence']?.toString() ?? '';
                                final quizType = item['quiz_type']?.toString() ?? '';
                                final sourceLabel = item['source_label']?.toString() ?? '';
                                final streak = (item['streak'] as num?)?.toInt() ?? 0;
                                final nextReview = item['next_review_at']?.toString();

                                return Dismissible(
                                  key: ValueKey(id),
                                  direction: DismissDirection.endToStart,
                                  background: Container(
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 20),
                                    color: Colors.red.shade400,
                                    child: const Icon(Icons.delete, color: Colors.white),
                                  ),
                                  confirmDismiss: (_) => _confirmDelete(id),
                                  onDismissed: (_) => _deleteItem(id),
                                  child: Card(
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        child: Text('Lv$lv', style: const TextStyle(fontSize: 10)),
                                      ),
                                      title: Text(
                                        target.isNotEmpty ? target : '(대상 없음)',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            contextSentence,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Wrap(
                                            spacing: 6,
                                            children: [
                                              Chip(
                                                label: Text(_typeLabel(quizType),
                                                    style: const TextStyle(fontSize: 10)),
                                                visualDensity: VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                              ),
                                              if (sourceLabel.isNotEmpty)
                                                Chip(
                                                  label: Text(sourceLabel,
                                                      style: const TextStyle(fontSize: 10)),
                                                  visualDensity: VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  backgroundColor:
                                                      Colors.deepPurple.shade50,
                                                ),
                                              if (_queueKind == 'review') ...[
                                                Text(
                                                  _reviewLabel(nextReview),
                                                  style: TextStyle(
                                                      fontSize: 10, color: Colors.grey[600]),
                                                ),
                                                if (streak > 0)
                                                  Text(
                                                    '스트릭 ${streak}회',
                                                    style: TextStyle(
                                                        fontSize: 10, color: Colors.grey[600]),
                                                  ),
                                              ],
                                            ],
                                          ),
                                        ],
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () async {
                                          if (await _confirmDelete(id)) {
                                            await _deleteItem(id);
                                          }
                                        },
                                      ),
                                      isThreeLine: true,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
