import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../screens/quiz_session_screen.dart';
import 'pipeline_flow_canvas.dart';

Map<String, dynamic> quizOnlyTrace(Map<String, dynamic> trace) {
  final layout = trace['flow_layout'];
  if (layout is! Map) return trace;
  final copy = Map<String, dynamic>.from(trace);
  final layoutCopy = Map<String, dynamic>.from(layout);
  layoutCopy['nodes'] = (layout['nodes'] as List<dynamic>? ?? [])
      .where((n) => (n as Map)['phase']?.toString() == 'quiz_path')
      .toList();
  layoutCopy['edges'] = (layout['edges'] as List<dynamic>? ?? [])
      .where((e) {
        final edge = e as Map;
        final src = edge['source']?.toString() ?? '';
        final tgt = edge['target']?.toString() ?? '';
        return src.startsWith('quiz_') || tgt.startsWith('quiz_');
      })
      .toList();
  layoutCopy['phases'] = (layout['phases'] as List<dynamic>? ?? [])
      .where((p) => (p as Map)['id']?.toString() == 'quiz_path')
      .toList();
  copy['flow_layout'] = layoutCopy;
  copy['steps'] = (trace['steps'] as List<dynamic>? ?? [])
      .where((s) => (s as Map)['phase']?.toString() == 'quiz_path')
      .toList();
  return copy;
}

String quizTypeLabel(String type) {
  switch (type) {
    case 'cloze':
      return '단어 완성';
    case 'scramble':
      return '문장 배열';
    case 'mcq_nuance':
      return '뉘앙스 선택';
    default:
      return type;
  }
}

/// 지식 그래프 기반 Quiz Path — 생성 버튼 + 파이프라인 + 생성 기록.
class QuizPipelinePanel extends StatefulWidget {
  const QuizPipelinePanel({
    super.key,
    required this.items,
    required this.profile,
    required this.onRefresh,
    this.vocabularies = const [],
    this.selected,
    this.trace,
    this.traceLoading = false,
    this.onSelect,
    this.canvasKey,
    this.onAfterGenerate,
    this.onQuizDeleted,
    // Legacy — ignored
    this.onFreedomChanged,
    this.isFreedomOn,
    this.selectedVocabId,
    this.onVocabChanged,
  });

  final List<dynamic> items;
  final Map<String, dynamic>? profile;
  final Future<void> Function() onRefresh;
  final List<dynamic> vocabularies;
  final Map<String, dynamic>? selected;
  final Map<String, dynamic>? trace;
  final bool traceLoading;
  final ValueChanged<String>? onSelect;
  final GlobalKey<PipelineTraceCanvasState>? canvasKey;
  final Future<void> Function(String quizId)? onAfterGenerate;
  final Future<void> Function(String quizId)? onQuizDeleted;
  // Legacy (ignored)
  final Future<void> Function(bool)? onFreedomChanged;
  final bool? isFreedomOn;
  final String? selectedVocabId;
  final ValueChanged<String>? onVocabChanged;

  @override
  State<QuizPipelinePanel> createState() => _QuizPipelinePanelState();
}

class _QuizPipelinePanelState extends State<QuizPipelinePanel> {
  Map<String, dynamic>? _pendingTrace;
  bool _blueprintLoading = true;
  String? _blueprintError;
  String? _generating;
  String? _selectedLanguage;  // null = first target language from profile
  String? _selectedVocabId;   // null = auto (default:language)
  final _artifactCache = <String, String>{};

  @override
  void initState() {
    super.initState();
    _loadBlueprint();
  }

  Future<void> _loadBlueprint() async {
    Map<String, dynamic>? trace;
    String? error;

    try {
      final bp = await apiClient.getQuizFlowBlueprint();
      final layout = bp['flow_layout'];
      if (layout is Map) {
        trace = {
          'status': 'pending',
          'steps': <dynamic>[],
          'flow_layout': layout,
        };
      }
    } catch (_) {
      try {
        final bp = await apiClient.getFlowBlueprint();
        final layout = bp['flow_layout'];
        if (layout is Map) {
          final filtered = quizOnlyTrace({
            'status': 'pending',
            'steps': <dynamic>[],
            'flow_layout': layout,
          });
          final nodes =
              (filtered['flow_layout'] as Map?)?['nodes'] as List<dynamic>? ?? [];
          if (nodes.isNotEmpty) trace = filtered;
        }
      } catch (_) {}
    }

    if (trace == null) {
      error =
          'Quiz Path 파이프라인을 불러올 수 없습니다.\n'
          '백엔드를 최신 코드로 재시작했는지 확인하세요.';
    }

    if (mounted) {
      setState(() {
        _pendingTrace = trace;
        _blueprintError = error;
        _blueprintLoading = false;
      });
    }
  }

  Map<String, dynamic>? get _displayTrace {
    if (widget.trace != null) return quizOnlyTrace(widget.trace!);
    return _pendingTrace;
  }

  Future<String> _fetchArtifact(String relativePath) async {
    final quizId = widget.selected?['id']?.toString();
    if (quizId == null) return '';
    final key = '$quizId::$relativePath';
    if (_artifactCache.containsKey(key)) return _artifactCache[key]!;
    final text = await apiClient.fetchQuizArtifactText(quizId, relativePath);
    _artifactCache[key] = text;
    return text;
  }

  Future<bool> _confirmDelete(String quizId) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('문제 삭제'),
            content: const Text('이 문제를 완전히 삭제할까요?\n학습 큐에서도 제거됩니다.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return false;

    try {
      await apiClient.deleteQuizItem(quizId, permanent: true);
      if (!mounted) return true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('문제를 삭제했습니다')),
      );
      if (widget.onQuizDeleted != null) {
        await widget.onQuizDeleted!(quizId);
      } else {
        await widget.onRefresh();
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('삭제 실패: $e')),
        );
      }
      return false;
    }
  }

  Future<void> _generate(String quizType) async {
    setState(() => _generating = quizType);
    try {
      final result = await apiClient.generateQuizGraph(
        quizType,
        selectedVocabId: _selectedVocabId,
        language: _selectedLanguage,
      );
      final quizId = result['quiz_id']?.toString();
      if (quizId != null) {
        if (widget.onAfterGenerate != null) {
          await widget.onAfterGenerate!(quizId);
        } else {
          await widget.onRefresh();
          widget.onSelect?.call(quizId);
        }
      } else {
        await widget.onRefresh();
      }
      if (!mounted) return;
      widget.canvasKey?.currentState?.focusQuizPath();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${quizTypeLabel(quizType)} 생성 완료 · Lv.${result['difficulty_level']}')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('생성 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _generating = null);
    }
  }

  String _itemSubtitle(Map<String, dynamic> item) {
    final created = DateTime.tryParse(item['created_at']?.toString() ?? '');
    final date = created != null
        ? DateFormat('M/d HH:mm').format(created.toLocal())
        : '';
    final node = item['target_node']?.toString() ?? '';
    final type = quizTypeLabel(item['quiz_type']?.toString() ?? '');
    final source = item['source_label']?.toString() ?? '';
    return [date, type, source, node].where((s) => s.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final trace = _displayTrace;
    final quizId = widget.selected?['id']?.toString();
    final quizStarted = (trace?['steps'] as List<dynamic>? ?? [])
        .any((s) => (s as Map)['phase']?.toString() == 'quiz_path');

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageH,
          AppSpacing.md,
          AppSpacing.pageH,
          AppSpacing.xxl,
        ),
        children: [
          QuizGraphGenerateCard(
            profile: widget.profile,
            generating: _generating,
            vocabularies: widget.vocabularies,
            selectedLanguage: _selectedLanguage,
            selectedVocabId: _selectedVocabId,
            onLanguageChanged: (lang) => setState(() {
              _selectedLanguage = lang;
              _selectedVocabId = null; // reset vocab when language changes
            }),
            onVocabChanged: (v) => setState(() => _selectedVocabId = v),
            onGenerate: _generate,
            onPlay: (type) => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => QuizSessionScreen(
                  quizType: type,
                  vocabSource: _selectedVocabId,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(
            title: 'Quiz Path 파이프라인',
            subtitle: widget.selected != null
                ? '선택: ${quizTypeLabel(widget.selected!['quiz_type']?.toString() ?? '')} · Lv.${widget.selected!['difficulty_level']}'
                : '생성 전에도 흐름을 확인할 수 있습니다',
          ),
          const SizedBox(height: AppSpacing.md),
          if (_blueprintLoading)
            const SizedBox(
              height: 160,
              child: AppLoadingScreen(),
            )
          else if (_blueprintError != null && widget.trace == null)
            AppSurfaceCard(
              tint: Colors.orange,
              child: Text(
                _blueprintError!,
                style: TextStyle(fontSize: 13, color: Colors.orange.shade900),
              ),
            )
          else if (_displayTrace == null)
            const SizedBox(
              height: 100,
              child: AppLoadingScreen(message: '파이프라인 불러오는 중…'),
            )
          else
            Stack(
              children: [
                PipelineTraceCanvas(
                  key: widget.canvasKey,
                  trace: _displayTrace!,
                  entryId: quizId,
                  fetchArtifact: quizId != null ? _fetchArtifact : null,
                  quizMode: true,
                ),
                if (widget.traceLoading)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.white.withValues(alpha: 0.55),
                      child: const Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          if (quizStarted)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                '노드 탭 → 단계별 input/output · artifacts',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (widget.selected != null && !widget.traceLoading) ...[
            const SizedBox(height: AppSpacing.lg),
            _SelectedQuizCard(
              item: widget.selected!,
              quizId: quizId,
              onDelete: quizId == null ? null : () => _confirmDelete(quizId),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(title: '생성 기록 (${widget.items.length})'),
          const SizedBox(height: AppSpacing.md),
          if (widget.items.isEmpty)
            AppEmptyState(
              icon: Icons.quiz_outlined,
              title: '아직 생성 기록이 없습니다',
              subtitle: '위 버튼으로 문제를 만들어 보세요',
            )
          else
            ...widget.items.map((raw) {
              final item = raw as Map<String, dynamic>;
              final id = item['id']?.toString() ?? '';
              final selected = widget.selected?['id']?.toString() == id;
              final type = item['quiz_type']?.toString() ?? 'cloze';
              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Card(
                  color: selected
                      ? Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: 0.35)
                      : null,
                  child: ListTile(
                  dense: true,
                  title: Text(
                    item['context_sentence']?.toString() ?? '(문제)',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(_itemSubtitle(item)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '풀기',
                        icon: const Icon(Icons.play_circle_outline, size: 22),
                        onPressed: id.isEmpty
                            ? null
                            : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => QuizSessionScreen(
                                      quizType: type,
                                      quizIds: [id],
                                    ),
                                  ),
                                ),
                      ),
                      IconButton(
                        tooltip: '삭제',
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: id.isEmpty ? null : () => _confirmDelete(id),
                      ),
                      if (selected)
                        Icon(Icons.check_circle,
                            size: 18, color: Theme.of(context).colorScheme.primary),
                    ],
                  ),
                  onTap: id.isEmpty ? null : () => widget.onSelect?.call(id),
                ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _SelectedQuizCard extends StatelessWidget {
  const _SelectedQuizCard({
    required this.item,
    this.quizId,
    this.onDelete,
  });

  final Map<String, dynamic> item;
  final String? quizId;
  final Future<bool> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      tint: AppColors.hubQuiz,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            item['context_sentence']?.toString() ?? '(문제)',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: quizId == null
                      ? null
                      : () {
                          final id = quizId!;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => QuizSessionScreen(
                                quizType: item['quiz_type']?.toString() ?? 'cloze',
                                quizIds: [id],
                              ),
                            ),
                          );
                        },
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('이 문제 풀기'),
                ),
              ),
              if (onDelete != null) ...[
                const SizedBox(width: AppSpacing.sm),
                IconButton.outlined(
                  tooltip: '삭제',
                  onPressed: () => onDelete!(),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 3종 퀴즈 수동 생성 — 지식 그래프 기반.
class QuizGraphGenerateCard extends StatelessWidget {
  const QuizGraphGenerateCard({
    super.key,
    required this.profile,
    required this.generating,
    required this.onGenerate,
    this.vocabularies = const [],
    this.selectedLanguage,
    this.selectedVocabId,
    this.onLanguageChanged,
    this.onVocabChanged,
    this.onPlay,
  });

  final Map<String, dynamic>? profile;
  final String? generating;
  final Future<void> Function(String quizType) onGenerate;
  final List<dynamic> vocabularies;
  final String? selectedLanguage;
  final String? selectedVocabId;
  final ValueChanged<String>? onLanguageChanged;
  final ValueChanged<String>? onVocabChanged;
  final void Function(String quizType)? onPlay;

  static const _buttons = [
    (type: 'cloze', icon: Icons.spellcheck, label: '단어 완성 퀴즈', primary: true),
    (type: 'scramble', icon: Icons.reorder, label: '문장 배열 퀴즈', primary: false),
    (type: 'mcq_nuance', icon: Icons.psychology_alt, label: '뉘앙스 선택 퀴즈', primary: false),
  ];

  static const _kLangMeta = {
    'english':    (label: '영어 🇺🇸'),
    'german':     (label: '독일어 🇩🇪'),
    'japanese':   (label: '일본어 🇯🇵'),
    'chinese':    (label: '중국어 🇨🇳'),
    'spanish':    (label: '스페인어 🇪🇸'),
    'french':     (label: '프랑스어 🇫🇷'),
    'portuguese': (label: '포르투갈어 🇧🇷'),
    'italian':    (label: '이탈리아어 🇮🇹'),
  };

  String get _settingsHint {
    final s = profile?['selection_settings'];
    if (s is! Map) return '';
    final nodes = s['quiz_max_nodes'];
    if (nodes == null) return '';
    final hops = s['quiz_max_hops'];
    final rw = s['quiz_recency_weight'];
    final pct = rw is num ? (rw * 100).round() : 70;
    return '그래프 선택: max_nodes=$nodes, hops=$hops, $pct/30';
  }

  List<({String key, String label})> get _availableLanguages {
    final rawLangs = profile?['target_languages'];
    final List<String> langs;
    if (rawLangs is List && rawLangs.isNotEmpty) {
      langs = rawLangs.map((e) => e.toString()).toList();
    } else {
      langs = [profile?['target_language']?.toString() ?? 'english'];
    }
    return langs.map((k) {
      final meta = _kLangMeta[k];
      return (key: k, label: meta?.label ?? k);
    }).toList();
  }

  String get _effectiveLang =>
      selectedLanguage ?? _availableLanguages.firstOrNull?.key ?? 'english';

  /// Vocab sets for the currently selected language.
  List<Map<String, dynamic>> _vocabsForLang(String lang) {
    final result = <Map<String, dynamic>>[];
    for (final raw in vocabularies) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString() ?? '';
      final vocabLang = raw['language']?.toString() ?? 'english';
      // Match language explicitly or infer from id prefix
      String inferredLang = vocabLang;
      if (id.startsWith('statement_bank:')) {
        inferredLang = id.split(':')[1];
      } else if (id.startsWith('default:')) {
        inferredLang = id.split(':')[1];
      }
      if (inferredLang == lang) {
        result.add(Map<String, dynamic>.from(raw));
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final langs = _availableLanguages;
    final effectiveLang = _effectiveLang;
    final filteredVocabs = _vocabsForLang(effectiveLang);

    // Auto-select default if nothing picked or picked doesn't match language
    String? effectiveVocabId = selectedVocabId;
    if (effectiveVocabId == null ||
        !filteredVocabs.any((v) => v['id']?.toString() == effectiveVocabId)) {
      effectiveVocabId = filteredVocabs.firstOrNull?['id']?.toString();
    }
    // Commit the resolved fallback back into parent state so what's DISPLAYED is
    // always what gets SENT on generate. Without this, the dropdown showed a
    // default while the request carried a stale/null vocab id (the "selected 학습
    // 표현 but got IELTS" bug).
    if (effectiveVocabId != null && effectiveVocabId != selectedVocabId) {
      final resolved = effectiveVocabId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onVocabChanged?.call(resolved);
      });
    }

    return AppSurfaceCard(
      tint: AppColors.hubQuiz,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.hubQuiz.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.auto_awesome_rounded, color: AppColors.hubQuiz, size: 22),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('문제 생성', style: Theme.of(context).textTheme.titleSmall),
                    if (_settingsHint.isNotEmpty)
                      Text(_settingsHint, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          // ── Language chips ───────────────────────────────────────────────
          if (langs.length > 1) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('언어', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: langs.map((l) => ChoiceChip(
                label: Text(l.label, style: const TextStyle(fontSize: 12)),
                selected: effectiveLang == l.key,
                onSelected: generating != null
                    ? null
                    : (_) => onLanguageChanged?.call(l.key),
              )).toList(),
            ),
          ],
          // ── Vocab set selector ───────────────────────────────────────────
          const SizedBox(height: AppSpacing.sm),
          Text('단어장 소스', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          if (filteredVocabs.isEmpty)
            Text(
              '이 언어에 해당하는 단어장이 없습니다.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            DropdownButtonFormField<String>(
              key: ValueKey('$effectiveLang:$effectiveVocabId'),
              value: effectiveVocabId,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: filteredVocabs.map((v) {
                final id = v['id']?.toString() ?? '';
                final name = v['name']?.toString() ?? id;
                final wc = v['word_count'];
                final label = wc != null ? '$name ($wc개)' : name;
                return DropdownMenuItem(value: id, child: Text(label, overflow: TextOverflow.ellipsis));
              }).toList(),
              onChanged: generating != null
                  ? null
                  : (v) { if (v != null) onVocabChanged?.call(v); },
            ),
          const SizedBox(height: AppSpacing.sm),
          // ── Quiz type buttons ────────────────────────────────────────────
          for (final b in _buttons) ...[
            _QuizTypeRow(
              icon: b.icon,
              label: b.label,
              primary: b.primary,
              loading: generating == b.type,
              disabled: generating != null || filteredVocabs.isEmpty,
              onGenerate: () => onGenerate(b.type),
              onPlay: onPlay != null ? () => onPlay!(b.type) : null,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _QuizTypeRow extends StatelessWidget {
  const _QuizTypeRow({
    required this.icon,
    required this.label,
    required this.primary,
    required this.loading,
    required this.disabled,
    required this.onGenerate,
    this.onPlay,
  });

  final IconData icon;
  final String label;
  final bool primary;
  final bool loading;
  final bool disabled;
  final VoidCallback onGenerate;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: primary
              ? FilledButton.icon(
                  onPressed: disabled ? null : onGenerate,
                  icon: loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon, size: 18),
                  label: Text(label, style: const TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                )
              : OutlinedButton.icon(
                  onPressed: disabled ? null : onGenerate,
                  icon: loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon, size: 18),
                  label: Text(label, style: const TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
        ),
        if (onPlay != null) ...[
          const SizedBox(width: 6),
          IconButton.filledTonal(
            tooltip: '큐에서 풀기',
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow, size: 20),
            style: IconButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(40, 40),
            ),
          ),
        ],
      ],
    );
  }
}
