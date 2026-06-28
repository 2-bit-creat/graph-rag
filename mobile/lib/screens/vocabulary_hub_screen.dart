import 'package:flutter/material.dart';

import '../api/client.dart';
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
          _error = e.toString();
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
            title: const Text('새 단어장'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '이름',
                    hintText: '예: 여행 표현',
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(
                    labelText: '설명 (선택)',
                  ),
                  maxLines: 2,
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim().isNotEmpty),
                child: const Text('만들기'),
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
          const SnackBar(content: Text('단어장을 만들었습니다')),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('생성 실패: $e')),
        );
      }
    }
  }

  Future<void> _deleteVocabulary(VocabularySummary vocab) async {
    if (vocab.isDefault) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('단어장 삭제'),
            content: Text('「${vocab.name}」 단어장을 삭제할까요?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    try {
      await apiClient.deleteVocabulary(vocab.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('단어장을 삭제했습니다')),
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

  Future<void> _deleteStatementBank(String langKey, String displayName) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('추출 표현 삭제'),
            content: Text(
              '「$displayName」에서 추출된 모든 표현을 삭제하고\n'
              '백그라운드에서 다시 소급 추출합니다.\n\n'
              '새로 추출된 표현에는 CEFR 난이도가 포함됩니다.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
                child: const Text('삭제 후 재추출'),
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
          SnackBar(content: Text(result['message']?.toString() ?? '재추출이 시작됐습니다')),
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
        title: const Text('단어장'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '새 단어장',
            onPressed: _createVocabulary,
          ),
        ],
      ),
      body: _loading
          ? const AppLoadingScreen(message: '단어장 불러오는 중…')
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
                  const AppSectionHeader(
                    title: '내 단어장',
                    subtitle: '퀴즈 자유도 모드에서 문제 소스로 사용할 수 있습니다',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_items.isEmpty)
                    const AppEmptyState(
                      icon: Icons.menu_book_outlined,
                      title: '단어장이 없습니다',
                      subtitle: '우측 상단 + 버튼으로 만들어 보세요',
                    )
                  else
                    ..._items.map((vocab) {
                      final isStatementBank = vocab.id.startsWith('statement_bank:');
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
                              if (vocab.isDefault) '서버 디폴트',
                              if (isStatementBank) '자동 추출',
                              '${vocab.wordCount}개 표현',
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: vocab.isDefault
                              ? null
                              : isStatementBank
                                  ? IconButton(
                                      icon: const Icon(Icons.refresh, size: 20),
                                      tooltip: '삭제 후 재추출',
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
                                        builder: (_) => StatementBankScreen(language: langKey),
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
