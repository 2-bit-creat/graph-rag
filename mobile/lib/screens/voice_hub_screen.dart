import 'package:flutter/material.dart';

import 'pipeline_debug_hub_screen.dart';

/// @deprecated [PipelineDebugHubScreen] 사용
class VoiceHubScreen extends StatelessWidget {
  const VoiceHubScreen({super.key, this.initialEntryId});

  final String? initialEntryId;

  @override
  Widget build(BuildContext context) {
    return PipelineDebugHubScreen(initialEntryId: initialEntryId);
  }
}

/// @deprecated [PipelineDebugHubScreen] 사용
typedef JournalPipelineHubScreen = VoiceHubScreen;
