import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../models/vocabulary.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'statement_bank_screen.dart';
import 'vocabulary_detail_screen.dart';

class VocabularyHubScreen extends StatefulWidget {
  const VocabularyHubScreen({super.key});

  @override
  State<VocabularyHubScreen> createState() => _VocabularyHubScreenState();
}

class _VocabularyHubScreenState extends State<VocabularyHubScreen> {
  List<VocabularySummary> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final raw = await apiClient.listVocabularies();
      final items = raw
          .whereType<Map>()
          .map((e) => VocabularySummary.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  Future<void> _createVocabulary() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('vocabHub.newVocabTitle')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: tr('sidebar.nameLabel'),
                    hintText: tr('vocabHub.nameHint'),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  decoration: InputDecoration(
                    labelText: tr('vocabHub.descLabelOptional'),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('common.cancel'))),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(ctx, nameCtrl.text.trim().isNotEmpty),
                child: Text(tr('common.create')),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    try {
      await apiClient.createVocabulary(
        name: nameCtrl.text.trim(),
        description: descCtrl.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabHub.createdSnackbar'))),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabHub.createFailed', {'error': e}))),
        );
      }
    }
  }

  Future<void> _deleteVocabulary(VocabularySummary vocab) async {
    if (vocab.isDefault) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('vocabHub.deleteTitle')),
            content: Text(tr('vocabHub.deleteBody', {'name': vocab.name})),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('common.cancel'))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(tr('common.delete'))),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    try {
      await apiClient.deleteVocabulary(vocab.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabHub.deletedSnackbar'))),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabHub.deleteFailed', {'error': e}))),
        );
      }
    }
  }

  Future<void> _deleteStatementBank(String langKey, String displayName) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('vocabHub.deleteExtractedTitle')),
            content: Text(
              tr('vocabHub.deleteExtractedBody', {'name': displayName}),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('common.cancel'))),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.orange.shade700),
                child: Text(tr('vocabHub.deleteAndReextract')),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;

    try {
      final result = await apiClient.deleteAndReextractLanguage(langKey);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(result['message']?.toString() ?? tr('vocabHub.reextractStartedSnackbar'))),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('vocabHub.deleteFailed', {'error': e}))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('vocabHub.pageTitle')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: tr('vocabHub.newVocabTooltip'),
            onPressed: _createVocabulary,
          ),
        ],
      ),
      body: _loading
          ? AppLoadingScreen(message: tr('vocabHub.loadingVocab'))
          // A failed load used to render the error card *and* the empty state,
          // which reads as "your list is empty" when the truth is "we
          // couldn't fetch it". Show one centered failure with a retry
          // instead; the inline banner below is kept for the case where a
          // refresh fails but we still have data to show.
          : (_error != null && _items.isEmpty)
              ? AppEmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: tr('vocabHub.loadFailedTitle'),
                  subtitle: _error,
                  action: FilledButton(
                    onPressed: _load,
                    child: Text(tr('kg.retry')),
                  ),
                )
              : RefreshIndicator(
              onRefresh: () => _load(silent: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageH,
                  AppSpacing.md,
                  AppSpacing.pageH,
                  AppSpacing.xxl,
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
                  AppSectionHeader(
                    title: tr('vocabHub.myVocabTitle'),
                    subtitle: tr('vocabHub.myVocabSubtitle'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_items.isEmpty)
                    AppEmptyState(
                      icon: Icons.menu_book_outlined,
                      title: tr('vocabHub.emptyTitle'),
                      subtitle: tr('vocabHub.emptySubtitle'),
                    )
                  else
                    ..._items.map((vocab) {
                      final isStatementBank =
                          vocab.id.startsWith('statement_bank:');
                      final langKey = isStatementBank
                          ? vocab.id.substring('statement_bank:'.length)
                          : null;

                      Color avatarColor;
                      Color iconColor;
                      IconData iconData;
                      if (vocab.isDefault) {
                        avatarColor = AppColors.hubQuiz.withValues(alpha: 0.15);
                        iconColor = AppColors.hubQuiz;
                        iconData = Icons.public;
                      } else if (isStatementBank) {
                        avatarColor = Colors.teal.withValues(alpha: 0.12);
                        iconColor = Colors.teal;
                        iconData = Icons.translate;
                      } else {
                        avatarColor = AppColors.accent.withValues(alpha: 0.15);
                        iconColor = AppColors.accent;
                        iconData = Icons.book_outlined;
                      }

                      return Card(
                        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: avatarColor,
                            child: Icon(iconData, color: iconColor),
                          ),
                          title: Text(vocab.name),
                          subtitle: Text(
                            [
                              if (vocab.isDefault) tr('vocabHub.serverDefault'),
                              if (isStatementBank) tr('vocabHub.autoExtracted'),
                              tr('vocabHub.expressionCount', {'count': vocab.wordCount}),
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: vocab.isDefault
                              ? null
                              : isStatementBank
                                  ? IconButton(
                                      icon: const Icon(Icons.refresh, size: 20),
                                      tooltip: tr('vocabHub.reextractTooltip'),
                                      onPressed: () => _deleteStatementBank(
                                        langKey!,
                                        vocab.name,
                                      ),
                                    )
                                  : IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _deleteVocabulary(vocab),
                                    ),
                          onTap: vocab.isDefault
                              ? null
                              : () async {
                                  if (isStatementBank && langKey != null) {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => StatementBankScreen(
                                            language: langKey),
                                      ),
                                    );
                                  } else {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => VocabularyDetailScreen(
                                          vocabId: vocab.id,
                                          initialName: vocab.name,
                                        ),
                                      ),
                                    );
                                  }
                                  _load(silent: true);
                                },
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}
