import 'package:flutter/material.dart';

import 'kg_debug_screen.dart';
import 'quiz_pipeline_hub_screen.dart';

/// Which tab to open on. KG and Pipeline used to be two separate screens
/// showing the same underlying trace data (JournalEntry.pipeline_trace);
/// this hub merges them and adds the quiz generation history as a second tab.
enum DebugHubTab { kg, quiz }

class DebugHubScreen extends StatefulWidget {
  const DebugHubScreen({
    super.key,
    this.initialTab = DebugHubTab.kg,
    this.initialQuizId,
  });

  final DebugHubTab initialTab;
  final String? initialQuizId;

  @override
  State<DebugHubScreen> createState() => _DebugHubScreenState();
}

class _DebugHubScreenState extends State<DebugHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab == DebugHubTab.quiz ? 1 : 0,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('디버그'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'KG 이력'),
            Tab(text: '퀴즈 생성 이력'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          const KgDebugScreen(),
          QuizPipelineHubScreen(
            initialQuizId: widget.initialQuizId,
            showAppBar: false,
          ),
        ],
      ),
    );
  }
}
