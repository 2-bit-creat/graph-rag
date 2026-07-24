import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/graph_chat_panel.dart' show GraphChatMessage;
import 'chat_session_controller.dart' show ChatMode;

/// One tappable option offered above the composer.
///
/// A text-only conversational UI makes the user carry the whole burden of
/// phrasing every turn. Offering the likely next moves as buttons cuts that
/// cost and doubles as a discovery surface for modes buried in the "+" menu.
@immutable
class ChatSuggestion {
  const ChatSuggestion.prompt(this.label, {this.icon, this.tint})
      : send = label,
        action = null;

  /// Sends [send] as a message while showing a different [label].
  const ChatSuggestion.say(this.label, this.send, {this.icon, this.tint})
      : action = null;

  /// Switches the composer into a mode ('journal' | 'distill' | 'composition'
  /// | 'word') instead of sending text — same keys the "+" menu emits.
  const ChatSuggestion.action(this.label, this.action, {this.icon, this.tint})
      : send = null;

  final String label;
  final IconData? icon;
  final Color? tint;

  /// Non-null for prompt chips: the text handed to the composer's send path.
  final String? send;

  /// Non-null for action chips: the mode key handed to `onModeSelected`.
  final String? action;

  bool get isAction => action != null;
}

/// Starter options for a conversation that hasn't begun yet.
///
/// Scoped deliberately to the empty state. An always-present rail is a layer
/// floating over the live feed — it competes with the messages for attention
/// every turn and pushes the feed's tail around as it grows. Once there is a
/// conversation to read, the rail gets out of the way entirely; the "+" menu
/// remains the way into every mode.
///
/// Client-side and deterministic: no extra round-trip, nothing to wait for.
List<ChatSuggestion> chatSuggestionsFor({
  required ChatMode mode,
  required List<GraphChatMessage> messages,
  required bool busy,
  bool journalBusy = false,
}) {
  if (busy || mode != ChatMode.normal) return const [];

  // Anything the user can read as "a conversation happened here" — including
  // a saved diary entry — ends the starter state.
  final started = messages
      .any((m) => m.kind == 'text' || m.kind == 'journal_submit');
  if (started) return const [];

  return [
    if (!journalBusy)
      ChatSuggestion.action(
        tr('chat.menu.journal'),
        'journal',
        icon: Icons.auto_stories_rounded,
        tint: AppColors.hubVoice,
      ),
    ChatSuggestion.prompt(tr('chat.suggest.start.whatsInGraph')),
    ChatSuggestion.prompt(tr('chat.suggest.start.recentThemes')),
    ChatSuggestion.action(
      tr('chat.menu.word'),
      'word',
      icon: Icons.style_rounded,
      tint: AppColors.hubQuiz,
    ),
    ChatSuggestion.action(
      tr('chat.menu.composition'),
      'composition',
      icon: Icons.edit_note_rounded,
      tint: AppColors.hubQuiz,
    ),
  ];
}
