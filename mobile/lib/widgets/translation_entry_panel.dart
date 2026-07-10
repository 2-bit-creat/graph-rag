import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/speaker_merge_sheet.dart';
import '../widgets/transcript_speaker_view.dart';
import '../widgets/vocabulary_picker_sheet.dart';

// 저널 유형 칩 목록. '자료' = AI·여러 출처를 정리한 참고 지식(외부 출처 기본값).
const List<String> _kJournalTypes = [
  '일기', '대화', '회의록', '책', '뉴스', '강연', '논문', '자료',
];

class TranslationEntryPanel extends StatelessWidget {
  const TranslationEntryPanel({
    super.key,
    required this.entry,
    required this.entryId,
    required this.onRefresh,
    this.isPrecisionText = false,
    this.locked = false,
  });

  final Map<String, dynamic> entry;
  final String entryId;
  final Future<void> Function({bool silent}) onRefresh;
  final bool isPrecisionText;

  /// True once a knowledge graph has been committed for this entry. Type and
  /// speaker edits are read-only at that point — they're the graph's structural
  /// inputs, and changing them would silently desync the already-built graph.
  final bool locked;

  /// LLM-suggested content type, confirmable/overridable by the user (Phase 3).
  /// 외부 출처(자료) 기록에서는 유형이 부차적 결정이라 접힌 컴팩트 칩으로 표시.
  Widget _buildTypeBar(BuildContext context) {
    final current = entry['source_type']?.toString();
    final suggested = entry['suggested_source_type']?.toString();
    final hasSuggestion = suggested != null && suggested.isNotEmpty;
    final hasCurrent = current != null && current.isNotEmpty;
    if (!hasSuggestion && !hasCurrent) return const SizedBox.shrink();
    final label = hasCurrent ? current : '$suggested (추천)';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Chip(
            avatar: const Icon(Icons.category_outlined, size: 16),
            label: Text('유형: $label'),
            visualDensity: VisualDensity.compact,
          ),
          if (!locked)
            TextButton(
              onPressed: () => _pickType(context, hasCurrent ? current : suggested),
              child: const Text('변경'),
            ),
        ],
      ),
    );
  }

  Future<void> _pickType(BuildContext context, String? selected) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            for (final t in _kJournalTypes)
              ListTile(
                leading: Icon(
                  t == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(t),
                onTap: () => Navigator.pop(ctx, t),
              ),
          ],
        ),
      ),
    );
    if (choice == null || choice == selected) return;
    await apiClient.setSourceType(entryId, choice);
    await onRefresh(silent: true);
  }

  Future<void> _openMergeSheet(BuildContext context) async {
    final segments = entry['transcript_segments'] as List<dynamic>? ?? [];
    final applied = await showSpeakerMergeSheet(
      context: context,
      entryId: entryId,
      segments: segments,
    );
    if (applied == true) {
      await onRefresh(silent: true);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('화자 그룹을 적용했어요. 각 화자를 지정해 주세요.')),
        );
      }
    }
  }

  Future<void> _reset(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await apiClient.remapSpeakers(entryId, reset: true);
      await onRefresh(silent: true);
      messenger.showSnackBar(const SnackBar(content: Text('원래 화자 분리로 되돌렸습니다')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('실패: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    }
  }

  /// "화자 합치기 / 분리" (drag-and-drop grouping sheet) + a quick "되돌리기".
  /// Lives at panel level so it survives the speaker-view flip.
  Widget _buildRemapBar(BuildContext context) {
    // Speaker grouping is a structural input to the graph — once built, it's locked.
    if (locked) return const SizedBox.shrink();
    final segments = entry['transcript_segments'] as List<dynamic>? ?? [];
    if (segments.isEmpty) return const SizedBox.shrink();
    final origins = <String>{};
    var canReset = false;
    for (final raw in segments) {
      if (raw is! Map) continue;
      final sp = raw['speaker']?.toString() ?? '';
      final orig = (raw['speaker_original'] ?? raw['speaker'])?.toString() ?? '';
      if (orig.isNotEmpty) origins.add(orig);
      if (orig.isNotEmpty && sp.isNotEmpty && orig != sp) canReset = true;
    }
    // 2+ original speakers → there's something to merge/split.
    final canManage = origins.length > 1;
    if (!canManage && !canReset) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          if (canManage)
            OutlinedButton.icon(
              onPressed: () => _openMergeSheet(context),
              icon: const Icon(Icons.merge_type_rounded, size: 16),
              label: const Text('화자 합치기 / 분리'),
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          if (canReset)
            TextButton.icon(
              onPressed: () => _reset(context),
              icon: const Icon(Icons.restore_rounded, size: 16),
              label: const Text('원래대로'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final segments = entry['transcript_segments'] as List<dynamic>? ?? [];
    final summaries = entry['speaker_summaries'] as List<dynamic>? ?? [];
    // 2026-07-04 통일: 텍스트도 음성과 동일하게 화자 칩으로 확인한다(예외 없음).
    final speakersPending =
        summaries.any((s) => s is Map && s['needs_confirmation'] == true);

    // 1차 콘텐츠 = 정제된 일기(한국어). 쓰기는 정제만 하므로 이것이 가장 먼저
    // 보여야 할 산출물. cleanKo가 없으면(구버전/실패) 원문으로 대체.
    // (일기 통번역 기능은 2026-07-04 제거 — 언어 학습은 표현/문장 뱅크 쪽 담당.)
    final cleanKo = entry['transcript_clean_ko']?.toString() ?? '';
    final rawKo = entry['transcript_ko']?.toString() ?? '';
    final primaryClean = cleanKo.trim().isNotEmpty ? cleanKo : rawKo;

    // 화자별 스크립트(음성·텍스트 공통): 화자 확인이 남아 있으면 그 자체가
    // '지금 할 일'이므로 펼쳐서 보여주고, 확인이 끝났으면 접어 둔다(참고용).
    // 텍스트도 저장 후 칩에서 나/사람/외부 출처를 지정한다.
    final speakerSection = <Widget>[];
    if (segments.isNotEmpty) {
      final view = TranscriptSpeakerView(
        entryId: entryId,
        segments: segments,
        speakerSummaries: entry['speaker_summaries'] as List<dynamic>? ?? [],
        onConfirmed: () => onRefresh(silent: true),
        readOnly: locked,
        showHeader: false,
        wrapInCard: false,
      );
      speakerSection.add(
        _CollapsibleSection(
          icon: Icons.record_voice_over_rounded,
          title: isPrecisionText ? '작성자 · 화자' : '화자별 스크립트',
          subtitle: speakersPending ? '탭해서 누가 쓴/말한 글인지 지정하세요' : null,
          accent: speakersPending ? Colors.orange.shade800 : null,
          initiallyExpanded: speakersPending,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRemapBar(context),
              view,
            ],
          ),
        ),
      );
    }

    // 원문(한국어)이 정제본과 다를 때만 접이식으로 — 정제본이 1차라 원문은 참고.
    final showRaw =
        rawKo.trim().isNotEmpty && rawKo.trim() != cleanKo.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (locked) ...[
          _LockedNote(),
          const SizedBox(height: AppSpacing.sm),
        ],
        _buildTypeBar(context),

        // 화자 확인이 필요하면 그것이 우선 → 스크립트를 정제본보다 위에.
        if (speakersPending) ...speakerSection,

        // ── 1차 콘텐츠: 정제된 일기(한국어), 항상 펼침·강조 ──────────────────
        if (primaryClean.trim().isNotEmpty)
          _VocabTextSection(
            title: '정제된 일기',
            content: primaryClean,
            icon: Icons.auto_fix_high_rounded,
            highlight: true,
            pinned: true,
            // 번역 카드가 사라져 단어장 추가 진입점을 여기로 — 단어를 드래그해 추가.
            showVocab: true,
            entryId: entryId,
          ),

        // 화자 확인이 끝났으면 스크립트는 접어서 아래로.
        if (!speakersPending) ...speakerSection,

        // ── 원문(한국어): 접기 ──────────────────────────────────────────────
        if (showRaw)
          _CollapsibleSection(
            icon: Icons.notes_rounded,
            title: '원문 일기 (한국어)',
            initiallyExpanded: false,
            child: _LabeledBlock(label: '', content: rawKo),
          ),
      ],
    );
  }
}

/// 잠금 안내 — 컴팩트 한 줄.
class _LockedNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      tint: AppColors.hubGraph,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          const Icon(Icons.lock_outline_rounded, color: AppColors.hubGraph, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '지식그래프 생성 후 유형·화자는 잠깁니다. 수정하려면 그래프를 삭제 후 다시 생성하세요.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 접이식 콘텐츠 섹션 — 초기 화면을 비우기 위한 공통 래퍼.
class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.accent,
    this.initiallyExpanded = false,
  });

  final String title;
  final Widget child;
  final String? subtitle;
  final IconData? icon;
  final Color? accent;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            childrenPadding:
                const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
            initiallyExpanded: initiallyExpanded,
            leading: icon == null
                ? null
                : Icon(icon, size: 20, color: accent ?? theme.colorScheme.primary),
            title: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: accent,
                fontWeight: accent != null ? FontWeight.w700 : null,
              ),
            ),
            subtitle: subtitle == null
                ? null
                : Text(subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(color: accent)),
            children: [child],
          ),
        ),
      ),
    );
  }
}

/// 접이식 섹션 내부의 라벨 + 본문 블록.
class _LabeledBlock extends StatelessWidget {
  const _LabeledBlock({required this.label, required this.content});
  final String label;
  final String content;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty) ...[
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
          child: SelectableText(
            content,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _VocabTextSection extends StatefulWidget {
  const _VocabTextSection({
    required this.title,
    required this.content,
    required this.entryId,
    this.highlight = false,
    this.pinned = false,
    this.icon = Icons.translate_rounded,
    this.showVocab = true,
  });

  final String title;
  final String content;
  final String entryId;
  final bool highlight;

  /// 1차 콘텐츠용 — 접기 없이 항상 펼쳐진 강조 카드로 렌더.
  final bool pinned;

  /// pinned 카드의 헤더 아이콘.
  final IconData icon;

  /// '단어장에 추가' 노출 여부 — 한국어 정제 본문에는 숨긴다(학습 대상은 번역).
  final bool showVocab;

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

  Widget _buildTextBody(BuildContext context) {
    return Container(
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
    );
  }

  Widget _buildVocabButton() {
    return Align(
      alignment: Alignment.centerRight,
      child: FilledButton.tonalIcon(
        onPressed: _addToVocabulary,
        icon: const Icon(Icons.bookmark_add_outlined, size: 18),
        label: Text(
          _selected.isNotEmpty ? '「$_selected」 단어장에 추가' : '단어장에 추가',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = widget.content.trim().isEmpty;

    // 1차 콘텐츠: 접기 없이 항상 펼쳐진 강조 카드 — 사용자가 가장 먼저 보게 될 것.
    if (widget.pinned) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(widget.icon,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(widget.title,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(color: theme.colorScheme.primary)),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                _buildTextBody(context),
                if (!empty && widget.showVocab) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _buildVocabButton(),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
            initiallyExpanded: false,
            onExpansionChanged: (v) => setState(() => _expanded = v),
            title: Text(widget.title, style: theme.textTheme.titleSmall),
            subtitle: empty
                ? Text('(없음)', style: theme.textTheme.bodySmall)
                : _expanded
                    ? null
                    : Text(
                        widget.content.split('\n').first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
            children: [
              _buildTextBody(context),
              if (!empty && widget.showVocab) ...[
                const SizedBox(height: AppSpacing.sm),
                _buildVocabButton(),
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
