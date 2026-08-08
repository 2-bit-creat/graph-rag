import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
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
  final Set<String> _deletingWords = {};
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
            title: Text(tr('vocabDetail.editNameTitle')),
            content: TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: tr('sidebar.nameLabel'),
                hintText: tr('vocabDetail.nameHint'),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim().isNotEmpty),
                child: Text(tr('common.save')),
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
          SnackBar(content: Text(tr('vocabDetail.nameEditedSnackbar'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabDetail.editFailed', {'error': e}))),
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
            title: Text(tr('vocabDetail.editMeaningTitle', {'word': word.word})),
            content: TextField(
              controller: meaningCtrl,
              decoration: InputDecoration(
                labelText: tr('vocabDetail.meaningLabel'),
                hintText: tr('vocabDetail.meaningHint'),
              ),
              autofocus: true,
              maxLines: 4,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, meaningCtrl.text.trim().isNotEmpty),
                child: Text(tr('common.save')),
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
          SnackBar(content: Text(tr('vocabDetail.meaningEditedSnackbar', {'word': word.word}))),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabDetail.editFailed', {'error': e}))),
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
          SnackBar(content: Text(tr('vocabDetail.wordAddedSnackbar', {'word': word}))),
        );
        await _load(silent: true);
        _addCardKey.currentState?.focusWord();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabDetail.addFailed', {'error': e}))),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _deleteWord(VocabWord word) async {
    if (_deletingWords.contains(word.word)) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('vocabDetail.deleteWordTitle')),
            content: Text(tr('vocabDetail.deleteWordBody', {'word': word.word})),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.delete'))),
            ],
          ),
        ) ??
        false;
    if (!ok || _deletingWords.contains(word.word)) return;

    setState(() => _deletingWords.add(word.word));
    try {
      await apiClient.deleteVocabularyWord(widget.vocabId, word.word);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabDetail.wordDeletedSnackbar'))),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabDetail.editFailed', {'error': e}))),
        );
        setState(() => _deletingWords.remove(word.word));
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
            tooltip: tr('vocabDetail.editNameTooltip'),
            onPressed: _savingMeta ? null : _editVocabName,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: tr('vocabDetail.addWordTooltip'),
            onPressed: _adding ? null : () => _addCardKey.currentState?.focusWord(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _adding ? null : () => _addCardKey.currentState?.focusWord(),
        icon: const Icon(Icons.add),
        label: Text(tr('vocabDetail.addWordTooltip')),
      ),
      body: _loading
          ? AppLoadingScreen(message: tr('vocabDetail.loadingWords'))
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
                    title: tr('vocabDetail.wordListTitle', {'count': _words.length}),
                    subtitle: tr('vocabDetail.wordListSubtitle'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_words.isEmpty)
                    AppEmptyState(
                      icon: Icons.style_outlined,
                      title: tr('vocabDetail.emptyTitle'),
                      subtitle: tr('vocabDetail.emptySubtitle'),
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
                                    tr('vocabDetail.journalLinkedReview', {'count': w.reviewCount}),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  )
                                else if (w.reviewCount > 0)
                                  Text(
                                    tr('vocabDetail.reviewCount', {'count': w.reviewCount}),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  tooltip: tr('vocabDetail.editMeaningTooltip'),
                                  onPressed: () => _editWordMeaning(w),
                                ),
                                _deletingWords.contains(w.word)
                                    ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        ),
                                      )
                                    : IconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        tooltip: tr('common.delete'),
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
