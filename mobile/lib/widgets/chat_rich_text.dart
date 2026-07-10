import 'package:flutter/material.dart';
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
