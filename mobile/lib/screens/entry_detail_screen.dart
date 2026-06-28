import 'package:flutter/material.dart';

import 'pipeline_debug_hub_screen.dart';

/// @deprecated [PipelineDebugHubScreen]으로 리다이렉트.
class EntryDetailScreen extends StatelessWidget {
  const EntryDetailScreen({
    super.key,
    required this.entryId,
    this.initialEntry,
    this.initialTab = 0,
  });

  final String entryId;
  final Map<String, dynamic>? initialEntry;
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return PipelineDebugHubScreen(initialEntryId: entryId);
  }
}
