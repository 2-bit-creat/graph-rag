import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/transcript_speaker_view.dart';
import '../widgets/vocabulary_picker_sheet.dart';
import 'pipeline_flow_graph.dart';

class TranslationEntryPanel extends StatelessWidget {
  const TranslationEntryPanel({
    super.key,
    required this.entry,
    required this.entryId,
    required this.onRefresh,
    this.showProgress = false,
    this.isPrecisionText = false,
  });

  final Map<String, dynamic> entry;
  final String entryId;
  final Future<void> Function({bool silent}) onRefresh;
  final bool showProgress;
  final bool isPrecisionText;

  @override
  Widget build(BuildContext context) {
    final status = entry['status']?.toString() ?? '';
    // graph_status is the authoritative graph phase (may differ from status which is fast-path)
    final graphStatus = entry['graph_status']?.toString() ?? status;
    final hasTranslation = (entry['translation_en']?.toString() ?? '').isNotEmpty;
    final pendingSpeakers = isPrecisionText
        ? <String>[]
        : pendingSpeakerLabels(
            entry['speaker_summaries'] as List<dynamic>? ?? [],
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showProgress) ...[
          PipelineProgressStepper(
            status: graphStatus,
            hasTranslation: hasTranslation,
            compact: true,
          ),
          const SizedBox(height: 12),
        ],
        if (pendingSpeakers.isNotEmpty) ...[
          AppSurfaceCard(
            tint: Colors.orange,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Row(
              children: [
                Icon(Icons.record_voice_over_rounded, color: Colors.orange.shade800, size: 22),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('화자 확인 필요', style: Theme.of(context).textTheme.titleSmall),
                      Text(pendingSpeakers.join(', '), style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (!isPrecisionText)
          TranscriptSpeakerView(
            entryId: entryId,
            segments: entry['transcript_segments'] as List<dynamic>? ?? [],
            speakerSummaries: entry['speaker_summaries'] as List<dynamic>? ?? [],
            onConfirmed: () => onRefresh(silent: true),
          ),
        if (isPrecisionText && (entry['transcript_segments'] as List?)?.isNotEmpty == true)
          _LabeledDialogueSection(
            segments: entry['transcript_segments'] as List<dynamic>? ?? [],
          ),
        _VocabTextSection(
          title: '영어 번역',
          content: entry['translation_en']?.toString() ?? '',
          highlight: true,
          initiallyExpanded: true,
          entryId: entryId,
        ),
        if ((entry['translation_de']?.toString() ?? '').isNotEmpty)
          _VocabTextSection(
            title: '독일어 번역',
            content: entry['translation_de']!.toString(),
            highlight: false,
            initiallyExpanded: true,
            entryId: entryId,
          ),
        _TextSection(
          title: '정제 (한국어)',
          content: entry['transcript_clean_ko']?.toString() ?? '',
        ),
        _TextSection(
          title: '원문 (한국어)',
          content: entry['transcript_ko']?.toString() ?? '',
        ),
      ],
    );
  }
}

class _LabeledDialogueSection extends StatelessWidget {
  const _LabeledDialogueSection({required this.segments});

  final List<dynamic> segments;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        child: ExpansionTile(
          initiallyExpanded: true,
          title: Text('라벨링된 대화', style: Theme.of(context).textTheme.titleSmall),
          children: [
            for (final raw in segments)
              if (raw is Map)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 14,
                    child: Text(
                      ((raw['speaker']?.toString() ?? '?').isNotEmpty
                              ? (raw['speaker']?.toString() ?? '?')[0]
                              : '?')
                          .toUpperCase(),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  title: Text(raw['speaker']?.toString() ?? '?'),
                  subtitle: Text(raw['text']?.toString() ?? ''),
                ),
          ],
        ),
      ),
    );
  }
}

class _VocabTextSection extends StatefulWidget {
  const _VocabTextSection({
    required this.title,
    required this.content,
    required this.entryId,
    this.highlight = false,
    this.initiallyExpanded = false,
  });

  final String title;
  final String content;
  final String entryId;
  final bool highlight;
  final bool initiallyExpanded;

  @override
  State<_VocabTextSection> createState() => _VocabTextSectionState();
}

class _VocabTextSectionState extends State<_VocabTextSection> {
  final _controller = TextEditingController();
  String _selected = '';
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.content;
    _controller.addListener(_onSelectionChanged);
    _expanded = widget.initiallyExpanded && widget.content.trim().isNotEmpty;
  }

  @override
  void didUpdateWidget(covariant _VocabTextSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _controller.text = widget.content;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    final sel = _controller.selection;
    if (!sel.isValid || sel.isCollapsed) {
      if (_selected.isNotEmpty) setState(() => _selected = '');
      return;
    }
    final text = _controller.text.substring(sel.start, sel.end).trim();
    if (text != _selected) setState(() => _selected = text);
  }

  Future<void> _addToVocabulary() async {
    await showAddWordToVocabularyDialog(
      context,
      initialWord: _selected,
      linkedDiaryId: widget.entryId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.content.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
            initiallyExpanded: widget.initiallyExpanded && !empty,
            onExpansionChanged: (v) => setState(() => _expanded = v),
            title: Text(widget.title, style: Theme.of(context).textTheme.titleSmall),
            subtitle: empty
                ? Text('(없음)', style: Theme.of(context).textTheme.bodySmall)
                : _expanded
                    ? null
                    : Text(
                        widget.content.split('\n').first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: widget.highlight
                      ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35)
                      : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: TextField(
                  controller: _controller,
                  readOnly: true,
                  maxLines: null,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (!empty) ...[
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: _addToVocabulary,
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: Text(
                      _selected.isNotEmpty ? '「$_selected」 단어장에 추가' : '단어장에 추가',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TextSection extends StatelessWidget {
  const _TextSection({
    required this.title,
    required this.content,
    this.highlight = false,
    this.initiallyExpanded = false,
  });

  final String title;
  final String content;
  final bool highlight;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final empty = content.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
            initiallyExpanded: initiallyExpanded && !empty,
            title: Text(title, style: Theme.of(context).textTheme.titleSmall),
            subtitle: empty
                ? Text('(없음)', style: Theme.of(context).textTheme.bodySmall)
                : Text(
                    content.split('\n').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: highlight
                      ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35)
                      : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: SelectableText(
                  empty ? '(없음)' : content,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
