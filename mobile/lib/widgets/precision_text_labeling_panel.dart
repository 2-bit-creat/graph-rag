import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../utils/paragraph_formatter.dart';
import '../utils/graph_layout.dart';
import '../widgets/app_ui.dart';

const _ignoreSpeaker = '무시';

/// User drag-labels speaker ranges, then submits structured dialogue.
class PrecisionTextLabelingPanel extends StatefulWidget {
  const PrecisionTextLabelingPanel({
    super.key,
    required this.onSubmit,
    this.initialText = '',
    this.busy = false,
  });

  final Future<void> Function(String paragraphText) onSubmit;
  final String initialText;
  final bool busy;

  @override
  State<PrecisionTextLabelingPanel> createState() => _PrecisionTextLabelingPanelState();
}

class _LabeledSpan {
  _LabeledSpan({
    required this.start,
    required this.end,
    required this.speaker,
  });

  final int start;
  final int end;
  final String speaker;
}

class _SpeakerOption {
  const _SpeakerOption({required this.name, required this.degree});

  final String name;
  final int degree;
}

class _PrecisionTextLabelingPanelState extends State<PrecisionTextLabelingPanel> {
  final _composeCtrl = TextEditingController();
  final _focusNode = FocusNode();
  bool _labeling = false;
  bool _loadingSpeakers = false;
  String _fullText = '';
  final List<_LabeledSpan> _spans = [];
  TextSelection? _selection;
  final List<String> _speakers = [];
  final Map<String, int> _speakerDegrees = {};
  final Set<String> _customSpeakers = {};

  static const _palette = [
    AppColors.primary,
    AppColors.accent,
    AppColors.accentWarm,
    Color(0xFF0D9488),
    Color(0xFF7C3AED),
    Color(0xFFDB2777),
    Color(0xFF2563EB),
  ];

  @override
  void initState() {
    super.initState();
    _composeCtrl.text = widget.initialText;
  }

  @override
  void dispose() {
    _composeCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Color _colorForSpeaker(String speaker) {
    if (speaker == _ignoreSpeaker) return Colors.grey.shade500;
    final names = [..._speakers, ..._customSpeakers];
    final idx = names.indexOf(speaker);
    if (idx < 0) return _palette[speaker.hashCode.abs() % _palette.length];
    return _palette[idx % _palette.length];
  }

  Future<void> _loadGraphSpeakers() async {
    setState(() => _loadingSpeakers = true);
    try {
      final graph = await apiClient.getGraph();
      final nodes = (graph['nodes'] as List?)?.whereType<Map>().toList() ?? [];
      final edges =
          (graph['edges'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ??
              [];
      final degrees = degreeByNodeId(edges);

      final persons = <_SpeakerOption>[];
      final seen = <String>{};
      for (final n in nodes) {
        final name = n['name']?.toString().trim() ?? '';
        if (name.isEmpty || !isSpeakerLikeType(n['type']?.toString())) continue;
        final key = name.toLowerCase();
        if (seen.contains(key)) continue;
        seen.add(key);
        persons.add(
          _SpeakerOption(
            name: name,
            degree: degrees[n['id']?.toString()] ?? 0,
          ),
        );
      }
      persons.sort((a, b) => b.degree.compareTo(a.degree));

      if (mounted) {
        setState(() {
          _speakers
            ..clear()
            ..addAll(persons.map((p) => p.name));
          _speakerDegrees
            ..clear()
            ..addAll({for (final p in persons) p.name: p.degree});
          _loadingSpeakers = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSpeakers = false);
    }
  }

  Future<void> _startLabeling() async {
    final text = _composeCtrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('텍스트를 입력해 주세요')),
      );
      return;
    }
    setState(() {
      _fullText = text;
      _labeling = true;
      _spans.clear();
      _selection = null;
    });
    await _loadGraphSpeakers();
  }

  int? _spanIndexAt(int offset) {
    for (var i = 0; i < _spans.length; i++) {
      final s = _spans[i];
      if (offset >= s.start && offset < s.end) return i;
    }
    return null;
  }

  void _applySpeaker(String speaker, {int? start, int? end}) {
    final sel = _selection;
    final rangeStart = start ?? sel?.start;
    final rangeEnd = end ?? sel?.end;
    if (rangeStart == null ||
        rangeEnd == null ||
        rangeStart >= rangeEnd ||
        (start == null && (sel == null || !sel.isValid || sel.isCollapsed))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('먼저 텍스트 범위를 드래그해 선택하세요')),
      );
      return;
    }

    setState(() {
      _spans.removeWhere((s) => !(s.end <= rangeStart || s.start >= rangeEnd));
      _spans.add(_LabeledSpan(start: rangeStart, end: rangeEnd, speaker: speaker));
      _spans.sort((a, b) => a.start.compareTo(b.start));
      if (!_speakers.contains(speaker) && speaker != _ignoreSpeaker) {
        _customSpeakers.add(speaker);
      }
      _selection = null;
    });
    _focusNode.unfocus();
  }

  void _removeSpan(int index) {
    setState(() => _spans.removeAt(index));
  }

  void _onSelectionChanged(TextSelection sel, SelectionChangedCause? cause) {
    if (sel.isCollapsed && cause == SelectionChangedCause.tap) {
      final idx = _spanIndexAt(sel.start);
      if (idx != null) {
        _openSpanEditor(idx);
        return;
      }
    }
    setState(() => _selection = sel);
  }

  Future<void> _openSpanEditor(int index) async {
    final span = _spans[index];
    final snippet = _fullText.substring(span.start, span.end).trim();
    final allNames = [
      ..._speakers,
      ..._customSpeakers.where((n) => !_speakers.contains(n)),
    ];

    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('라벨 수정', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                '「${snippet.length > 48 ? '${snippet.substring(0, 48)}…' : snippet}」',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('화자 변경', style: Theme.of(ctx).textTheme.labelMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final name in allNames)
                    ActionChip(
                      label: Text(name),
                      avatar: CircleAvatar(
                        radius: 8,
                        backgroundColor: _colorForSpeaker(name).withValues(alpha: 0.2),
                        child: Icon(Icons.person, size: 12, color: _colorForSpeaker(name)),
                      ),
                      onPressed: () => Navigator.pop(ctx, 'set:$name'),
                    ),
                  ActionChip(
                    label: const Text(_ignoreSpeaker),
                    onPressed: () => Navigator.pop(ctx, 'set:$_ignoreSpeaker'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                icon: const Icon(Icons.label_off_outlined),
                label: const Text('라벨 삭제'),
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted || result == null) return;
    if (result == 'delete') {
      _removeSpan(index);
      return;
    }
    if (result.startsWith('set:')) {
      final name = result.substring(4);
      setState(() {
        _spans[index] = _LabeledSpan(start: span.start, end: span.end, speaker: name);
      });
    }
  }

  String _buildParagraphText() {
    return buildParagraphText(
      _fullText,
      _spans
          .map((s) => LabeledSpanInput(start: s.start, end: s.end, speaker: s.speaker))
          .toList(),
    );
  }

  Future<void> _save() async {
    final paragraph = _buildParagraphText();
    if (paragraph.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('화자를 지정한 구간이 없습니다. 드래그 후 화자를 선택하세요.')),
      );
      return;
    }
    await widget.onSubmit(paragraph);
  }

  Future<void> _addCustomSpeaker() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 화자'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '지식 그래프에 없는 이름'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('추가'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _customSpeakers.add(name));
    if (_selection != null && !_selection!.isCollapsed) {
      _applySpeaker(name);
    }
  }

  Widget _speakerChip(String speaker, {bool isIgnore = false}) {
    final color = _colorForSpeaker(speaker);
    final degree = _speakerDegrees[speaker];
    final label = isIgnore
        ? '무시 (제외)'
        : (degree != null && degree > 0 ? '$speaker · $degree' : speaker);
    return ActionChip(
      label: Text(label),
      avatar: CircleAvatar(
        radius: 8,
        backgroundColor: color.withValues(alpha: 0.25),
        child: Icon(
          isIgnore ? Icons.block : Icons.person,
          size: 12,
          color: color,
        ),
      ),
      onPressed: widget.busy ? null : () => _applySpeaker(speaker),
    );
  }

  TextStyle _spanStyle(TextStyle base, String speaker) {
    final color = _colorForSpeaker(speaker);
    final ignored = speaker == _ignoreSpeaker;
    return base.copyWith(
      backgroundColor: color.withValues(alpha: ignored ? 0.12 : 0.22),
      decoration: ignored ? TextDecoration.lineThrough : TextDecoration.none,
      decorationColor: Colors.grey.shade600,
    );
  }

  TextSpan _buildHighlightedTextSpan(TextStyle style) {
    if (_spans.isEmpty) {
      return TextSpan(text: _fullText, style: style);
    }

    final sorted = [..._spans]..sort((a, b) => a.start.compareTo(b.start));
    final children = <InlineSpan>[];
    var cursor = 0;

    for (final span in sorted) {
      final start = span.start.clamp(0, _fullText.length);
      final end = span.end.clamp(0, _fullText.length);
      if (start >= end) continue;
      if (cursor < start) {
        children.add(TextSpan(text: _fullText.substring(cursor, start), style: style));
      }
      if (cursor < end) {
        children.add(TextSpan(
          text: _fullText.substring(start, end),
          style: _spanStyle(style, span.speaker),
        ));
      }
      cursor = end;
    }
    if (cursor < _fullText.length) {
      children.add(TextSpan(text: _fullText.substring(cursor), style: style));
    }
    return TextSpan(children: children);
  }

  Widget _labeledTextArea(TextStyle style) {
    return SelectableText.rich(
      _buildHighlightedTextSpan(style),
      focusNode: _focusNode,
      style: style,
      onSelectionChanged: _onSelectionChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_labeling) {
      return AppSurfaceCard(
        tint: AppColors.hubVoice,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('텍스트 입력', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _composeCtrl,
              maxLines: 12,
              minLines: 6,
              decoration: const InputDecoration(
                hintText: '대화·일기 텍스트를 붙여넣거나 입력하세요…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: widget.busy ? null : _startLabeling,
              icon: const Icon(Icons.label_important_outline),
              label: const Text('화자 라벨링 시작'),
            ),
          ],
        ),
      );
    }

    final style = Theme.of(context).textTheme.bodyLarge!.copyWith(height: 1.55);
    final hasSelection = _selection != null && _selection!.isValid && !_selection!.isCollapsed;
    final customOnly =
        _customSpeakers.where((n) => !_speakers.contains(n)).toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSurfaceCard(
          tint: AppColors.hubVoice,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('화자 라벨링', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  TextButton(
                    onPressed: widget.busy
                        ? null
                        : () => setState(() {
                              _labeling = false;
                              _spans.clear();
                            }),
                    child: const Text('텍스트 수정'),
                  ),
                ],
              ),
              Text(
                '드래그 → 화자 선택 · 지정된 글자를 탭하면 수정/삭제',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  border: Border.all(
                    color: hasSelection
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                  ),
                ),
                child: _labeledTextArea(style),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_loadingSpeakers)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else if (_speakers.isEmpty && _customSpeakers.isEmpty)
                Text(
                  '지식 그래프에 Speaker 노드가 없습니다. + 화자로 추가하세요.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in _speakers) _speakerChip(s),
                  for (final s in customOnly) _speakerChip(s),
                  _speakerChip(_ignoreSpeaker, isIgnore: true),
                  ActionChip(
                    label: const Text('+ 화자'),
                    avatar: const Icon(Icons.person_add_alt_1, size: 16),
                    onPressed: widget.busy ? null : _addCustomSpeaker,
                  ),
                ],
              ),
              if (hasSelection) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '선택: 「${_fullText.substring(_selection!.start, _selection!.end).trim()}」',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          onPressed: widget.busy ? null : _save,
          icon: widget.busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.save_alt_outlined),
          label: Text(widget.busy ? '저장 중…' : '정제본 저장 · 번역 시작'),
        ),
      ],
    );
  }
}
