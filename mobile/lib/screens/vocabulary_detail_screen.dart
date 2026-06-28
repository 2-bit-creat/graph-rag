import 'package:flutter/material.dart';

import '../api/client.dart';
import '../models/vocabulary.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/vocabulary_word_add_card.dart';

class VocabularyDetailScreen extends StatefulWidget {
  const VocabularyDetailScreen({
    super.key,
    required this.vocabId,
    required this.initialName,
  });

  final String vocabId;
  final String initialName;

  @override
  State<VocabularyDetailScreen> createState() => _VocabularyDetailScreenState();
}

class _VocabularyDetailScreenState extends State<VocabularyDetailScreen> {
  late String _name;
  List<VocabWord> _words = [];
  bool _loading = true;
  bool _adding = false;
  bool _savingMeta = false;
  String? _error;
  final _addCardKey = GlobalKey<VocabularyWordAddCardState>();

  @override
  void initState() {
    super.initState();
    _name = widget.initialName;
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final data = await apiClient.getVocabulary(widget.vocabId);
      final raw = data['words'] as List<dynamic>? ?? [];
      final words = raw
          .whereType<Map>()
          .map((e) => VocabWord.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (mounted) {
        setState(() {
          _name = data['name']?.toString() ?? _name;
          _words = words;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _editVocabName() async {
    final nameCtrl = TextEditingController(text: _name);
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('단어장 이름 수정'),
            content: TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: '이름',
                hintText: '예: IELTS 핵심 단어',
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim().isNotEmpty),
                child: const Text('저장'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    final newName = nameCtrl.text.trim();
    if (newName == _name) return;

    setState(() => _savingMeta = true);
    try {
      await apiClient.updateVocabulary(widget.vocabId, name: newName);
      if (mounted) {
        setState(() => _name = newName);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('단어장 이름을 수정했습니다')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('수정 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingMeta = false);
    }
  }

  Future<void> _editWordMeaning(VocabWord word) async {
    final meaningCtrl = TextEditingController(text: word.meaning);
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('「${word.word}」 뜻 수정'),
            content: TextField(
              controller: meaningCtrl,
              decoration: const InputDecoration(
                labelText: '뜻',
                hintText: '한국어 또는 영문 정의',
              ),
              autofocus: true,
              maxLines: 4,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, meaningCtrl.text.trim().isNotEmpty),
                child: const Text('저장'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    final newMeaning = meaningCtrl.text.trim();
    if (newMeaning == word.meaning) return;

    try {
      await apiClient.updateVocabularyWord(
        widget.vocabId,
        word.word,
        meaning: newMeaning,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${word.word}」 뜻을 수정했습니다')),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('수정 실패: $e')),
        );
      }
    }
  }

  Future<void> _addWord({required String word, required String meaning}) async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await apiClient.addVocabularyWord(
        widget.vocabId,
        word: word,
        meaning: meaning,
      );
      if (mounted) {
        _addCardKey.currentState?.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「$word」을(를) 추가했습니다')),
        );
        await _load(silent: true);
        _addCardKey.currentState?.focusWord();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('추가 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _deleteWord(VocabWord word) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('단어 삭제'),
            content: Text('「${word.word}」을(를) 삭제할까요?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    try {
      await apiClient.deleteVocabularyWord(widget.vocabId, word.word);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('단어를 삭제했습니다')),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('삭제 실패: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _savingMeta ? null : _editVocabName,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.edit_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.outline,
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.drive_file_rename_outline),
            tooltip: '이름 수정',
            onPressed: _savingMeta ? null : _editVocabName,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '단어 추가',
            onPressed: _adding ? null : () => _addCardKey.currentState?.focusWord(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _adding ? null : () => _addCardKey.currentState?.focusWord(),
        icon: const Icon(Icons.add),
        label: const Text('단어 추가'),
      ),
      body: _loading
          ? const AppLoadingScreen(message: '단어 불러오는 중…')
          : RefreshIndicator(
              onRefresh: () => _load(silent: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageH,
                  AppSpacing.md,
                  AppSpacing.pageH,
                  AppSpacing.xxl + 72,
                ),
                children: [
                  if (_error != null) ...[
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Text(_error!),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  VocabularyWordAddCard(
                    key: _addCardKey,
                    loading: _adding,
                    onSubmit: _addWord,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppSectionHeader(
                    title: '단어 목록 (${_words.length})',
                    subtitle: '탭하여 뜻 수정 · 스와이프로 삭제',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_words.isEmpty)
                    const AppEmptyState(
                      icon: Icons.style_outlined,
                      title: '아직 카드가 없습니다',
                      subtitle: '위 입력란에 단어와 뜻을 적고 추가해 보세요',
                    )
                  else
                    ..._words.map((w) {
                      return Dismissible(
                        key: ValueKey(w.word),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: AppSpacing.lg),
                          color: Theme.of(context).colorScheme.error,
                          child: const Icon(Icons.delete_outline, color: Colors.white),
                        ),
                        confirmDismiss: (_) async {
                          await _deleteWord(w);
                          return false;
                        },
                        child: Card(
                          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: ListTile(
                            onTap: () => _editWordMeaning(w),
                            title: Text(w.word, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(w.meaning),
                                if (w.linkedDiaryId != null)
                                  Text(
                                    '일기 연결 · 복습 ${w.reviewCount}회',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  )
                                else if (w.reviewCount > 0)
                                  Text(
                                    '복습 ${w.reviewCount}회',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  tooltip: '뜻 수정',
                                  onPressed: () => _editWordMeaning(w),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: '삭제',
                                  onPressed: () => _deleteWord(w),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}
