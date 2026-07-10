import 'package:flutter/material.dart';

import 'chat/chat_session_controller.dart';

/// 猷⑦듃 ?대퉬寃뚯씠????????梨꾪똿)?쇰줈 蹂듦??????ъ슜.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// PiP ?놁씠 ?몃씪???쇨린 ?묒꽦 紐⑤뱶濡?吏꾩엯?쒕떎.
void openInlineJournalCompose() {
  final nav = appNavigatorKey.currentState;
  if (nav != null) {
    nav.popUntil((route) => route.isFirst);
  }
  chatSession.enterJournalMode();
}
