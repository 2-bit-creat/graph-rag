import 'package:flutter/material.dart';

import 'voice_hub_screen.dart';

/// @deprecated [VoiceHubScreen]으로 통합됨
class TranslationHubScreen extends StatelessWidget {
  const TranslationHubScreen({super.key, this.initialEntryId});

  final String? initialEntryId;

  @override
  Widget build(BuildContext context) {
    return VoiceHubScreen(initialEntryId: initialEntryId);
  }
}
