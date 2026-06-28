import 'package:flutter/material.dart';

import '../api/client.dart';
import '../models/vocabulary.dart';
import '../theme/app_theme.dart';

/// Bottom sheet: pick an existing custom vocabulary or create a new one inline.
class VocabularyPickerSheet extends StatefulWidget {
  const VocabularyPickerSheet({super.key});

  static Future<VocabularySummary?> show(BuildContext context) {
    return showModalBottomSheet<VocabularySummary>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const VocabularyPickerSheet(),
    );
  }

  @override
  State<VocabularyPickerSheet> createState() => _VocabularyPickerSheetState();
}

class _VocabularyPickerSheetState extends State<VocabularyPickerSheet> {
  List<VocabularySummary> _items = [];
  bool _loading = true;
  String? _error;

  // Inline creation state
  bool _creating = false;
  bool _saving = false;
  final _nameCtrl = TextEditingController();
  final _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final raw = await apiClient.listVocabularies();
      final items = raw
          .whereType<Map>()
          .map((e) => VocabularySummary.fromJson(Map<String, dynamic>.from(e)))
          .where((v) => !v.isDefault)
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

  void _showCreateForm() {
    setState(() {
      _creating = true;
      _nameCtrl.clear();
    });
    // Focus after frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _nameFocus.requestFocus());
  }

  void _cancelCreate() {
    setState(() {
      _creating = false;
      _nameCtrl.clear();
    });
  }

  Future<void> _submitCreate() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      final raw = await apiClient.createVocabulary(name: name);
      final created = VocabularySummary.fromJson(raw);
      if (mounted) Navigator.pop(context, created);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('단어장 생성 실패: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.pageH,
          0,
          AppSpacing.pageH,
          AppSpacing.lg + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '단어장 선택',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (!_creating)
                  TextButton.icon(
                    onPressed: _showCreateForm,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('새 단어장'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // Inline creation form
            if (_creating) ...[
              _CreateVocabForm(
                controller: _nameCtrl,
                focusNode: _nameFocus,
                saving: _saving,
                onSubmit: _submitCreate,
                onCancel: _cancelCreate,
              ),
              const SizedBox(height: AppSpacing.sm),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.sm),
            ],

            // Vocabulary list
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (_items.isEmpty && !_creating)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text(
                  '아직 만든 단어장이 없어요.\n위 버튼으로 새 단어장을 만들어 추가해 보세요!',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              )
            else if (_items.isNotEmpty)
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 52),
                  itemBuilder: (context, index) {
                    final vocab = _items[index];
                    return ListTile(
                      dense: true,
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.book_outlined,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      title: Text(
                        vocab.name,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text('${vocab.wordCount}개 단어'),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => Navigator.pop(context, vocab),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CreateVocabForm extends StatelessWidget {
  const _CreateVocabForm({
    required this.controller,
    required this.focusNode,
    required this.saving,
    required this.onSubmit,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool saving;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '새 단어장 만들기',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: !saving,
            decoration: InputDecoration(
              hintText: '단어장 이름 (예: 비즈니스 영어)',
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: saving ? null : onCancel,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: saving ? null : onSubmit,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('만들기'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Dialog flow: pick/create vocab → confirm word (meaning optional) → POST.
Future<bool> showAddWordToVocabularyDialog(
  BuildContext context, {
  required String initialWord,
  String? linkedDiaryId,
}) async {
  final vocab = await VocabularyPickerSheet.show(context);
  if (vocab == null || !context.mounted) return false;

  return _showWordConfirmDialog(
    context,
    vocab: vocab,
    initialWord: initialWord,
    linkedDiaryId: linkedDiaryId,
  );
}

Future<bool> _showWordConfirmDialog(
  BuildContext context, {
  required VocabularySummary vocab,
  required String initialWord,
  String? linkedDiaryId,
}) async {
  final wordCtrl = TextEditingController(text: initialWord);
  final meaningCtrl = TextEditingController();

  final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => _WordConfirmDialog(
          vocab: vocab,
          wordCtrl: wordCtrl,
          meaningCtrl: meaningCtrl,
        ),
      ) ??
      false;

  if (!confirmed) return false;

  try {
    await apiClient.addVocabularyWord(
      vocab.id,
      word: wordCtrl.text.trim(),
      meaning: meaningCtrl.text.trim(),
      linkedDiaryId: linkedDiaryId,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '「${wordCtrl.text.trim()}」을(를) ${vocab.name}에 추가했습니다',
          ),
        ),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('추가 실패: $e')),
      );
    }
    return false;
  }
}

class _WordConfirmDialog extends StatefulWidget {
  const _WordConfirmDialog({
    required this.vocab,
    required this.wordCtrl,
    required this.meaningCtrl,
  });

  final VocabularySummary vocab;
  final TextEditingController wordCtrl;
  final TextEditingController meaningCtrl;

  @override
  State<_WordConfirmDialog> createState() => _WordConfirmDialogState();
}

class _WordConfirmDialogState extends State<_WordConfirmDialog> {
  bool _canAdd = true;

  @override
  void initState() {
    super.initState();
    _canAdd = widget.wordCtrl.text.trim().isNotEmpty;
    widget.wordCtrl.addListener(_onWordChanged);
  }

  @override
  void dispose() {
    widget.wordCtrl.removeListener(_onWordChanged);
    super.dispose();
  }

  void _onWordChanged() {
    final ok = widget.wordCtrl.text.trim().isNotEmpty;
    if (ok != _canAdd) setState(() => _canAdd = ok);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.book_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '「${widget.vocab.name}」에 추가',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: widget.wordCtrl,
            decoration: const InputDecoration(
              labelText: '단어 (영어)',
              border: OutlineInputBorder(),
            ),
            autofocus: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.meaningCtrl,
            decoration: InputDecoration(
              labelText: '뜻 (한국어)',
              hintText: '선택사항',
              border: const OutlineInputBorder(),
              suffixIcon: ValueListenableBuilder(
                valueListenable: widget.meaningCtrl,
                builder: (_, value, __) => value.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => widget.meaningCtrl.clear(),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            autofocus: widget.wordCtrl.text.isNotEmpty,
          ),
          const SizedBox(height: 4),
          Text(
            '뜻은 나중에 단어장에서 추가할 수 있어요',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _canAdd ? () => Navigator.pop(context, true) : null,
          child: const Text('추가'),
        ),
      ],
    );
  }
}
