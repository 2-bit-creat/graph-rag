import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';

/// Quizlet-style inline word + meaning form for a vocabulary list.
class VocabularyWordAddCard extends StatefulWidget {
  const VocabularyWordAddCard({
    super.key,
    required this.onSubmit,
    this.loading = false,
  });

  final Future<void> Function({required String word, required String meaning}) onSubmit;
  final bool loading;

  @override
  State<VocabularyWordAddCard> createState() => VocabularyWordAddCardState();
}

class VocabularyWordAddCardState extends State<VocabularyWordAddCard> {
  final _wordCtrl = TextEditingController();
  final _meaningCtrl = TextEditingController();
  final _wordFocus = FocusNode();

  @override
  void dispose() {
    _wordCtrl.dispose();
    _meaningCtrl.dispose();
    _wordFocus.dispose();
    super.dispose();
  }

  void clear() {
    _wordCtrl.clear();
    _meaningCtrl.clear();
  }

  void focusWord() {
    if (!mounted) return;
    Scrollable.ensureVisible(context, alignment: 0.1, duration: const Duration(milliseconds: 200));
    _wordFocus.requestFocus();
  }

  Future<void> _submit() async {
    final word = _wordCtrl.text.trim();
    final meaning = _meaningCtrl.text.trim();
    if (word.isEmpty || meaning.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('vocabAddCard.missingFieldsSnackbar'))),
      );
      return;
    }
    await widget.onSubmit(word: word, meaning: meaning);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AppSurfaceCard(
      tint: AppColors.accentWarm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.post_add_rounded, color: AppColors.accentWarm, size: 22),
              const SizedBox(width: AppSpacing.sm),
              Text(tr('vocabAddCard.title'), style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _wordCtrl,
            focusNode: _wordFocus,
            enabled: !widget.loading,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: tr('vocabAddCard.wordLabel'),
              hintText: tr('vocabAddCard.wordHint'),
              filled: true,
              fillColor: colorScheme.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppSpacing.radiusSm)),
            ),
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _meaningCtrl,
            enabled: !widget.loading,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: tr('vocabAddCard.meaningLabel'),
              hintText: tr('vocabAddCard.meaningHint'),
              filled: true,
              fillColor: colorScheme.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppSpacing.radiusSm)),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: widget.loading ? null : _submit,
            icon: widget.loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.add, size: 20),
            label: Text(widget.loading ? tr('vocabAddCard.addingLabel') : tr('vocabAddCard.addButton')),
          ),
        ],
      ),
    );
  }
}
