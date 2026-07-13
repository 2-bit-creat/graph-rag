import 'package:flutter/material.dart';

import '../api/client.dart';
import '../widgets/app_ui.dart';
import '../widgets/pipeline_flow_canvas.dart';
import '../widgets/quiz_pipeline_panel.dart';
import 'quiz_queue_screen.dart';

class QuizPipelineHubScreen extends StatefulWidget {
  const QuizPipelineHubScreen({super.key, this.initialQuizId});

  final String? initialQuizId;

  @override
  State<QuizPipelineHubScreen> createState() => _QuizPipelineHubScreenState();
}

class _QuizPipelineHubScreenState extends State<QuizPipelineHubScreen> {
  List<dynamic> _items = [];
  Map<String, dynamic>? _trace;
  Map<String, dynamic>? _selected;
  Map<String, dynamic>? _profile;
  List<dynamic> _vocabularies = [];
  bool _loading = true;
  bool _traceLoading = false;
  final _canvasKey = GlobalKey<PipelineTraceCanvasState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] true — 생성·당겨서 새로고침 시 전체 화면 로딩 없이 갱신.
  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final data = await apiClient.listQuizGenerations();
      Map<String, dynamic>? profile;
      List<dynamic> vocabs = [];
      try {
        profile = await apiClient.getQuizProfile();
      } catch (_) {}
      try {
        vocabs = await apiClient.listVocabularies();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _items = ((data['items'] as List<dynamic>?) ?? [])
            .where((item) {
              final type = (item as Map)['quiz_type']?.toString();
              return type == 'cloze' || type == 'composition';
            })
            .toList();
        _profile = profile;
        _vocabularies = vocabs;
        _loading = false;
      });
      if (widget.initialQuizId != null && _selected == null) {
        await _select(widget.initialQuizId!);
      } else if (_items.isNotEmpty && _selected == null) {
        await _select(_items.first['id']?.toString() ?? '');
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _afterGenerate(String quizId) async {
    try {
      final data = await apiClient.listQuizGenerations();
      if (!mounted) return;
      setState(() {
        _items = ((data['items'] as List<dynamic>?) ?? [])
            .where((item) {
              final type = (item as Map)['quiz_type']?.toString();
              return type == 'cloze' || type == 'composition';
            })
            .toList();
      });
      await _select(quizId);
    } catch (_) {}
  }

  Future<void> _select(String quizId) async {
    if (quizId.isEmpty) return;
    Map<String, dynamic> selected = {'id': quizId};
    for (final item in _items) {
      if (item is Map && item['id']?.toString() == quizId) {
        selected = Map<String, dynamic>.from(item);
        break;
      }
    }
    if (mounted) {
      setState(() {
        _traceLoading = true;
        _selected = selected;
      });
    }
    try {
      final trace = await apiClient.getQuizGenerationTrace(quizId);
      if (mounted) {
        setState(() {
          _trace = trace;
          _traceLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _traceLoading = false);
    }
  }

  Future<void> _onQuizDeleted(String quizId) async {
    if (_selected?['id']?.toString() == quizId) {
      if (mounted) {
        setState(() {
          _selected = null;
          _trace = null;
        });
      }
    }
    await _load(silent: true);
    if (_items.isNotEmpty && _selected == null) {
      await _select(_items.first['id']?.toString() ?? '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppHubAppBar(
        title: '문제 생성',
        subtitle: '개발자 도구 · Quiz Path trace',
        actions: [
          IconButton(
            icon: const Icon(Icons.inventory_2_outlined),
            tooltip: '학습 큐',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const QuizQueueScreen()),
            ),
          ),
        ],
      ),
      body: _loading
          ? const AppLoadingScreen(message: '생성 기록 불러오는 중…')
          : QuizPipelinePanel(
              items: _items,
              profile: _profile,
              vocabularies: const [],
              selected: _selected,
              trace: _trace,
              traceLoading: _traceLoading,
              canvasKey: _canvasKey,
              onSelect: _select,
              onRefresh: () => _load(silent: true),
              onAfterGenerate: _afterGenerate,
              onQuizDeleted: _onQuizDeleted,
            ),
    );
  }
}
