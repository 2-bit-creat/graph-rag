import 'package:flutter/material.dart';

import '../api/client.dart';
import '../chat/journal_task_controller.dart';
import '../compose/compose_session_controller.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';
import 'concept_link_sheet.dart';
import 'entity_identity_sheet.dart';
import 'mention_editor_core.dart' show CaretStableField;

/// Inline or full-screen graph draft review — edit claims, then confirm.
enum GraphReviewPresentation { full, chat }

/// Review semantics, one colour each: approved, linked-to-self, fuzzy suggestion.
/// Everything else in the chat presentation is hairline + text, so these three
/// carry meaning instead of decoration.
const Color _kApproved = Color(0xFF35C08A);
const Color _kSelf = Color(0xFF4C8DFF);
const Color _kSuggest = Color(0xFFB07BFF);

/// Text-only affordance sized for a dense card (no 48px Material padding).
class _TinyTextButton extends StatelessWidget {
  const _TinyTextButton({
    required this.label,
    required this.onTap,
    required this.tone,
  });

  final String label;
  final VoidCallback onTap;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: tone,
          ),
        ),
      ),
    );
  }
}

class GraphReviewPanel extends StatefulWidget {
  const GraphReviewPanel({
    super.key,
    required this.entryId,
    required this.staging,
    this.presentation = GraphReviewPresentation.full,
    this.maxBodyHeight = 440,
    this.onApplied,
    this.onReopenSpeakers,
  });

  final String entryId;
  final Map<String, dynamic> staging;
  final GraphReviewPresentation presentation;

  /// Scroll-area cap for the [GraphReviewPresentation.full] embedding only.
  ///
  /// The chat presentation deliberately has NO cap and NO scrollable of its own:
  /// it lives inside the chat feed's ListView, and a second viewport nested in
  /// that one swallowed every vertical drag over the draft. The card's top could
  /// then never be scrolled into view — it sat clipped just above the inner
  /// viewport with no gesture able to reach it.
  final double maxBodyHeight;

  /// Called after a successful apply (optional — e.g. pop a route).
  final VoidCallback? onApplied;

  /// When set, user can go back to speaker confirmation instead of editing here.
  final VoidCallback? onReopenSpeakers;

  @override
  State<GraphReviewPanel> createState() => _GraphReviewPanelState();
}

class _PersonCandidate {
  _PersonCandidate({required this.id, required this.name, required this.isSelf});

  final String id;
  final String name;
  final bool isSelf;

  factory _PersonCandidate.fromRaw(dynamic raw) {
    final m = raw is Map ? raw : const {};
    return _PersonCandidate(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      isSelf: m['is_self'] == true,
    );
  }
}

class _ConceptDraft {
  _ConceptDraft({
    required this.name,
    this.importance = 3,
    this.kind = 'concept',
    this.resAction,
    this.resNodeId,
    this.resName,
    this.resIsSelf = false,
    this.resDistance,
    this.candidates = const [],
  });

  String name;
  int importance;
  String kind;
  String? resAction;
  String? resNodeId;
  String? resName;
  bool resIsSelf;

  /// Concept auto-linking (Feature A): cosine distance to the best match and the
  /// full candidate list, populated by the backend's suggest pass.
  double? resDistance;
  List<ConceptCandidate> candidates;

  bool get isPerson => kind == 'person';

  factory _ConceptDraft.fromRaw(dynamic raw) {
    if (raw is Map) {
      final name = (raw['name'] ?? '').toString().trim();
      final importance =
          (int.tryParse(raw['importance']?.toString() ?? '') ?? 3).clamp(1, 5);
      final kind =
          (raw['kind'] ?? 'concept').toString().trim().toLowerCase() == 'person'
              ? 'person'
              : 'concept';
      String? action;
      String? nodeId;
      String? matchedName;
      var isSelf = false;
      double? distance;
      var candidates = const <ConceptCandidate>[];
      final res = raw['resolution'];
      if (res is Map) {
        action = (res['action'] ?? '').toString().trim();
        if (action.isEmpty) action = null;
        final nid = (res['node_id'] ?? '').toString().trim();
        nodeId = nid.isEmpty ? null : nid;
        final mn = (res['matched_name'] ?? '').toString().trim();
        matchedName = mn.isEmpty ? null : mn;
        isSelf = res['is_self'] == true;
        distance = double.tryParse(res['distance']?.toString() ?? '');
        final cands = res['candidates'];
        if (cands is List) {
          candidates = cands
              .map(ConceptCandidate.fromRaw)
              .where((c) => c.nodeId.isNotEmpty)
              .toList();
        }
      }
      return _ConceptDraft(
        name: name,
        importance: importance,
        kind: kind,
        resAction: action,
        resNodeId: nodeId,
        resName: matchedName,
        resIsSelf: isSelf,
        resDistance: distance,
        candidates: candidates,
      );
    }
    return _ConceptDraft(name: raw.toString().trim());
  }

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{
      'name': name,
      'importance': importance,
      'kind': kind,
    };
    if (kind == 'person') {
      m['resolution'] = {
        'action': resAction ?? 'new_person',
        if (resAction == 'link' && resNodeId != null) 'node_id': resNodeId,
      };
    } else if (resAction == 'concept') {
      m['resolution'] = {'action': 'concept'};
    } else if (resAction == 'link' && resNodeId != null) {
      // Reviewer-confirmed concept link (Feature A). An unconfirmed 'suggest'
      // is deliberately NOT round-tripped — it falls back to name-based commit.
      m['resolution'] = {'action': 'link', 'node_id': resNodeId};
    }
    return m;
  }
}

class _ClaimDraft {
  _ClaimDraft({
    required this.speaker,
    required this.title,
    required this.statement,
    required this.concepts,
    this.speakerType = 'Person',
    this.eventTimeText,
    this.temporalPrecision = 'unknown',
    this.temporalConfidence = 0.0,
    this.eventStatus = 'happened',
    this.suggestedDate,
    this.resolvedPrecision = 'unknown',
    this.resolvedConfidence = 0.0,
  });

  final TextEditingController speaker;
  final TextEditingController title;
  final TextEditingController statement;
  final List<_ConceptDraft> concepts;

  /// Extraction metadata that must survive the review round-trip untouched —
  /// the server re-resolves event time from these at commit, so dropping them
  /// silently discarded every timing the text actually stated.
  final String speakerType;
  final String? eventTimeText;
  final String temporalPrecision;
  final double temporalConfidence;
  final String eventStatus;

  /// What the server resolved this claim's event day to, for display. Null only
  /// if resolution failed entirely.
  final DateTime? suggestedDate;
  final String resolvedPrecision;
  final double resolvedConfidence;

  /// Reviewer's answer to "when did this happen", overriding inference. Null
  /// means "the suggestion is right", which is the overwhelmingly common case.
  DateTime? dateOverride;

  DateTime? get effectiveDate => dateOverride ?? suggestedDate;

  /// A date nobody can infer from the text — it fell back to the recording day.
  /// Worth asking about; an explicitly stated date is not.
  bool get isGuessedDate =>
      dateOverride == null && resolvedPrecision == 'recorded_date';

  /// Swipe-review state (Feature B). Approval is review progress only — commit
  /// still sends every remaining claim. `dismissKey` is regenerated on undo so a
  /// restored card never reuses a dismissed Dismissible's key (which crashes).
  bool approved = false;
  bool expanded = false;
  Key dismissKey = UniqueKey();

  static DateTime? _parseDate(dynamic raw) {
    final s = (raw ?? '').toString().trim();
    if (s.isEmpty) return null;
    final d = DateTime.tryParse(s.length > 10 ? s.substring(0, 10) : s);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  factory _ClaimDraft.fromMap(Map<String, dynamic> m) => _ClaimDraft(
        speaker: TextEditingController(text: (m['speaker'] ?? '').toString()),
        title: TextEditingController(text: (m['title'] ?? '').toString()),
        statement: TextEditingController(text: (m['statement'] ?? '').toString()),
        concepts: ((m['concepts'] as List?) ?? [])
            .map(_ConceptDraft.fromRaw)
            .where((c) => c.name.isNotEmpty)
            .toList(),
        speakerType: (m['speaker_type'] ?? 'Person').toString(),
        eventTimeText: (m['event_time_text'] as String?)?.trim().isEmpty ?? true
            ? null
            : (m['event_time_text'] as String).trim(),
        temporalPrecision: (m['temporal_precision'] ?? 'unknown').toString(),
        temporalConfidence:
            double.tryParse(m['temporal_confidence']?.toString() ?? '') ?? 0.0,
        eventStatus: (m['event_status'] ?? 'happened').toString(),
        suggestedDate: _parseDate(m['resolved_event_date']),
        resolvedPrecision: (m['resolved_precision'] ?? 'unknown').toString(),
        resolvedConfidence:
            double.tryParse(m['resolved_confidence']?.toString() ?? '') ?? 0.0,
      );

  Map<String, dynamic> toMap() => {
        'speaker': speaker.text.trim(),
        'speaker_type': speakerType,
        'title': title.text.trim(),
        'statement': statement.text.trim(),
        'concepts': concepts.map((c) => c.toMap()).toList(),
        if (eventTimeText != null) 'event_time_text': eventTimeText,
        'temporal_precision': temporalPrecision,
        'temporal_confidence': temporalConfidence,
        'event_status': eventStatus,
        if (dateOverride != null)
          'event_date_override': _isoDay(dateOverride!),
      };

  void dispose() {
    speaker.dispose();
    title.dispose();
    statement.dispose();
  }
}

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "7월 2일 (목)" — the same date vocabulary the timeline day headers use.
String _dayLabel(DateTime d) => tr('timeline.dayPanelDateLabel', {
      'month': d.month,
      'day': d.day,
      'weekday': [
        tr('timeline.weekdayMon'),
        tr('timeline.weekdayTue'),
        tr('timeline.weekdayWed'),
        tr('timeline.weekdayThu'),
        tr('timeline.weekdayFri'),
        tr('timeline.weekdaySat'),
        tr('timeline.weekdaySun'),
      ][d.weekday - 1],
    });

class _GraphReviewPanelState extends State<GraphReviewPanel> {
  late List<_ClaimDraft> _claims;
  late String _contextType;
  late List<_PersonCandidate> _personCandidates;
  bool _submitting = false;

  /// The entry's own recording day — the anchor for the "그날/전날" shortcuts, so
  /// a draft reviewed the next morning still counts back from when it was written.
  late DateTime _recordedDate;

  @override
  void initState() {
    super.initState();
    final raw = (widget.staging['claims'] as List?) ?? [];
    _claims = raw
        .whereType<Map>()
        .map((m) => _ClaimDraft.fromMap(Map<String, dynamic>.from(m)))
        .toList();
    _contextType = (widget.staging['context_type'] ?? '대화').toString();
    _personCandidates = ((widget.staging['person_candidates'] as List?) ?? [])
        .map(_PersonCandidate.fromRaw)
        .where((p) => p.id.isNotEmpty)
        .toList();
    final now = DateTime.now();
    _recordedDate = _ClaimDraft._parseDate(widget.staging['recorded_date']) ??
        DateTime(now.year, now.month, now.day);
  }

  // ── Event date ─────────────────────────────────────────────────────────────

  /// The one date shared by every claim, or null when they differ. Claims almost
  /// always share a day, which is what makes a single bulk control the right
  /// default rather than a per-claim chore.
  DateTime? get _commonDate {
    if (_claims.isEmpty) return null;
    final first = _claims.first.effectiveDate;
    if (first == null) return null;
    for (final c in _claims) {
      final d = c.effectiveDate;
      if (d == null || !_sameDay(d, first)) return null;
    }
    return first;
  }

  /// True when nothing in the text said when this happened, so every claim just
  /// inherited the recording day. This is the case worth a confirmation nudge.
  bool get _dateIsGuessed =>
      _claims.isNotEmpty && _claims.every((c) => c.isGuessedDate);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _setAllDates(DateTime day) => setState(() {
        for (final c in _claims) {
          c.dateOverride = day;
        }
      });

  Future<void> _pickDate({_ClaimDraft? claim}) async {
    final initial = claim?.effectiveDate ?? _commonDate ?? _recordedDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      // Journals are written about the past; a year back covers backfilling old
      // notes, and today caps it since a diary entry cannot describe the future.
      firstDate: DateTime(_recordedDate.year - 1),
      lastDate: _recordedDate,
      helpText: tr('reviewDate.pickerHelp'),
    );
    if (picked == null || !mounted) return;
    final day = DateTime(picked.year, picked.month, picked.day);
    if (claim == null) {
      _setAllDates(day);
    } else {
      setState(() => claim.dateOverride = day);
    }
  }

  /// Bulk date control. A single answer covers the whole entry because thoughts
  /// and conversations recorded together virtually always belong to one day;
  /// per-claim chips handle the exceptions.
  Widget _dateHeader(BuildContext context, {required bool chatStyle}) {
    if (_claims.isEmpty) return const SizedBox.shrink();
    final common = _commonDate;
    final guessed = _dateIsGuessed;
    final tone = guessed ? AppColors.accentWarm : AppColors.hubGraph;
    final label = common == null
        ? tr('reviewDate.mixedDates')
        : _dayLabel(common);
    final yesterday = _recordedDate.subtract(const Duration(days: 1));

    // Chat: a single unboxed line. The question and its shortcuts sit on one
    // row, and the whole block is muted unless the day was only inferred — a
    // confirmed date is an answer, not an alert.
    if (chatStyle) {
      final quiet = !guessed;
      return Row(
        children: [
          Icon(Icons.event_outlined,
              size: 13, color: quiet ? context.shell.mutedText : tone),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              guessed
                  ? tr('reviewDate.questionGuessed')
                  : tr('reviewDate.questionKnown'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: quiet ? context.shell.mutedText : tone,
              ),
            ),
          ),
          const SizedBox(width: 6),
          _TinyTextButton(
            label: label,
            onTap: () => _pickDate(),
            tone: quiet ? context.shell.primaryText : tone,
          ),
          if (guessed && (common == null || !_sameDay(common, yesterday)))
            _TinyTextButton(
              label: tr('reviewDate.dayBefore'),
              onTap: () => _setAllDates(yesterday),
              tone: context.shell.mutedText,
            ),
        ],
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: chatStyle ? 10 : AppSpacing.md,
        vertical: chatStyle ? 8 : AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_outlined, size: chatStyle ? 14 : 16, color: tone),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  guessed
                      ? tr('reviewDate.questionGuessed')
                      : tr('reviewDate.questionKnown'),
                  style: TextStyle(
                    fontSize: chatStyle ? 11.5 : 13,
                    fontWeight: FontWeight.w600,
                    color: tone,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _dateChoiceChip(
                context,
                label: label,
                selected: true,
                onTap: () => _pickDate(),
                tone: tone,
                icon: Icons.edit_calendar_outlined,
              ),
              if (common == null || !_sameDay(common, _recordedDate))
                _dateChoiceChip(
                  context,
                  label: tr('reviewDate.thatDay'),
                  selected: false,
                  onTap: () => _setAllDates(_recordedDate),
                  tone: tone,
                ),
              if (common == null || !_sameDay(common, yesterday))
                _dateChoiceChip(
                  context,
                  label: tr('reviewDate.dayBefore'),
                  selected: false,
                  onTap: () => _setAllDates(yesterday),
                  tone: tone,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dateChoiceChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required Color tone,
    IconData? icon,
  }) {
    return Material(
      color: selected ? tone.withValues(alpha: 0.20) : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: tone.withValues(alpha: selected ? 0.55 : 0.28),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: tone),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: tone,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Deleted claims held for undo — their TextEditingControllers must stay alive
  /// until the panel disposes, so we never dispose them at delete time.
  final List<_ClaimDraft> _removed = [];

  @override
  void dispose() {
    for (final c in _claims) {
      c.dispose();
    }
    for (final c in _removed) {
      c.dispose();
    }
    super.dispose();
  }

  void _deleteClaimWithUndo(int i) {
    if (i < 0 || i >= _claims.length) return;
    final claim = _claims[i];
    setState(() => _claims.removeAt(i));
    _removed.add(claim);
    final snippet = claim.title.text.trim().isNotEmpty
        ? claim.title.text.trim()
        : claim.statement.text.trim();
    final label = snippet.isEmpty
        ? tr('reviewPanel.itemLabelFallback')
        : (snippet.length > 18 ? '${snippet.substring(0, 18)}…' : snippet);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(tr('reviewPanel.deletedSnackbar', {'label': label})),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: tr('reviewPanel.undoAction'),
          onPressed: () {
            if (!mounted || !_removed.remove(claim)) return;
            claim.dismissKey = UniqueKey(); // reinsertion-safe
            setState(() => _claims.insert(i.clamp(0, _claims.length), claim));
          },
        ),
      ));
  }

  int get _approvedCount => _claims.where((c) => c.approved).length;

  /// Commit is gated on every claim being approved — that's what makes the
  /// swipe-right/tap-check triage meaningful. Empty list can't commit.
  bool get _allApproved => _claims.isNotEmpty && _claims.every((c) => c.approved);

  void _approveAll() => setState(() {
        for (final c in _claims) {
          c.approved = true;
          c.expanded = false;
        }
      });

  Future<void> _confirm() async {
    // Re-entrancy guard, and it has to be the FIRST thing here. _submitting used
    // to be set only on the direct-API path further down, so the two hand-off
    // paths (compose session / journal task) never set it at all and left the
    // button live — a second tap sent a second commit for an entry that was
    // already committed. The server refuses that with 409 graph_locked, so the
    // graph itself was never doubled, but the controllers turn any failure into
    // "그래프 확정 실패": the user saw their diary fail right after it succeeded.
    if (_submitting) return;
    final claims = _claims
        .map((c) => c.toMap())
        .where((m) => (m['statement'] as String).isNotEmpty)
        .toList();
    if (claims.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('graphReview.notEnoughContentSnackbar'))),
      );
      return;
    }
    final emptyCount =
        claims.where((m) => (m['concepts'] as List).isEmpty).length;
    if (emptyCount > 0) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('graphReview.emptyConceptsTitle')),
          content: Text(
            tr('graphReview.emptyConceptsBody', {'count': emptyCount}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('graphReview.goBackAndAdd')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('graphReview.confirmAnyway')),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    if (composeSession.isActive && composeSession.entryId == widget.entryId) {
      composeSession.applyGraph(
        widget.entryId,
        claims: claims,
        contextType: _contextType,
      );
      widget.onApplied?.call();
      return;
    }
    if (journalTask.entryId == widget.entryId && journalTask.isActive) {
      journalTask.applyGraph(
        widget.entryId,
        claims: claims,
        contextType: _contextType,
      );
      widget.onApplied?.call();
      return;
    }

    setState(() => _submitting = true);
    try {
      await apiClient.applyEntryGraph(
        widget.entryId,
        claims: claims,
        contextType: _contextType,
      );
      if (!mounted) return;
      widget.onApplied?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  int get _conceptCount =>
      _claims.fold<int>(0, (n, c) => n + c.concepts.length);

  bool get _isChat => widget.presentation == GraphReviewPresentation.chat;

  Future<void> _handleReopenSpeakers() async {
    if (widget.onReopenSpeakers == null) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('reviewPanel.reopenSpeakersDialogTitle')),
        content: Text(
          tr('reviewPanel.reopenSpeakersDialogBody'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('reviewPanel.reopenSpeakersButton')),
          ),
        ],
      ),
    );
    if (proceed == true) widget.onReopenSpeakers!();
  }

  @override
  Widget build(BuildContext context) {
    if (_isChat) return _buildChat(context);
    return _buildFull(context);
  }

  Widget _buildFull(BuildContext context) {
    final claimsList = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxBodyHeight),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        children: [
          AppSurfaceCard(
            tint: AppColors.accent,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                const Icon(Icons.fact_check_outlined,
                    color: AppColors.accent, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    tr('graphReview.reviewBanner'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _dateHeader(context, chatStyle: false),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < _claims.length; i++) ...[
            _swipeableClaim(context, i, chatStyle: false),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_claims.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                tr('graphReview.nothingToReview'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        claimsList,
        const SizedBox(height: AppSpacing.sm),
        _confirmButton(context),
      ],
    );
  }

  /// Chat presentation: one flat column, no viewport of its own.
  ///
  /// Everything here is sized by content and scrolls with the feed. The visual
  /// language is deliberately quiet — a hairline card per claim, one accent
  /// (progress + commit), and state carried by a single glyph rather than by
  /// coloured pills, so a nine-turn draft reads as a list instead of a wall.
  Widget _buildChat(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _chatHeader(context),
        const SizedBox(height: 10),
        if (widget.onReopenSpeakers != null) ...[
          _SpeakerLockBanner(onReopen: _handleReopenSpeakers),
          const SizedBox(height: 8),
        ],
        _dateHeader(context, chatStyle: true),
        if (_claims.isNotEmpty) const SizedBox(height: 8),
        for (var i = 0; i < _claims.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _swipeableClaim(context, i, chatStyle: true),
        ],
        if (_claims.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              tr('graphReview.nothingToReview'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: context.shell.mutedText,
              ),
            ),
          ),
        const SizedBox(height: 10),
        Text(
          tr('reviewPanel.swipeHint'),
          style: TextStyle(
            fontSize: 9.5,
            height: 1.3,
            color: context.shell.mutedText,
          ),
        ),
        const SizedBox(height: 8),
        _confirmButton(context, chatStyle: true),
      ],
    );
  }

  /// Title · progress · bulk approve, in the height a single badge used to take.
  Widget _chatHeader(BuildContext context) {
    final total = _claims.length;
    final ratio = total == 0 ? 0.0 : _approvedCount / total;
    final muted = context.shell.mutedText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.hub_outlined,
                size: 14, color: AppColors.hubGraph.withValues(alpha: 0.9)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('reviewPanel.draftTitle'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                  color: context.shell.primaryText,
                ),
              ),
            ),
            Text(
              '$_approvedCount/$total',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: _allApproved ? _kApproved : muted,
              ),
            ),
            if (!_allApproved && total > 0 && !_submitting) ...[
              const SizedBox(width: 2),
              _TinyTextButton(
                label: tr('reviewPanel.approveAllShort'),
                onTap: _approveAll,
                tone: _kApproved,
              ),
            ],
          ],
        ),
        const SizedBox(height: 7),
        // 2px rail — the one place progress is stated, replacing three badges.
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 2,
            backgroundColor: context.shell.panelBorder,
            valueColor: AlwaysStoppedAnimation(
              _allApproved ? _kApproved : AppColors.hubGraph,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${tr('reviewPanel.statementCountBadge', {'count': total})} · '
          '${tr('reviewPanel.conceptCountBadge', {'count': _conceptCount})} · '
          '${tr('reviewPanel.lockedAfterConfirm')}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: muted),
        ),
      ],
    );
  }

  /// A claim wrapped in swipe-to-triage (Feature B): swipe right = approve
  /// (card collapses, stays in the list), swipe left = delete with undo.
  Widget _swipeableClaim(BuildContext context, int i, {required bool chatStyle}) {
    final claim = _claims[i];
    final Widget child = (claim.approved && !claim.expanded)
        ? _ApprovedRow(
            claim: claim,
            onTap: () => setState(() => claim.expanded = true),
            onUnapprove: () => setState(() {
              claim.approved = false;
              claim.expanded = false;
            }),
          )
        : _ClaimCard(
            claim: claim,
            index: i + 1,
            personCandidates: _personCandidates,
            chatStyle: chatStyle,
            approved: claim.approved,
            onEditDate: () => _pickDate(claim: claim),
            sharesCommonDate: _commonDate != null,
            onDelete: () => _deleteClaimWithUndo(i),
            onConceptsChanged: () => setState(() {}),
            onToggleApproved: () => setState(() {
              claim.approved = !claim.approved;
              if (!claim.approved) claim.expanded = false;
            }),
            onReopenSpeakers:
                widget.onReopenSpeakers == null ? null : _handleReopenSpeakers,
          );
    return Dismissible(
      key: claim.dismissKey,
      direction: DismissDirection.horizontal,
      background: _swipeBg(approve: true),
      secondaryBackground: _swipeBg(approve: false),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          // Swipe right = approve in place; never actually dismiss.
          setState(() {
            claim.approved = true;
            claim.expanded = false;
          });
          return false;
        }
        return true; // swipe left = delete
      },
      onDismissed: (_) => _deleteClaimWithUndo(i),
      child: child,
    );
  }

  Widget _swipeBg({required bool approve}) {
    final Color color = approve ? _kApproved : AppColors.accentWarm;
    return Container(
      alignment: approve ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(approve ? Icons.check_circle_rounded : Icons.delete_outline_rounded,
              color: color, size: 20),
          const SizedBox(width: 6),
          Text(
            approve ? tr('reviewPanel.approveSwipeLabel') : tr('reviewPanel.deleteSwipeLabel'),
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _confirmButton(BuildContext context, {bool chatStyle = false}) {
    final enabled = !_submitting && _allApproved;

    // Chat: one button, one job. The "전체 승인" escape hatch moved up into the
    // header row, so the footer no longer stacks two competing full-width
    // buttons — the gradient/glow pair read as two primary actions.
    if (chatStyle) {
      return SizedBox(
        height: 42,
        child: FilledButton(
          onPressed: enabled ? _confirm : null,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.hubGraph,
            disabledBackgroundColor: context.shell.subtleSurface,
            disabledForegroundColor: context.shell.mutedText,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_submitting)
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              else
                Icon(
                  _allApproved
                      ? Icons.check_rounded
                      : Icons.lock_outline_rounded,
                  size: 16,
                ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  _submitting ? tr('graphReview.confirming') : _confirmLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // "전체 승인" shortcut so gating never becomes a dead end — one tap approves
    // everything and lights up the confirm button.
    final approveAllRow = (!_allApproved && _claims.isNotEmpty && !_submitting)
        ? Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton.icon(
              onPressed: _approveAll,
              icon: const Icon(Icons.done_all_rounded, size: 18),
              label: Text(
                tr('reviewPanel.approveAllButton', {'approved': _approvedCount, 'total': _claims.length}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF2E9E74),
                side: const BorderSide(color: Color(0x6635C08A)),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          )
        : const SizedBox.shrink();

    final Widget button = FilledButton.icon(
      onPressed: enabled ? _confirm : null,
      icon: _submitting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(_allApproved
              ? Icons.check_circle_outline
              : Icons.lock_outline_rounded),
      label: Text(
        _submitting ? tr('graphReview.confirming') : _confirmLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [approveAllRow, button],
    );
  }

  String get _confirmLabel {
    final total = _claims.length;
    final approved = _approvedCount;
    if (total == 0) return tr('reviewPanel.confirmNone');
    if (approved == total) return tr('reviewPanel.confirmAllApproved');
    return tr('reviewPanel.confirmNeedsApproval', {'approved': approved, 'total': total});
  }
}

class _ClaimCard extends StatelessWidget {
  const _ClaimCard({
    required this.claim,
    required this.index,
    required this.personCandidates,
    required this.chatStyle,
    required this.onDelete,
    required this.onConceptsChanged,
    required this.onEditDate,
    this.sharesCommonDate = true,
    this.approved = false,
    this.onToggleApproved,
    this.onReopenSpeakers,
  });

  final _ClaimDraft claim;
  final int index;
  final List<_PersonCandidate> personCandidates;
  final bool chatStyle;
  final VoidCallback onDelete;
  final VoidCallback onConceptsChanged;

  /// Opens the picker for this claim alone, leaving the rest of the entry alone.
  final VoidCallback onEditDate;

  /// False when this claim's day differs from the rest of the entry.
  final bool sharesCommonDate;
  final bool approved;
  final VoidCallback? onToggleApproved;
  final VoidCallback? onReopenSpeakers;

  /// Per-claim date. Present on every editable card so an exception can actually
  /// be made, but muted while it agrees with the entry's shared day — it only
  /// takes on colour when this claim breaks from the rest.
  Widget _dateChip(BuildContext context) {
    final date = claim.effectiveDate;
    if (date == null) return const SizedBox.shrink();
    final tone =
        sharesCommonDate ? context.shell.mutedText : AppColors.hubGraph;

    // Chat: numeric and unboxed, riding the meta row instead of costing a row of
    // its own. It only speaks up (colour + full label) when this claim's day
    // breaks from the rest of the entry, which is the case worth noticing.
    if (chatStyle) {
      return InkWell(
        onTap: onEditDate,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: Text(
            sharesCommonDate ? '${date.month}.${date.day}' : _dayLabel(date),
            style: TextStyle(
              fontSize: 10,
              fontWeight: sharesCommonDate ? FontWeight.w500 : FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: tone,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: chatStyle ? 6 : AppSpacing.xs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: tone.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: onEditDate,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.event_outlined, size: 12, color: tone),
                  const SizedBox(width: 4),
                  Text(
                    _dayLabel(date),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: tone,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<EntityPersonCandidate> get _entityCandidates => personCandidates
      .map((p) => EntityPersonCandidate(id: p.id, name: p.name, isSelf: p.isSelf))
      .toList();

  Future<void> _resolvePerson(BuildContext context, _ConceptDraft c) async {
    final result = await showEntityIdentitySheet(
      context: context,
      entityName: c.name,
      candidates: _entityCandidates,
      suggestedNodeId: c.resAction == 'suggest' ? c.resNodeId : null,
      suggestedName: c.resAction == 'suggest' ? c.resName : null,
      currentAction: c.resAction,
      currentNodeId: c.resNodeId,
    );
    if (result == null) return;
    if (result.action == 'concept') {
      c.kind = 'concept';
      c.resAction = 'concept';
      c.resNodeId = null;
      c.resName = null;
      c.resIsSelf = false;
    } else if (result.action == 'link') {
      c.kind = 'person';
      c.resAction = 'link';
      c.resNodeId = result.nodeId;
      c.resName = result.linkedName;
      c.resIsSelf = result.isSelf;
    } else {
      c.kind = 'person';
      c.resAction = 'new_person';
      c.resNodeId = null;
      c.resName = null;
      c.resIsSelf = false;
    }
    onConceptsChanged();
  }

  /// Concept auto-linking (Feature A): confirm/change/undo a link to an existing
  /// Concept node. Candidates come from the backend suggest pass; for an already
  /// linked concept we still offer the candidate list so the user can re-pick.
  Future<void> _resolveConceptLink(BuildContext context, _ConceptDraft c) async {
    var cands = c.candidates;
    if (cands.isEmpty && c.resNodeId != null && (c.resName ?? '').isNotEmpty) {
      cands = [ConceptCandidate(nodeId: c.resNodeId!, name: c.resName!)];
    }
    final result = await showConceptLinkSheet(
      context: context,
      conceptName: c.name,
      candidates: cands,
      currentNodeId: c.resNodeId,
    );
    if (result == null) return;
    if (result.action == 'link') {
      c.resAction = 'link';
      c.resNodeId = result.nodeId;
      c.resName = result.linkedName;
    } else {
      // keep as a new concept
      c.resAction = null;
      c.resNodeId = null;
      c.resName = null;
      c.candidates = const [];
    }
    onConceptsChanged();
  }

  Widget _speakerBadge(BuildContext context, String name, {required bool chatStyle}) {
    // Chat: the speaker is a name, not a status — plain coloured text with a lock
    // glyph, so it stops competing with the linked/suggested concept chips that
    // genuinely need a filled background to be read as state.
    if (chatStyle) {
      final label = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              name.isEmpty ? tr('graphReview.speakerLabel') : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
                color: AppColors.hubVoice,
              ),
            ),
          ),
          if (onReopenSpeakers != null) ...[
            const SizedBox(width: 3),
            Icon(Icons.lock_outline_rounded,
                size: 10, color: AppColors.hubVoice.withValues(alpha: 0.5)),
          ],
        ],
      );
      if (onReopenSpeakers == null) return label;
      return Tooltip(
        message: tr('reviewPanel.speakerLockedTooltip'),
        child: InkWell(
          onTap: onReopenSpeakers,
          borderRadius: BorderRadius.circular(6),
          child: label,
        ),
      );
    }

    final badge = Container(
      padding: EdgeInsets.symmetric(
        horizontal: chatStyle ? 8 : 10,
        vertical: chatStyle ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: AppColors.hubVoice.withValues(alpha: chatStyle ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(chatStyle ? 6 : 8),
        border: Border.all(color: AppColors.hubVoice.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_rounded,
              size: chatStyle ? 13 : 15, color: AppColors.hubVoice),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              name.isEmpty ? tr('graphReview.speakerLabel') : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: chatStyle ? 12 : 13.5,
                fontWeight: FontWeight.w700,
                color: AppColors.hubVoice,
              ),
            ),
          ),
          if (onReopenSpeakers != null) ...[
            const SizedBox(width: 2),
            Icon(Icons.lock_outline_rounded,
                size: chatStyle ? 11 : 12,
                color: AppColors.hubVoice.withValues(alpha: 0.55)),
          ],
        ],
      ),
    );
    if (onReopenSpeakers == null) return badge;
    return Tooltip(
      message: tr('reviewPanel.speakerLockedTooltip'),
      child: InkWell(
        onTap: onReopenSpeakers,
        borderRadius: BorderRadius.circular(chatStyle ? 6 : 8),
        child: badge,
      ),
    );
  }

  Future<void> _addConcept(BuildContext context) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('graphReview.addConceptTitle')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('graphReview.addConceptHint')),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('common.add')),
          ),
        ],
      ),
    );
    final v = (value ?? '').trim();
    if (v.isNotEmpty && !claim.concepts.any((c) => c.name == v)) {
      claim.concepts.add(_ConceptDraft(name: v));
      onConceptsChanged();
    }
  }

  Widget _personChip(BuildContext context, _ConceptDraft c) {
    final linked = c.resAction == 'link';
    final suggested = c.resAction == 'suggest';
    final Color tone = linked
        ? (c.resIsSelf ? const Color(0xFF4C8DFF) : const Color(0xFF35C08A))
        : suggested
            ? const Color(0xFFB07BFF)
            : const Color(0xFFFFB020);
    final String suffix = linked
        ? (c.resIsSelf
            ? tr('graphReview.linkedSelfSuffix', {'name': c.resName ?? c.name})
            : tr('graphReview.linkedSuffix', {'name': c.resName ?? c.name}))
        : suggested
            ? tr('graphReview.suggestedSuffix', {'name': c.resName ?? ''})
            : tr('graphReview.newEntitySuffix');
    return InputChip(
      avatar: CircleAvatar(
        backgroundColor: tone.withValues(alpha: 0.22),
        child: Icon(
          suggested
              ? Icons.person_search
              : (c.resIsSelf ? Icons.account_circle : Icons.person),
          size: 14,
          color: tone,
        ),
      ),
      label: Text('${c.name}  $suffix'),
      onPressed: () => _resolvePerson(context, c),
      onDeleted: () {
        claim.concepts.remove(c);
        onConceptsChanged();
      },
    );
  }

  Widget _fullConceptChip(BuildContext context, _ConceptDraft c) {
    final suggested = c.resAction == 'suggest';
    final linked = c.resAction == 'link';
    final Color tone = suggested
        ? const Color(0xFFB07BFF)
        : linked
            ? const Color(0xFF35C08A)
            : AppColors.accent;
    final Widget avatar = (suggested || linked)
        ? CircleAvatar(
            backgroundColor: tone.withValues(alpha: 0.2),
            child: Icon(Icons.link_rounded, size: 14, color: tone),
          )
        : CircleAvatar(
            backgroundColor:
                AppColors.accent.withValues(alpha: 0.15 + 0.15 * c.importance),
            child: Text(
              '${c.importance}',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
            ),
          );
    final String label = suggested
        ? '${c.name} ${tr('graphReview.suggestedSuffix', {'name': c.resName ?? ''})}'
        : linked
            ? '${c.name} ${tr('graphReview.linkedSuffix', {'name': c.resName ?? ''})}'
            // Importance already reads off the avatar badge (and its tint).
            // Repeating it as a "· 5" suffix showed the same number twice on
            // one chip and pushed longer concept names into an ellipsis.
            : c.name;
    return GestureDetector(
      onLongPress: () {
        c.kind = 'person';
        c.resAction = null;
        onConceptsChanged();
        _resolvePerson(context, c);
      },
      child: InputChip(
        label: Text(label),
        avatar: avatar,
        onPressed: () {
          if (suggested || linked) {
            _resolveConceptLink(context, c);
          } else {
            c.importance = c.importance >= 5 ? 1 : c.importance + 1;
            onConceptsChanged();
          }
        },
        onDeleted: () {
          claim.concepts.remove(c);
          onConceptsChanged();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (chatStyle) return _buildChatCard(context);
    return _buildFullCard(context);
  }

  /// Compact claim card: hairline surface, one meta row, body, chips.
  ///
  /// The old card spent three stacked rows and four tinted containers per claim
  /// (index chip, speaker pill, date pill, bordered field), so eight claims read
  /// as a wall of boxes. Here the index and speaker share the meta row with the
  /// date and the two actions, the statement field carries no border until
  /// focus, and only linked/suggested chips take colour.
  Widget _buildChatCard(BuildContext context) {
    final approvedTone = approved ? _kApproved : context.shell.mutedText;
    return Container(
      decoration: BoxDecoration(
        color: context.shell.panelBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: approved
              ? _kApproved.withValues(alpha: 0.35)
              : context.shell.panelBorder,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(11, 7, 5, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '$index',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: context.shell.mutedText,
                ),
              ),
              const SizedBox(width: 8),
              // Expanded, not Flexible+Spacer: a loose Flexible would only claim
              // its share of the free space, leaving the actions floating mid-row
              // whenever the speaker name is short.
              Expanded(
                child: _speakerBadge(
                  context,
                  claim.speaker.text,
                  chatStyle: true,
                ),
              ),
              _dateChip(context),
              if (onToggleApproved != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  tooltip: approved
                      ? tr('reviewPanel.unapproveTooltip')
                      : tr('reviewPanel.approveTooltip'),
                  onPressed: onToggleApproved,
                  icon: Icon(
                    approved
                        ? Icons.check_circle_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 17,
                    color: approvedTone,
                  ),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 30),
                tooltip: tr('common.delete'),
                onPressed: onDelete,
                icon: Icon(Icons.close_rounded,
                    size: 15,
                    color: context.shell.mutedText.withValues(alpha: 0.75)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // Statement bodies are edited here and can run long, so they need the
          // same treatment as the composers. See [CaretStableField].
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: CaretStableField(
              maxHeight: 96,
              child: TextField(
                controller: claim.statement,
                minLines: 1,
                maxLines: null,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: context.shell.primaryText,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: context.shell.subtleSurface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                  // Borderless at rest — the fill already bounds the field, and
                  // eight outlined boxes in a column read as a table.
                  border: _statementBorder(Colors.transparent),
                  enabledBorder: _statementBorder(Colors.transparent),
                  focusedBorder: _statementBorder(
                    AppColors.hubGraph.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ),
          if (claim.concepts.isEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 11,
                    color: AppColors.accentWarm.withValues(alpha: 0.85)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    tr('reviewPanel.noConceptsChatHint'),
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.accentWarm.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 7),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final c in claim.concepts)
                  if (c.isPerson)
                    _chatPersonChip(context, c)
                  else
                    _chatConceptChip(context, c),
                _chatAddChip(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static OutlineInputBorder _statementBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color),
      );

  /// One chip geometry for every chat-mode tag: 24px tall, hairline by default,
  /// filled only when it carries state (linked / suggested / new identity). A
  /// plain concept is the common case and now costs no colour at all — its
  /// importance reads off a 4px dot instead of a filled numeral avatar.
  Widget _chatChip(
    BuildContext context, {
    required String label,
    required Color tone,
    required bool filled,
    required VoidCallback onTap,
    required VoidCallback onDelete,
    IconData? icon,
    Widget? leading,
    VoidCallback? onLongPress,
  }) {
    final chip = Material(
      color: filled ? tone.withValues(alpha: 0.13) : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: filled
                  ? tone.withValues(alpha: 0.34)
                  : context.shell.panelBorder,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(6, 3, 3, 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 5)],
              if (icon != null) ...[
                Icon(icon, size: 11, color: tone),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: filled ? tone : context.shell.primaryText,
                ),
              ),
              GestureDetector(
                onTap: onDelete,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 2, 2),
                  child: Icon(Icons.close_rounded,
                      size: 11,
                      color: (filled ? tone : context.shell.mutedText)
                          .withValues(alpha: 0.75)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return chip;
  }

  Widget _chatConceptChip(BuildContext context, _ConceptDraft c) {
    final suggested = c.resAction == 'suggest';
    final linked = c.resAction == 'link';
    final Color tone =
        suggested ? _kSuggest : (linked ? _kApproved : AppColors.accent);
    return _chatChip(
      context,
      // Suggest/link → concept-link sheet; plain → cycle importance.
      onTap: () {
        if (suggested || linked) {
          _resolveConceptLink(context, c);
        } else {
          c.importance = c.importance >= 5 ? 1 : c.importance + 1;
          onConceptsChanged();
        }
      },
      onLongPress: () {
        c.kind = 'person';
        c.resAction = null;
        onConceptsChanged();
        _resolvePerson(context, c);
      },
      onDelete: () {
        claim.concepts.remove(c);
        onConceptsChanged();
      },
      tone: tone,
      filled: suggested || linked,
      icon: (suggested || linked) ? Icons.link_rounded : null,
      leading: (suggested || linked) ? null : _importanceDot(c.importance),
      label: suggested
          ? '${c.name} ${tr('graphReview.suggestedSuffix', {'name': c.resName ?? ''})}'
          : linked
              ? '${c.name} ${tr('graphReview.linkedSuffix', {'name': c.resName ?? ''})}'
              : c.name,
    );
  }

  /// Importance 1–5 as one dot that grows and gains opacity — the number itself
  /// was never the point, the relative weight is.
  Widget _importanceDot(int importance) {
    final size = 3.0 + importance * 0.9;
    return SizedBox(
      width: 8,
      height: 8,
      child: Center(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent.withValues(alpha: 0.35 + 0.13 * importance),
          ),
        ),
      ),
    );
  }

  Widget _chatPersonChip(BuildContext context, _ConceptDraft c) {
    final linked = c.resAction == 'link';
    final suggested = c.resAction == 'suggest';
    final color = linked
        ? (c.resIsSelf ? _kSelf : _kApproved)
        : suggested
            ? _kSuggest
            : AppColors.accentWarm;
    final suffix = linked
        ? (c.resIsSelf
            ? tr('graphReview.linkedSelfSuffix', {'name': c.resName ?? c.name})
            : tr('graphReview.linkedSuffix', {'name': c.resName ?? c.name}))
        : suggested
            ? tr('graphReview.suggestedSuffix', {'name': c.resName ?? ''})
            : tr('graphReview.newEntitySuffix');
    return _chatChip(
      context,
      onTap: () => _resolvePerson(context, c),
      onDelete: () {
        claim.concepts.remove(c);
        onConceptsChanged();
      },
      tone: color,
      // A person mention always carries a resolution decision, so it always
      // reads as state.
      filled: true,
      icon: suggested ? Icons.person_search_rounded : Icons.person_rounded,
      label: '${c.name} $suffix',
    );
  }

  /// Icon-only: "추가" spelled out was the widest chip in every card while being
  /// the least interesting thing in it.
  Widget _chatAddChip(BuildContext context) {
    return Tooltip(
      message: tr('graphReview.addConceptTitle'),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: () => _addConcept(context),
          borderRadius: BorderRadius.circular(7),
          child: Container(
            width: 26,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: context.shell.panelBorder),
            ),
            child: Icon(Icons.add_rounded,
                size: 13, color: context.shell.mutedText),
          ),
        ),
      ),
    );
  }

  Widget _buildFullCard(BuildContext context) {
    return AppSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _speakerBadge(context, claim.speaker.text, chatStyle: false)),
              if (onToggleApproved != null)
                IconButton(
                  tooltip: approved ? tr('reviewPanel.unapproveTooltip') : tr('reviewPanel.approveTooltip'),
                  onPressed: onToggleApproved,
                  icon: Icon(
                    approved
                        ? Icons.check_circle_rounded
                        : Icons.check_circle_outline_rounded,
                    color: approved
                        ? const Color(0xFF35C08A)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              IconButton(
                tooltip: tr('graphReview.deleteItemTooltip'),
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, color: AppColors.accentWarm),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _dateChip(context),
          CaretStableField(
            maxHeight: 96,
            child: TextField(
              controller: claim.statement,
              minLines: 1,
              maxLines: null,
              decoration: InputDecoration(
                labelText: tr('graphReview.statementLabel'),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              tr('graphReview.conceptHelpText'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          if (claim.concepts.isEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: const Color(0x2EFFB020),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0x66FFB020)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: Color(0xFFFFB020)),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      tr('graphReview.noConceptsWarning'),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: const Color(0xFFFFB020)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final c in claim.concepts)
                if (c.isPerson)
                  _personChip(context, c)
                else
                  _fullConceptChip(context, c),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: Text(tr('common.add')),
                onPressed: () => _addConcept(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Collapsed one-line view of an approved claim (Feature B). Tap to re-expand
/// and edit; long-press to un-approve.
class _ApprovedRow extends StatelessWidget {
  const _ApprovedRow({
    required this.claim,
    required this.onTap,
    required this.onUnapprove,
  });

  final _ClaimDraft claim;
  final VoidCallback onTap;
  final VoidCallback onUnapprove;

  @override
  Widget build(BuildContext context) {
    final snippet = claim.title.text.trim().isNotEmpty
        ? claim.title.text.trim()
        : claim.statement.text.trim();
    // 34px, one line, no fill: an approved claim is settled work and should
    // recede. The check glyph is the only thing that has to stay legible — the
    // "승인됨" label it used to carry said the same thing twice.
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        onLongPress: onUnapprove,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(9, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kApproved.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_rounded, size: 14, color: _kApproved),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  snippet.isEmpty
                      ? tr('reviewPanel.noContentPlaceholder')
                      : snippet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.shell.primaryText.withValues(alpha: 0.75),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: tr('reviewPanel.approvedLabel'),
                child: Icon(Icons.expand_more_rounded,
                    size: 15, color: context.shell.mutedText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeakerLockBanner extends StatelessWidget {
  const _SpeakerLockBanner({required this.onReopen});

  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    // Unboxed and single-line: an informational note about a locked field does
    // not need a tinted panel of its own above the list it annotates.
    return Row(
      children: [
        Icon(Icons.lock_outline_rounded,
            size: 12, color: AppColors.hubVoice.withValues(alpha: 0.8)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            tr('reviewPanel.speakerLockedBanner'),
            maxLines: 2,
            style: TextStyle(
              fontSize: 10,
              height: 1.35,
              color: context.shell.mutedText,
            ),
          ),
        ),
        _TinyTextButton(
          label: tr('reviewPanel.reopenSpeakersButton'),
          onTap: onReopen,
          tone: AppColors.hubVoice,
        ),
      ],
    );
  }
}
