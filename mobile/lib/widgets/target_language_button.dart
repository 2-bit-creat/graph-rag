import 'package:flutter/material.dart';

import '../api/client.dart';
import '../screens/tutor_screen.dart' show tutorLangLabel;
import '../theme/app_theme.dart';

/// ?¸ěëł??ę˛??¸ě´ ?í ???ëĄ?ě???ąëĄ???ěľ ?¸ě´ ě¤??ëëĽ?? í?ë¤.
///
/// ? í ???ë˛ `target_language`??ę°ąě ???ÂˇëŹ¸???ěą ???¤ëĽ¸ ?ëŠ´ęł?ë§ěś??
class TargetLanguageButton extends StatelessWidget {
  const TargetLanguageButton({
    super.key,
    required this.languages,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  final List<String> languages;
  final String selected;
  final ValueChanged<String> onChanged;
  final bool enabled;

  static const _flags = {
    'english': '?ş?¸',
    'japanese': '?Ż?ľ',
    'chinese': '?¨?ł',
    'spanish': '?Ş?¸',
    'french': '?Ť?ˇ',
    'german': '?Š?Ş',
    'portuguese': '?§?ˇ',
    'italian': '?Ž?š',
  };

  Future<void> _pick(BuildContext context) async {
    if (!enabled || languages.length <= 1) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.pageH, 0, AppSpacing.pageH, AppSpacing.sm),
              child: Text('?°ěľ ?¸ě´',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            for (final lang in languages)
              ListTile(
                leading: Text(_flags[lang] ?? '?', style: const TextStyle(fontSize: 22)),
                title: Text(tutorLangLabel(lang)),
                trailing: lang == selected
                    ? Icon(Icons.check_rounded, color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, lang),
              ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
    if (picked == null || picked == selected) return;
    try {
      await apiClient.updateActiveTargetLanguage(picked);
      onChanged(picked);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final flag = _flags[selected] ?? '?';
    final label = tutorLangLabel(selected);
    return TextButton.icon(
      onPressed: enabled && languages.length > 1 ? () => _pick(context) : null,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      icon: Text(flag, style: const TextStyle(fontSize: 16)),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          if (languages.length > 1) ...[
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)),
          ],
        ],
      ),
    );
  }
}
