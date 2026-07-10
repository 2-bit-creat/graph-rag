import 'dart:async';



import 'package:flutter/material.dart';



import '../api/client.dart';

import '../theme/app_theme.dart';

import '../widgets/app_ui.dart';

import '../widgets/pipeline_flow_canvas.dart';

import '../widgets/pipeline_flow_graph.dart';

import '../widgets/run_graph_ingest.dart';

import '../widgets/translation_entry_panel.dart';



Map<String, dynamic> _traceForDisplay(Map<String, dynamic> trace) {

  return trace;

}



/// Fast + Slow Path — journal entry pipeline.

class JournalPipelinePanel extends StatefulWidget {

  const JournalPipelinePanel({

    super.key,

    required this.entryId,

    required this.entry,

    required this.onRefresh,

    this.isPrecisionText = false,

  });



  final String entryId;

  final Map<String, dynamic> entry;

  final Future<void> Function({bool silent}) onRefresh;

  final bool isPrecisionText;



  @override

  State<JournalPipelinePanel> createState() => _JournalPipelinePanelState();

}



class _JournalPipelinePanelState extends State<JournalPipelinePanel> {

  Map<String, dynamic>? _trace;

  bool _loading = true;

  bool _buildingGraph = false;

  final _artifactCache = <String, String>{};

  final _canvasKey = GlobalKey<PipelineTraceCanvasState>();

  Timer? _pollTimer;



  @override

  void initState() {

    super.initState();

    _loadTrace();

    _syncPollTimer();

  }



  @override

  void dispose() {

    _pollTimer?.cancel();

    super.dispose();

  }



  void _syncPollTimer() {

    final status = widget.entry['status']?.toString() ?? '';

    if (status == 'graph_processing' && !_buildingGraph) {

      _pollTimer ??= Timer.periodic(const Duration(seconds: 4), (_) async {

        await widget.onRefresh(silent: true);

        await _loadTrace(silent: true);

      });

    } else {

      _pollTimer?.cancel();

      _pollTimer = null;

    }

  }



  @override

  void didUpdateWidget(covariant JournalPipelinePanel oldWidget) {

    super.didUpdateWidget(oldWidget);

    if (oldWidget.entryId != widget.entryId ||

        oldWidget.entry['status'] != widget.entry['status']) {

      _loadTrace(preferEmbedded: true, silent: true);

      _syncPollTimer();

    }

  }



  Future<void> _loadTrace({bool preferEmbedded = false, bool silent = false}) async {

    final embedded = widget.entry['pipeline_trace'];

    try {

      final trace = _traceForDisplay(await apiClient.getEntryTrace(widget.entryId));

      if (mounted) {

        setState(() {

          _trace = trace;

          _loading = false;

        });

      }

      return;

    } catch (_) {

      if (preferEmbedded && embedded is Map<String, dynamic>) {

        if (mounted) {

          setState(() {

            _trace = _traceForDisplay(embedded);

            _loading = false;

          });

        }

        return;

      }

      try {

        final blueprint = await apiClient.getFlowBlueprint();

        final flowLayout = blueprint['flow_layout'];

        if (mounted && flowLayout is Map) {

          setState(() {

            _trace = _traceForDisplay({

              'status': 'pending',

              'steps': <dynamic>[],

              'flow_layout': flowLayout,

            });

            _loading = false;

          });

          return;

        }

      } catch (_) {}

    }

    if (mounted) {

      setState(() {

        _trace = embedded is Map<String, dynamic>

            ? _traceForDisplay(embedded)

            : _trace;

        _loading = false;

      });

    }

  }



  Future<String> _fetchArtifact(String relativePath) async {

    if (_artifactCache.containsKey(relativePath)) {

      return _artifactCache[relativePath]!;

    }

    final text = await apiClient.fetchArtifactText(widget.entryId, relativePath);

    _artifactCache[relativePath] = text;

    return text;

  }



  Future<void> _buildGraph({bool force = false}) async {

    setState(() => _buildingGraph = true);

    _syncPollTimer();

    try {

      final finalStatus = await runGraphIngestForEntry(

        entryId: widget.entryId,

        onRefresh: widget.onRefresh,

        force: force,

      );

      if (!mounted) return;

      await _loadTrace(silent: true);

      _syncPollTimer();

      await showGraphIngestSnackBar(context, finalStatus);

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(content: Text('지식 그래프 생성 실패: $e')),

        );

      }

    } finally {

      if (mounted) {

        setState(() => _buildingGraph = false);

        _syncPollTimer();

      }

    }

  }



  @override

  Widget build(BuildContext context) {

    if (_loading) {

      return const AppLoadingScreen();

    }

    if (_trace == null) {

      return const AppLoadingScreen(message: '파이프라인 불러오는 중…');

    }



    final trace = _trace!;

    final entryStatus = widget.entry['status']?.toString() ?? '';

    final hasTranslation = (widget.entry['translation_en']?.toString() ?? '').isNotEmpty;

    final graphStarted = ((trace['steps'] as List<dynamic>? ?? [])

        .any((s) {

          final m = s as Map;

          final phase = m['phase']?.toString() ?? '';

          final name = m['name']?.toString() ?? '';

          return phase == 'graph_path' ||

              phase == 'slow_path' ||

              phase == 'manual_graph_path' ||

              name == 'slow_path_start' ||

              name == 'manual_graph_trigger';

        }));

    final manualStarted = ((trace['steps'] as List<dynamic>? ?? [])

        .any((s) => (s as Map)['phase'] == 'manual_graph_path' ||

            (s as Map)['name'] == 'manual_graph_trigger'));

    final autoStarted = graphStarted && !manualStarted;



    return RefreshIndicator(

      onRefresh: () async {

        await widget.onRefresh();

        await _loadTrace();

      },

      child: ListView(

        padding: const EdgeInsets.fromLTRB(

          AppSpacing.pageH,

          AppSpacing.md,

          AppSpacing.pageH,

          AppSpacing.lg,

        ),

        children: [

          PipelineProgressStepper(

            status: entryStatus,

            hasTranslation: hasTranslation,

            compact: true,

          ),

          const SizedBox(height: AppSpacing.md),

          TranslationEntryPanel(

            entry: widget.entry,

            entryId: widget.entryId,

            onRefresh: ({bool silent = false}) => widget.onRefresh(silent: silent),

            isPrecisionText: widget.isPrecisionText,

          ),

          const SizedBox(height: AppSpacing.lg),

          AppSectionHeader(title: '처리 파이프라인'),

          const SizedBox(height: AppSpacing.md),

          PipelineTraceCanvas(

            key: _canvasKey,

            trace: trace,

            entryId: widget.entryId,

            fetchArtifact: _fetchArtifact,

            journalMode: true,

            textPipelineMode: widget.isPrecisionText,

          ),

          const SizedBox(height: 16),

          SlowPathActionCard(

            status: entryStatus,

            building: _buildingGraph,

            pendingSpeakerLabels: pendingSpeakerLabels(

              widget.entry['speaker_summaries'] as List<dynamic>? ?? [],

            ),

            onBuildGraph: () => _buildGraph(),

            onForceRebuild: () => _buildGraph(force: true),

            onRefreshStatus: () async {

              await widget.onRefresh(silent: true);

              await _loadTrace(silent: true);

            },

          ),

          if (manualStarted)

            Padding(

              padding: const EdgeInsets.only(top: 8),

              child: Text(

                'Graph Path — Semantic Chunk ingest (Chunk · Speaker · Vocab · Concept)',

                style: TextStyle(fontSize: 11, color: Colors.teal[700]),

              ),

            ),

          if (autoStarted)

            Padding(

              padding: const EdgeInsets.only(top: 8),

              child: Text(

                'Graph Path — Semantic Chunk ingest (자동)',

                style: TextStyle(fontSize: 11, color: context.mutedText),

              ),

            ),

        ],

      ),

    );

  }

}

