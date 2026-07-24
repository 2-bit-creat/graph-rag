import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_suggestions.dart';
import '../theme/app_theme.dart';

/// Horizontal strip of tappable options docked just above the composer.
///
/// Sits in the "keypad area" — the band between the feed and the input pill —
/// so the likely next turn is always one tap away instead of something the
/// user has to type from scratch. Scrolls horizontally with soft fade edges so
/// a long option set never wraps into a second row that would eat the feed.
class ChatSuggestionRail extends StatelessWidget {
  const ChatSuggestionRail({
    super.key,
    required this.suggestions,
    required this.onPrompt,
    required this.onAction,
  });

  final List<ChatSuggestion> suggestions;

  /// Fired for prompt chips with the text to send.
  final ValueChanged<String> onPrompt;

  /// Fired for action chips with the mode key ('journal' | 'distill' | …).
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    // Animate the whole rail's presence so entering/leaving a mode swaps the
    // option set with a glide instead of a jump cut.
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: suggestions.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: 34,
                child: ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: [0, 0.035, 0.965, 1],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    itemCount: suggestions.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, i) => _SuggestionChip(
                      // Keyed by content so re-ordering the set doesn't replay
                      // the entrance on chips that were already on screen.
                      key: ValueKey(
                          '${suggestions[i].label}|${suggestions[i].action}'),
                      suggestion: suggestions[i],
                      index: i,
                      onTap: () {
                        final s = suggestions[i];
                        HapticFeedback.selectionClick();
                        if (s.isAction) {
                          onAction(s.action!);
                        } else {
                          onPrompt(s.send!);
                        }
                      },
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// A single option pill. Action chips (mode switches) carry their hub color so
/// they read as a different class of move than a plain follow-up question.
class _SuggestionChip extends StatefulWidget {
  const _SuggestionChip({
    super.key,
    required this.suggestion,
    required this.index,
    required this.onTap,
  });

  final ChatSuggestion suggestion;
  final int index;
  final VoidCallback onTap;

  @override
  State<_SuggestionChip> createState() => _SuggestionChipState();
}

class _SuggestionChipState extends State<_SuggestionChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  @override
  void initState() {
    super.initState();
    // Staggered so the set unfurls left-to-right rather than popping at once.
    Future.delayed(Duration(milliseconds: 40 * widget.index), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final s = widget.suggestion;
    final tint = s.tint;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = tint == null
        ? shell.primaryText.withValues(alpha: 0.88)
        : (isDark ? _lighten(tint, 0.28) : _darken(tint, 0.12));

    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: AnimatedBuilder(
        animation: curve,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, (1 - curve.value) * 6),
          child: child,
        ),
        child: Material(
          // Composited against the bar background rather than layered with
          // alpha: the rail floats over the live feed, and a translucent chip
          // lets whatever message is scrolling underneath read straight
          // through it.
          color: tint == null
              ? shell.barBackground
              : Color.alphaBlend(
                  tint.withValues(alpha: isDark ? 0.20 : 0.10),
                  shell.barBackground,
                ),
          shape: StadiumBorder(
            side: BorderSide(
              color: tint == null
                  ? shell.panelBorder
                  : tint.withValues(alpha: isDark ? 0.45 : 0.35),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (s.icon != null) ...[
                    Icon(s.icon, size: 14, color: labelColor),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    s.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                      color: labelColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _lighten(Color c, double amount) =>
    Color.lerp(c, Colors.white, amount) ?? c;

Color _darken(Color c, double amount) =>
    Color.lerp(c, Colors.black, amount) ?? c;
