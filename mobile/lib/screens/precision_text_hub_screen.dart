import 'package:flutter/material.dart';

import 'journal_compose_screen.dart';
import 'journal_hub_screen.dart';

/// @deprecated [JournalHubScreen] / [JournalComposeScreen]으로 통합됨
class PrecisionTextHubScreen extends StatelessWidget {
  const PrecisionTextHubScreen({super.key, this.initialEntryId});

  final String? initialEntryId;

  @override
  Widget build(BuildContext context) {
    return JournalHubScreen(initialEntryId: initialEntryId);
  }
}

/// @deprecated [JournalComposeScreen] 사용
class PrecisionTextHubPage extends StatelessWidget {
  const PrecisionTextHubPage({super.key, this.initialEntryId});

  final String? initialEntryId;

  @override
  Widget build(BuildContext context) {
    if (initialEntryId != null) {
      return JournalHubScreen(initialEntryId: initialEntryId);
    }
    return const JournalComposeScreen(initialMode: JournalInputMode.text);
  }
}
