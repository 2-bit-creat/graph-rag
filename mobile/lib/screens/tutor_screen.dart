import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/target_language_button.dart';
import 'quiz_generation_screen.dart';

/// ?�문 ?�터 ?�션 ???�이브아카데미式 ?�문 ?�릴.
///
/// ?�전 ?�성??composition ?�즈 ?�에???�성???�서?��?문제�?꺼내 출제?�고,
/// ?��? ?�에???�?�된 모범?�안??기�??�로 경량 첨삭�??�행?�다. ?��? 비면
/// 즉석 ?�성 ?�이 '문제 ?�성' ?�이지�??�내?�다.
class TutorScreen extends StatefulWidget {
  const TutorScreen({
    super.key,
    required this.language,
    required this.sourceMode,
  });

  final String language;
  final TutorSourceMode sourceMode;

  @override
  State<TutorScreen> createState() => _TutorScreenState();
}

/// ?�릴 출제 ?�스. ?�브?� ?�션??공유.
enum TutorSourceMode { journal, review }

extension TutorSourceModeX on TutorSourceMode {
  String get api => switch (this) {
        TutorSourceMode.journal => 'journal',
        TutorSourceMode.review => 'review',
      };
  String get label => switch (this) {
        TutorSourceMode.journal => '내 일기에서',
        TutorSourceMode.review => '복습 표현',
      };
  String get blurb => switch (this) {
        TutorSourceMode.journal => '내 일기 문장으로 출제',
        TutorSourceMode.review => '아까 배운 표현 다시 출제',
      };
  IconData get icon => switch (this) {
        TutorSourceMode.journal => Icons.auto_stories_rounded,
        TutorSourceMode.review => Icons.replay_rounded,
      };
}

String tutorLangLabel(String code) => switch (code) {
      'english' => 'English',
      'german' => 'Deutsch',
      'japanese' => '日本語',
      'chinese' => '中文',
      'spanish' => 'Español',
      'french' => 'Français',
      _ => code,
    };

// ?�???�드 ?�이??-------------------------------------------------------------

sealed class _Item {}

class _DrillItem extends _Item {
  _DrillItem(this.drill);
  final Map<String, dynamic> drill;
}

class _AttemptItem extends _Item {
  _AttemptItem(this.text);
  final String text;
}

class _FeedbackItem extends _Item {
  _FeedbackItem(this.data, this.drill);
  final Map<String, dynamic> data;
  final Map<String, dynamic> drill;
}

class _ChatItem extends _Item {
  _ChatItem(this.role, this.text);
  final String role; // 'user' | 'assistant'
  final String text;
}

class _PendingItem extends _Item {
  _PendingItem(this.label);
  final String label;
}

/// ?��? 비었???�의 종료 카드 ??문제 ?�성 ?�이지�??�내.
class _EmptyQueueItem extends _Item {}

class _TutorScreenState extends State<TutorScreen> {
  final _items = <_Item>[];
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  late String _language;
  late TutorSourceMode _sourceMode;

  bool _busy = false; // ?�릴 ?�성/첨삭/?�??�??�력 ?�금
  bool _sessionLoading = true;
  Map<String, dynamic>? _currentDrill; // ?��? ?��?중인 ?�릴 (null?�면 ?�??모드)

  List<Map<String, dynamic>> _queue = [];
  int _queueIndex = 0;
  List<String> _languages = ['english'];

  @override
  void initState() {
    super.initState();
    _language = widget.language;
    _sourceMode = widget.sourceMode;
    _loadLanguages();
    _initSession();
  }

  Future<void> _loadLanguages() async {
    try {
      final profile = await apiClient.getQuizProfile();
      final rawLangs = profile['target_languages'];
      final langs = (rawLangs is List && rawLangs.isNotEmpty)
          ? rawLangs.map((e) => e.toString()).toList()
          : [profile['target_language']?.toString() ?? _language];
      if (!mounted) return;
      setState(() {
        _languages = langs;
        if (!_languages.contains(_language)) {
          _language = _languages.first;
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Map<String, dynamic> _drillFromQuiz(Map<String, dynamic> quiz) {
    final qd = Map<String, dynamic>.from(
      (quiz['quiz_data'] as Map?)?.cast<String, dynamic>() ?? {},
    );
    return {
      'quiz_id': quiz['id']?.toString(),
      'prompt': quiz['question_ko']?.toString() ?? '',
      'source_label': qd['source_label']?.toString() ?? '',
      'source_mode': qd['source_mode']?.toString() ?? '',
      'target_expressions': qd['target_expressions'] ?? [],
      'glossary': qd['glossary'] ?? [],
      'hints': qd['hints'] ?? [],
      'language': qd['language']?.toString() ?? _language,
      'cefr': qd['cefr']?.toString() ?? '',
      'difficulty': qd['difficulty']?.toString() ?? '',
      'style': qd['style'] is Map
          ? Map<String, dynamic>.from(qd['style'] as Map)
          : const <String, dynamic>{},
    };
  }

  Future<void> _initSession() async {
    setState(() => _sessionLoading = true);
    try {
      final session = await apiClient.startQuizSession(
        quizType: 'composition',
        language: _language,
        size: 10,
      );
      final items = (session['items'] as List?) ?? [];
      if (!mounted) return;
      setState(() {
        _queue = items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _queueIndex = 0;
        _sessionLoading = false;
      });
      await _nextDrill();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sessionLoading = false);
      _showError(e);
    }
  }

  Future<void> _nextDrill() async {
    if (_queueIndex < _queue.length) {
      final quiz = _queue[_queueIndex++];
      final drill = _drillFromQuiz(quiz);
      setState(() {
        _currentDrill = drill;
        _items.add(_DrillItem(drill));
        _busy = false;
      });
      _scrollToBottom();
      return;
    }

    // ???�진 ??즉석 ?�성 ?�이 문제 ?�성 ?�이지�??�내?�다.
    setState(() {
      _currentDrill = null;
      _busy = false;
      if (_items.whereType<_EmptyQueueItem>().isEmpty) {
        _items.add(_EmptyQueueItem());
      }
    });
    _scrollToBottom();
  }

  Future<void> _openGeneration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const QuizGenerationScreen()),
    );
    // ?�성 ?�이지?�서 ?�아?�면 ?��? ?�시 채워본다.
    if (!mounted) return;
    setState(() => _items.removeWhere((i) => i is _EmptyQueueItem));
    _restart();
  }

  Future<void> _submitAttempt(String text) async {
    final drill = _currentDrill;
    if (drill == null || text.trim().isEmpty) return;
    _inputController.clear();
    setState(() {
      _busy = true;
      _items.add(_AttemptItem(text.trim()));
      _items.add(_PendingItem('첨삭하는 중…'));
      _currentDrill = null; // 첨삭 ?�엔 ?�??모드�??�환
    });
    _scrollToBottom();
    try {
      // Drills only ever come from the queue, so each carries a quiz_id and is
      // graded against its pre-generated reference answers.
      final quizId = drill['quiz_id']?.toString() ?? '';
      final result = await apiClient.submitQuizAnswer(
        quizId: quizId,
        answer: text.trim(),
      );
      final data = Map<String, dynamic>.from(
        (result['tutor_feedback'] as Map?)?.cast<String, dynamic>() ?? {},
      );
      if (!mounted) return;
      setState(() {
        _items.removeWhere((i) => i is _PendingItem);
        _items.add(_FeedbackItem(data, drill));
        _busy = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items.removeWhere((i) => i is _PendingItem);
        _busy = false;
      });
      _showError(e);
    }
  }

  Future<void> _sendChat(String text) async {
    if (text.trim().isEmpty) return;
    _inputController.clear();
    setState(() {
      _busy = true;
      _items.add(_ChatItem('user', text.trim()));
      _items.add(_PendingItem('생각하는 중…'));
    });
    _scrollToBottom();

    // 최근 ?�???�스?�리(첨삭 ?�후??질문·?��?)�?추려???�달.
    final history = <Map<String, String>>[];
    for (final it in _items) {
      if (it is _ChatItem) history.add({'role': it.role, 'content': it.text});
    }

    try {
      final answer = await apiClient.tutorChat(
        messages: history,
        language: _language,
        drillPrompt: _lastDrillPrompt(),
      );
      if (!mounted) return;
      setState(() {
        _items.removeWhere((i) => i is _PendingItem);
        _items.add(_ChatItem('assistant', answer));
        _busy = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items.removeWhere((i) => i is _PendingItem);
        _busy = false;
      });
      _showError(e);
    }
  }

  String? _lastDrillPrompt() {
    for (final it in _items.reversed) {
      if (it is _DrillItem) return it.drill['prompt']?.toString();
    }
    return null;
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
    );
  }

  void _restart() {
    setState(() {
      _items.clear();
      _queueIndex = 0;
    });
    _initSession();
  }

  @override
  Widget build(BuildContext context) {
    final langAction = TargetLanguageButton(
      languages: _languages,
      selected: _language,
      enabled: !_busy && !_sessionLoading,
      onChanged: (lang) {
        setState(() => _language = lang);
        _restart();
      },
    );

    if (_sessionLoading) {
      return Scaffold(
        appBar: AppHubAppBar(
          title: '샘플 튜터',
          subtitle: '${tutorLangLabel(_language)} · ${_sourceMode.label}',
          actions: [langAction],
        ),
        body: const AppLoadingScreen(message: '문제 불러오는 중…'),
      );
    }
    return Scaffold(
      appBar: AppHubAppBar(
        title: '샘플 튜터',
        subtitle: '${tutorLangLabel(_language)} · ${_sourceMode.label}',
        actions: [langAction],
      ),
      body: Column(
        children: [
          _SourceModeBar(
            selected: _sourceMode,
            onChanged: _busy
                ? null
                : (mode) {
                    if (mode == _sourceMode) return;
                    setState(() => _sourceMode = mode);
                    _restart();
                  },
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageH, AppSpacing.md, AppSpacing.pageH, AppSpacing.lg),
              itemCount: _items.length,
              itemBuilder: (context, i) => _buildItem(_items[i]),
            ),
          ),
          _InputBar(
            controller: _inputController,
            answering: _currentDrill != null,
            busy: _busy,
            language: _language,
            onSend: (text) =>
                _currentDrill != null ? _submitAttempt(text) : _sendChat(text),
            onNext: _busy ? null : _nextDrill,
          ),
        ],
      ),
    );
  }

  Widget _buildItem(_Item item) {
    return switch (item) {
      _DrillItem(:final drill) => _DrillPromptCard(drill: drill),
      _AttemptItem(:final text) => _AttemptBubble(text: text),
      _FeedbackItem(:final data, :final drill) => _FeedbackCard(
          data: data,
          drill: drill,
          language: _language,
        ),
      _ChatItem(:final role, :final text) =>
        role == 'user' ? _AttemptBubble(text: text) : _ChatBubble(text: text),
      _PendingItem(:final label) => _PendingRow(label: label),
      _EmptyQueueItem() => _EmptyQueueCard(onGenerate: _openGeneration),
    };
  }
}

// ?�?� Source-mode selector ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

class _SourceModeBar extends StatelessWidget {
  const _SourceModeBar({required this.selected, required this.onChanged});
  final TutorSourceMode selected;
  final ValueChanged<TutorSourceMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pageH, vertical: AppSpacing.sm),
      child: Row(
        children: [
          for (final mode in TutorSourceMode.values) ...[
            Expanded(
              child: _ModeChip(
                mode: mode,
                selected: mode == selected,
                onTap: onChanged == null ? null : () => onChanged!(mode),
              ),
            ),
            if (mode != TutorSourceMode.values.last)
              const SizedBox(width: AppSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode, required this.selected, this.onTap});
  final TutorSourceMode mode;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? AppColors.hubQuiz.withValues(alpha: 0.14)
          : scheme.surfaceContainerLow.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(mode.icon,
                  size: 18,
                  color: selected ? AppColors.hubQuiz : context.mutedText),
              const SizedBox(height: 3),
              Text(
                mode.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppColors.hubQuiz : context.mutedText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ?�?� Drill prompt card (glossary + progressive hints) ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

class _DrillPromptCard extends StatefulWidget {
  const _DrillPromptCard({required this.drill});
  final Map<String, dynamic> drill;

  @override
  State<_DrillPromptCard> createState() => _DrillPromptCardState();
}

class _DrillPromptCardState extends State<_DrillPromptCard> {
  int _hintsShown = 0;

  @override
  Widget build(BuildContext context) {
    final drill = widget.drill;
    final scheme = Theme.of(context).colorScheme;
    final sourceLabel = drill['source_label']?.toString() ?? '';
    final cefr = drill['cefr']?.toString() ?? '';
    final glossary = (drill['glossary'] as List?) ?? [];
    // hints: [{note (native-language), snippet (optional target fragment)}].
    // Back-compat: tolerate flat strings.
    final hints = <Map<String, String>>[
      for (final raw in (drill['hints'] as List?) ?? [])
        if (raw is Map)
          {
            'note': raw['note']?.toString() ?? '',
            'snippet': raw['snippet']?.toString() ?? '',
          }
        else if (raw is String && raw.isNotEmpty)
          {'note': raw, 'snippet': ''},
    ].where((h) => (h['note'] ?? '').isNotEmpty).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppSurfaceCard(
        tint: AppColors.hubQuiz,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Badge(
                  icon: Icons.bookmark_rounded,
                  text: sourceLabel,
                  color: AppColors.hubQuiz,
                ),
                const SizedBox(width: 6),
                if (cefr.isNotEmpty)
                  _Badge(
                      icon: Icons.bar_chart_rounded,
                      text: cefr,
                      color: context.mutedText),
                if (_styleFocus(drill).isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _Badge(
                    icon: Icons.category_rounded,
                    text: _styleFocus(drill),
                    color: AppColors.hubGraph,
                  ),
                ],
                if (_difficultyLabel(drill).isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _Badge(
                    icon: Icons.local_fire_department_rounded,
                    text: _difficultyLabel(drill),
                    color: AppColors.accentWarm,
                  ),
                ],
                const Spacer(),
                Text('한 문장 · ${tutorLangLabel(drill['language']?.toString() ?? '')}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.mutedText,
                        )),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            SelectableText(
              drill['prompt']?.toString() ?? '',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
            ),

            // 고유명사·?�문?�어 미리보기 ???�습?��? 막히지 ?�게 ??�� ?�출.
            if (glossary.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _GlossaryBlock(items: glossary),
            ],

            // ?�진???�트.
            if (hints.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              for (var i = 0; i < _hintsShown && i < hints.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 1, right: 6),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.accentWarm.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('힌트 ${i + 1}',
                            style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppColors.accentWarm)),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(hints[i]['note'] ?? '',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      height: 1.4,
                                      color: scheme.onSurface.withValues(alpha: 0.8),
                                    )),
                            if ((hints[i]['snippet'] ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: scheme.surface.withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                        color: AppColors.accentWarm
                                            .withValues(alpha: 0.3)),
                                  ),
                                  child: Text(hints[i]['snippet'] ?? '',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurface,
                                        fontStyle: FontStyle.italic,
                                      )),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (_hintsShown < hints.length)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _hintsShown++),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accentWarm,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    icon: const Icon(Icons.lightbulb_outline_rounded, size: 16),
                    label: Text('힌트 보기 ($_hintsShown/${hints.length})',
                        style: const TextStyle(fontSize: 12)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// quiz_data.style.focus_ko ???��???로테?�션 배�? (?? 과거 ?�상, 감정 묘사).
String _styleFocus(Map<String, dynamic> drill) {
  final style = drill['style'];
  if (style is Map) return style['focus_ko']?.toString() ?? '';
  return '';
}

/// quiz_data.difficulty ??normal?� 배�? ?�략.
String _difficultyLabel(Map<String, dynamic> drill) {
  return switch (drill['difficulty']?.toString() ?? '') {
    'easy' => '쉽게',
    'hard' => '어렵게',
    _ => '',
  };
}

class _GlossaryBlock extends StatelessWidget {
  const _GlossaryBlock({required this.items});
  final List items;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.hubGraph.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.translate_rounded, size: 14, color: AppColors.hubGraph),
              const SizedBox(width: 4),
              Text('이름·단어',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.hubGraph,
                        fontWeight: FontWeight.w700,
                      )),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final raw in items)
                if (raw is Map)
                  _GlossaryChip(
                    term: raw['term']?.toString() ?? '',
                    target: raw['target']?.toString() ?? '',
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlossaryChip extends StatelessWidget {
  const _GlossaryChip({required this.term, required this.target});
  final String term;
  final String target;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (term.isEmpty || target.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.hubGraph.withValues(alpha: 0.2)),
      ),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodySmall,
          children: [
            TextSpan(text: term, style: TextStyle(color: context.mutedText)),
            const TextSpan(text: '  → ', style: TextStyle(color: AppColors.hubGraph)),
            TextSpan(
                text: target,
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: scheme.onSurface)),
          ],
        ),
      ),
    );
  }
}

// ?�?� User attempt bubble ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

class _AttemptBubble extends StatelessWidget {
  const _AttemptBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md, left: 40),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.14),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppSpacing.radiusMd),
              topRight: Radius.circular(AppSpacing.radiusMd),
              bottomLeft: Radius.circular(AppSpacing.radiusMd),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.35)),
        ),
      ),
    );
  }
}

// ?�?� Tutor chat bubble ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md, right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TutorAvatar(),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45)),
          ),
        ],
      ),
    );
  }
}

// ?�?� Feedback card ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

class _FeedbackCard extends StatefulWidget {
  const _FeedbackCard({
    required this.data,
    required this.drill,
    required this.language,
  });
  final Map<String, dynamic> data;
  final Map<String, dynamic> drill;
  final String language;

  @override
  State<_FeedbackCard> createState() => _FeedbackCardState();
}

class _FeedbackCardState extends State<_FeedbackCard> {
  /// Session saves + expressions already in the tutor vocab (lowercase keys).
  final _saved = <String>{};
  bool _savingAll = false;

  @override
  void initState() {
    super.initState();
    _loadExistingVocab();
  }

  String _norm(String? s) => (s ?? '').trim().toLowerCase();

  Future<void> _loadExistingVocab() async {
    try {
      final vocab = await apiClient.getTutorVocab(language: widget.language);
      final items = (vocab['items'] as List?) ?? [];
      if (!mounted) return;
      setState(() {
        for (final raw in items) {
          if (raw is! Map) continue;
          final word = _norm(raw['expression']?.toString());
          if (word.isNotEmpty) _saved.add(word);
        }
      });
    } catch (_) {}
  }

  List<Map<String, dynamic>> _asMaps(List raw) =>
      raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();

  /// save_suggestions?�도 ?�으�??�심 ?�현 ?�션?�서 빼서 중복???�앤??
  ({List<Map<String, dynamic>> learn, List<Map<String, dynamic>> review})
      _splitExpressions(
    List<Map<String, dynamic>> keyExprs,
    List<Map<String, dynamic>> saveSuggestions,
  ) {
    final reviewKeys = {
      for (final s in saveSuggestions) _norm(s['expression']),
    }..remove('');
    final learn = [
      for (final e in keyExprs)
        if (!reviewKeys.contains(_norm(e['expression']))) e,
    ];
    return (learn: learn, review: saveSuggestions);
  }

  ({Color color, IconData icon}) _verdictStyle(String verdict) {
    return switch (verdict) {
      'natural' => (color: AppColors.accent, icon: Icons.check_circle_rounded),
      'understandable' => (color: AppColors.hubGraph, icon: Icons.thumb_up_rounded),
      'awkward' => (color: AppColors.accentWarm, icon: Icons.build_rounded),
      _ => (color: AppColors.hubRecord, icon: Icons.refresh_rounded),
    };
  }

  Future<void> _save(Map<String, dynamic> expr) async {
    final word = expr['expression']?.toString() ?? '';
    final key = _norm(word);
    if (key.isEmpty || _saved.contains(key)) return;
    setState(() => _saved.add(key));
    try {
      await apiClient.saveTutorExpression(
        expression: word,
        meaning: expr['meaning']?.toString() ?? '',
        example: expr['example']?.toString() ?? '',
        language: widget.language,
        note: expr['reason']?.toString() ?? '',
        promptKo: widget.drill['prompt']?.toString() ?? '',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"$word"를 튜터 단어장에 저장'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saved.remove(key));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  /// Save every unsaved review suggestion from this round.
  Future<void> _saveAllReview(List<Map<String, dynamic>> reviewExprs) async {
    final items = <Map<String, dynamic>>[];
    final words = <String>[];
    for (final raw in reviewExprs) {
      final word = raw['expression']?.toString() ?? '';
      final key = _norm(word);
      if (key.isEmpty || _saved.contains(key)) continue;
      words.add(key);
      items.add({
        'expression': word,
        'meaning': raw['meaning']?.toString() ?? '',
        'example': raw['example']?.toString() ?? '',
        'language': widget.language,
        'note': raw['reason']?.toString() ?? '',
        'prompt_ko': widget.drill['prompt']?.toString() ?? '',
      });
    }
    if (items.isEmpty) return;
    setState(() => _savingAll = true);
    try {
      final saved = await apiClient.saveTutorExpressionsBatch(items);
      if (mounted) {
        setState(() {
          _saved.addAll(words);
          _savingAll = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$saved개 표현을 단어장에 저장했어요'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _savingAll = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final verdict = d['verdict']?.toString() ?? 'understandable';
    final style = _verdictStyle(verdict);
    final naturalVersions = (d['natural_versions'] as List?) ?? [];
    final keyExprs = _asMaps((d['key_expressions'] as List?) ?? []);
    final saveSuggestions = _asMaps((d['save_suggestions'] as List?) ?? []);
    final split = _splitExpressions(keyExprs, saveSuggestions);
    final learnExprs = split.learn;
    final reviewExprs = split.review;
    final unsavedReview = reviewExprs
        .where((e) => !_saved.contains(_norm(e['expression'])))
        .length;
    final tip = d['thinking_tip']?.toString() ?? '';
    final encouragement = d['encouragement']?.toString() ?? '';
    final verdictLabel = d['verdict_label']?.toString() ?? '';
    // Answer-specific coaching: a note on the learner's own sentence + concrete
    // fixes, graded against the pre-generated reference answers on the backend.
    final attemptNote = d['attempt_note']?.toString() ?? '';
    final corrections = _asMaps((d['corrections'] as List?) ?? []);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppSurfaceCard(
        tint: style.color,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ?�정 ?�더
            Row(
              children: [
                Icon(style.icon, color: style.color, size: 20),
                const SizedBox(width: 6),
                Text(
                  verdictLabel.isNotEmpty ? verdictLabel : _defaultVerdictLabel(verdict),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: style.color,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            if (encouragement.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(encouragement,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4)),
            ],

            // ???��? 첨삭 ???�제 ?�출??문장???�???�답 기반 교정 (가???�에 배치)
            if (attemptNote.isNotEmpty || corrections.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _SectionLabel(
                icon: Icons.build_rounded,
                text: '내 답 첨삭',
                color: AppColors.hubRecord,
              ),
              if (attemptNote.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: Text(attemptNote,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(height: 1.4)),
                ),
              ],
              const SizedBox(height: AppSpacing.xs),
              for (final c in corrections) _CorrectionRow(data: c),
            ],

            // ?�연?�러???�현
            if (naturalVersions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _SectionLabel(icon: Icons.auto_awesome_rounded, text: '이렇게 말하면 자연스러워요'),
              const SizedBox(height: AppSpacing.xs),
              for (final v in naturalVersions)
                _NaturalVersionRow(data: Map<String, dynamic>.from(v as Map)),
            ],

            // 사고 전환 팁
            if (tip.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.hubQuiz.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.psychology_rounded,
                        size: 17, color: AppColors.hubQuiz),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(tip,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                height: 1.45,
                                fontStyle: FontStyle.italic,
                              )),
                    ),
                  ],
                ),
              ),
            ],

            // ?�번 문제?�서 배운 ?�현 (참고?????�기 버튼 ?�음)
            if (learnExprs.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _SectionLabel(
                icon: Icons.style_rounded,
                text: '이번에 배운 표현',
              ),
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 2, bottom: 4),
                child: Text(
                  '모범 답에서 확인한 핵심 어휘·요 · 참고만 하세요',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.mutedText,
                        fontSize: 11.5,
                      ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              for (final e in learnExprs) _LearnExpressionRow(data: e),
            ],

            // 아까 배운 표현 → 복습 단어장
            if (reviewExprs.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _SectionLabel(
                icon: Icons.bookmark_add_rounded,
                text: '복습 단어장에 담기',
                color: AppColors.accentWarm,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 2, bottom: 4),
                child: Text(
                  '이번에 아까 배운 표현을 추천해요 · 붙이면 복습 출제에 넣여요',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.accentWarm.withValues(alpha: 0.75),
                        fontSize: 11.5,
                      ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              for (final s in reviewExprs)
                _ReviewExpressionRow(
                  data: s,
                  saved: _saved.contains(_norm(s['expression']?.toString())),
                  onSave: () => _save(s),
                ),
            ],

            if (unsavedReview > 0) ...[
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      _savingAll ? null : () => _saveAllReview(reviewExprs),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accentWarm,
                    side: BorderSide(
                        color: AppColors.accentWarm.withValues(alpha: 0.5)),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: _savingAll
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.library_add_rounded, size: 17),
                  label: Text('추천 표현 $unsavedReview개 모두 담기'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _defaultVerdictLabel(String v) => switch (v) {
        'natural' => '자연스러워요',
        'understandable' => '이미 잘 이해해',
        'awkward' => '조금 어색해요',
        _ => '다시 생각해봐요',
      };
}

/// ???��?????지?�에 ?�??구체??교정: 무엇???�색?��? ???�렇�?????
class _CorrectionRow extends StatelessWidget {
  const _CorrectionRow({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final issue = data['issue']?.toString() ?? '';
    final suggestion = data['suggestion']?.toString() ?? '';
    final note = data['note']?.toString() ?? '';
    if (issue.isEmpty && suggestion.isEmpty && note.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.hubRecord.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(color: AppColors.hubRecord.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (issue.isNotEmpty)
              Text(issue,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.mutedText,
                        height: 1.35,
                      )),
            if (suggestion.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: issue.isEmpty ? 0 : 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.arrow_right_rounded,
                          size: 18, color: AppColors.hubRecord),
                    ),
                    Expanded(
                      child: SelectableText(suggestion,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1.35,
                              )),
                    ),
                  ],
                ),
              ),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 18, top: 2),
                child: Text('· $note',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.mutedText,
                          height: 1.35,
                        )),
              ),
          ],
        ),
      ),
    );
  }
}

/// 참고???�현 ???�??버튼 ?�음.
class _LearnExpressionRow extends StatelessWidget {
  const _LearnExpressionRow({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final expr = data['expression']?.toString() ?? '';
    final meaning = data['meaning']?.toString() ?? '';
    final example = data['example']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: Theme.of(context).textTheme.bodyMedium,
              children: [
                TextSpan(
                    text: expr,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                if (meaning.isNotEmpty)
                  TextSpan(
                      text: '  $meaning',
                      style: TextStyle(color: context.mutedText)),
              ],
            ),
          ),
          if (example.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text('예: $example',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                      )),
            ),
        ],
      ),
    );
  }
}

/// 복습 추천 ?�현 ???�기 / ?��? ?�태 ?�시.
class _ReviewExpressionRow extends StatelessWidget {
  const _ReviewExpressionRow({
    required this.data,
    required this.saved,
    required this.onSave,
  });

  final Map<String, dynamic> data;
  final bool saved;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final expr = data['expression']?.toString() ?? '';
    final meaning = data['meaning']?.toString() ?? '';
    final reason = data['reason']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.accentWarm.withValues(alpha: saved ? 0.04 : 0.07),
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(
            color: AppColors.accentWarm.withValues(alpha: saved ? 0.15 : 0.22),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      style: Theme.of(context).textTheme.bodyMedium,
                      children: [
                        TextSpan(
                            text: expr,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (meaning.isNotEmpty)
                          TextSpan(
                              text: '  $meaning',
                              style: TextStyle(
                                  color: context.mutedText, fontSize: 13)),
                      ],
                    ),
                  ),
                  if (reason.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(reason,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppColors.accentWarm.withValues(alpha: 0.85),
                                height: 1.35,
                              )),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            saved ? const _SavedBadge() : _SaveButton(onTap: onSave),
          ],
        ),
      ),
    );
  }
}

class _SavedBadge extends StatelessWidget {
  const _SavedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, size: 14, color: AppColors.accent),
          SizedBox(width: 4),
          Text('담김',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent)),
        ],
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accentWarm,
        side: BorderSide(color: AppColors.accentWarm.withValues(alpha: 0.5)),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      icon: const Icon(Icons.add_rounded, size: 16),
      label: const Text('담기', style: TextStyle(fontSize: 12)),
    );
  }
}

class _NaturalVersionRow extends StatelessWidget {
  const _NaturalVersionRow({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final text = data['text']?.toString() ?? '';
    final tone = data['tone']?.toString() ?? '';
    final note = data['note']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 3),
                child: Icon(Icons.arrow_right_rounded, size: 18, color: AppColors.accent),
              ),
              Expanded(
                child: SelectableText(
                  text,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                ),
              ),
              if (tone.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6, top: 2),
                  child: _Badge(text: tone, color: context.mutedText),
                ),
            ],
          ),
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 2),
              child: Text('· $note',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.mutedText,
                      )),
            ),
        ],
      ),
    );
  }
}

// ?�?� Small shared widgets ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.mutedText;
    return Row(
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 5),
        Text(text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: c,
                  fontWeight: FontWeight.w700,
                )),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({this.icon, required this.text, required this.color});
  final IconData? icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(text,
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

class _TutorAvatar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.hubQuiz, AppColors.hubGraph],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.school_rounded, size: 15, color: Colors.white),
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: [
          _TutorAvatar(),
          const SizedBox(width: AppSpacing.sm),
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.mutedText,
                  )),
        ],
      ),
    );
  }
}

// ?�?� Empty-queue card ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

class _EmptyQueueCard extends StatelessWidget {
  const _EmptyQueueCard({required this.onGenerate});
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppSurfaceCard(
        tint: context.mutedText,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.inbox_rounded, size: 20, color: context.mutedText),
                const SizedBox(width: 8),
                Text('이 언어에는 문제가 없어요',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
              ],
            ),
            const SizedBox(height: 6),
            Text('문제 생성에서 일기 문장으로 샘플 문제를 만들 수 있어요',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.mutedText,
                      height: 1.4,
                    )),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onGenerate,
                style: FilledButton.styleFrom(backgroundColor: AppColors.hubQuiz),
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: const Text('문제 만들러 가기'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ?�?� Bottom input bar ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.answering,
    required this.busy,
    required this.language,
    required this.onSend,
    required this.onNext,
  });

  final TextEditingController controller;
  final bool answering; // true = ?��? ?��? false = ?�??모드
  final bool busy;
  final String language;
  final ValueChanged<String> onSend;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = answering
        ? '${tutorLangLabel(language)}(으)로 번역해 보세요'
        : '표현·뉘앙스를 물어보거나 다음 문장으로';
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ?�??모드?�서??"?�음 문장" ?�션??강조 ?�출.
              if (!answering)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onNext,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.hubQuiz,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                      label: const Text('다음 문장'),
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: !busy,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: busy ? null : onSend,
                      decoration: InputDecoration(
                        hintText: hint,
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerLow.withValues(alpha: 0.6),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _SendButton(
                    answering: answering,
                    busy: busy,
                    onTap: () => onSend(controller.text),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.answering, required this.busy, required this.onTap});
  final bool answering;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = answering ? AppColors.accent : AppColors.hubGraph;
    return Material(
      color: busy ? Theme.of(context).disabledColor.withValues(alpha: 0.15) : color,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Icon(
            answering ? Icons.check_rounded : Icons.send_rounded,
            size: 20,
            color: busy ? context.mutedText : Colors.white,
          ),
        ),
      ),
    );
  }
}
