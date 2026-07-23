import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../theme/app_theme.dart';
import '../utils/chat_message_format.dart';

/// Chat-optimized rich text: bold, inline LaTeX, display LaTeX blocks.
class ChatRichText extends StatelessWidget {
  const ChatRichText({
    super.key,
    required this.text,
    this.style,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  static TextStyle defaultStyle(BuildContext context) {
    return TextStyle(
      color: context.shell.primaryText,
      height: 1.45,
      fontSize: 13,
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? defaultStyle(context);
    final parts = splitChatMessageParts(text);

    if (parts.length == 1 && parts.first.kind == ChatMessagePartKind.text) {
      return _ProseBlock(
        text: parts.first.content,
        style: baseStyle,
        textAlign: textAlign,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          switch (parts[i].kind) {
            ChatMessagePartKind.text => _ProseBlock(
                text: parts[i].content,
                style: baseStyle,
                textAlign: textAlign,
              ),
            ChatMessagePartKind.displayMath => _DisplayMath(
                latex: parts[i].content,
                style: baseStyle,
                textAlign: textAlign,
              ),
            ChatMessagePartKind.code => _CodeBlock(
                code: parts[i].content,
                language: parts[i].language,
              ),
          },
        ],
      ],
    );
  }
}

class _ProseBlock extends StatelessWidget {
  const _ProseBlock({
    required this.text,
    required this.style,
    this.textAlign,
  });

  final String text;
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final inline = parseChatInlineParts(text);
    if (inline.isEmpty) {
      return SelectableText(text, style: style, textAlign: textAlign);
    }

    return SelectableText.rich(
      TextSpan(
        children: [
          for (final part in inline)
            switch (part.kind) {
              ChatInlinePartKind.text =>
                TextSpan(text: part.content, style: style),
              ChatInlinePartKind.bold => TextSpan(
                  text: part.content,
                  style: style.copyWith(fontWeight: FontWeight.w700),
                ),
              ChatInlinePartKind.inlineMath => WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _InlineMath(latex: part.content, style: style),
                  ),
                ),
              ChatInlinePartKind.inlineCode => WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _InlineCode(text: part.content, style: style),
                ),
            },
        ],
      ),
      style: style,
      textAlign: textAlign,
    );
  }
}

class _InlineMath extends StatelessWidget {
  const _InlineMath({required this.latex, required this.style});

  final String latex;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final normalized = normalizeChatLatex(latex);
    return Math.tex(
      normalized,
      mathStyle: MathStyle.text,
      textStyle: style.copyWith(
        fontSize: (style.fontSize ?? 13) + 0.5,
        color: (style.color ?? context.shell.primaryText)
            .withValues(alpha: 0.96),
      ),
      onErrorFallback: (err) => Text(
        '\$$normalized\$',
        style: style.copyWith(
          fontFamily: 'monospace',
          fontSize: 12,
          color: AppColors.accentWarm.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

/// Inline `code` — monospace chip on a faint surface, sized to the line.
class _InlineCode extends StatelessWidget {
  const _InlineCode({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: context.shell.subtleSurface,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: context.shell.panelBorder.withValues(alpha: 0.6)),
      ),
      child: Text(
        text,
        style: style.copyWith(
          fontFamily: 'monospace',
          fontSize: (style.fontSize ?? 13) - 0.5,
          color: AppColors.accent,
          height: 1.2,
        ),
      ),
    );
  }
}

/// Fenced ```code``` block: language label + one-tap copy, horizontally
/// scrollable monospace body on a recessed surface.
class _CodeBlock extends StatefulWidget {
  const _CodeBlock({required this.code, this.language});

  final String code;
  final String? language;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    HapticFeedback.selectionClick();
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: shell.subtleSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: shell.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: language tag + copy affordance.
          Container(
            padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: shell.panelBorder.withValues(alpha: 0.7)),
              ),
            ),
            child: Row(
              children: [
                Text(
                  (widget.language ?? 'code').toLowerCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: shell.mutedText,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: _copy,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 13,
                          color: _copied ? AppColors.accent : shell.mutedText,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? '복사됨' : '복사',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _copied ? AppColors.accent : shell.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Body.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SelectableText(
              widget.code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.5,
                color: shell.primaryText.withValues(alpha: 0.95),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DisplayMath extends StatelessWidget {
  const _DisplayMath({
    required this.latex,
    required this.style,
    this.textAlign,
  });

  final String latex;
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final normalized = normalizeChatLatex(latex);
    final align = textAlign ?? TextAlign.center;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: context.shell.subtleSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.shell.panelBorder),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Align(
          alignment: align == TextAlign.center
              ? Alignment.center
              : Alignment.centerLeft,
          child: Math.tex(
            normalized,
            mathStyle: MathStyle.display,
            textStyle: style.copyWith(
              fontSize: 15,
              color: (style.color ?? context.shell.primaryText)
                  .withValues(alpha: 0.98),
            ),
            onErrorFallback: (err) => SelectableText(
              '\\[$normalized\\]',
              style: style.copyWith(
                fontFamily: 'monospace',
                fontSize: 12,
                color: AppColors.accentWarm.withValues(alpha: 0.9),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
