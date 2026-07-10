import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/graph_review_panel.dart';

/// Full-screen host for [GraphReviewPanel] (PiP compose, hub detail, etc.).
class GraphReviewScreen extends StatelessWidget {
  const GraphReviewScreen({
    super.key,
    required this.entryId,
    required this.staging,
  });

  final String entryId;
  final Map<String, dynamic> staging;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('그래??검??)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageH,
            AppSpacing.md,
            AppSpacing.pageH,
            AppSpacing.md,
          ),
          child: GraphReviewPanel(
            entryId: entryId,
            staging: staging,
            maxBodyHeight: MediaQuery.sizeOf(context).height * 0.72,
            onApplied: () => Navigator.pop(context, true),
          ),
        ),
      ),
    );
  }
}
