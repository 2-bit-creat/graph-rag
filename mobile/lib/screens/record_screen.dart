import 'package:flutter/material.dart';

import 'journal_compose_screen.dart';

/// @deprecated [JournalComposeScreen] 사용
class RecordScreen extends StatelessWidget {
  const RecordScreen({super.key, this.initialMode = JournalInputMode.voice});

  final JournalInputMode initialMode;

  @override
  Widget build(BuildContext context) {
    return JournalComposeScreen(initialMode: initialMode);
  }
}
