import 'package:flutter/material.dart';

import '../api/client.dart';
import '../chat/journal_task_controller.dart';
import '../compose/compose_session_controller.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';
import 'entity_identity_sheet.dart';

/// Inline or full-screen graph draft review — edit claims, then confirm.
enum GraphReviewPresentation { full, chat }

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

  /// Scroll area cap when embedded in chat cards.
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
  });

  String name;
  int importance;
  String kind;
  String? resAction;
  String? resNodeId;
  String? resName;
  bool resIsSelf;

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
      final res = raw['resolution'];
      if (res is Map) {
        action = (res['action'] ?? '').toString().trim();
        if (action.isEmpty) action = null;
        final nid = (res['node_id'] ?? '').toString().trim();
        nodeId = nid.isEmpty ? null : nid;
        final mn = (res['matched_name'] ?? '').toString().trim();
        matchedName = mn.isEmpty ? null : mn;
        isSelf = res['is_self'] == true;
      }
      return _ConceptDraft(
        name: name,
        importance: importance,
        kind: kind,
        resAction: action,
        resNodeId: nodeId,
        resName: matchedName,
        resIsSelf: isSelf,
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
  });

  final TextEditingController speaker;
  final TextEditingController title;
  final TextEditingController statement;
  final List<_ConceptDraft> concepts;

  factory _ClaimDraft.fromMap(Map<String, dynamic> m) => _ClaimDraft(
        speaker: TextEditingController(text: (m['speaker'] ?? '').toString()),
        title: TextEditingController(text: (m['title'] ?? '').toString()),
        statement: TextEditingController(text: (m['statement'] ?? '').toString()),
        concepts: ((m['concepts'] as List?) ?? [])
            .map(_ConceptDraft.fromRaw)
            .where((c) => c.name.isNotEmpty)
            .toList(),
      );

  Map<String, dynamic> toMap() => {
        'speaker': speaker.text.trim(),
        'title': title.text.trim(),
        'statement': statement.text.trim(),
        'concepts': concepts.map((c) => c.toMap()).toList(),
      };

  void dispose() {
    speaker.dispose();
    title.dispose();
    statement.dispose();
  }
}

class _GraphReviewPanelState extends State<GraphReviewPanel> {
  late List<_ClaimDraft> _claims;
  late String _contextType;
  late List<_PersonCandidate> _personCandidates;
  bool _submitting = false;

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
  }

  @override
  void dispose() {
    for (final c in _claims) {
      c.dispose();
    }
    super.dispose();
  }

  void _deleteClaim(int i) {
    setState(() {
      _claims.removeAt(i).dispose();
    });
  }

  Future<void> _confirm() async {
    final claims = _claims
        .map((c) => c.toMap())
        .where((m) => (m['statement'] as String).isNotEmpty)
        .toList();
    if (claims.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('확정할 내용이 없습니다. 최소 한 개의 Statement가 필요합니다.')),
      );
      return;
    }
    final emptyCount =
        claims.where((m) => (m['concepts'] as List).isEmpty).length;
    if (emptyCount > 0) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('개념 없는 항목이 있습니다'),
          content: Text(
            '$emptyCount개 항목에 개념(Concept)이 없습니다.\n'
            '이대로 확정하면 해당 Statement는 다른 지식과 연결되지 않는 '
            '고립 노드가 되고, 확정 후에는 수정할 수 없습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('돌아가서 추가'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('그래도 확정'),
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
        title: const Text('화자 설정으로 돌아갈까요?'),
        content: const Text(
          '화자는 그래프의 핵심 입력이라 여기서는 바꿀 수 없습니다.\n'
          '화자 설정으로 돌아가 수정한 뒤, 그래프 초안을 다시 만들어야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('화자 다시 설정'),
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
                    '생성된 내용을 검토하고 수정하세요. 확정 후에는 수정할 수 없고 삭제·복구만 가능합니다.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < _claims.length; i++) ...[
            _ClaimCard(
              claim: _claims[i],
              index: i + 1,
              personCandidates: _personCandidates,
              chatStyle: false,
              onDelete: () => _deleteClaim(i),
              onConceptsChanged: () => setState(() {}),
              onReopenSpeakers:
                  widget.onReopenSpeakers == null ? null : _handleReopenSpeakers,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_claims.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                '검토할 항목이 없습니다.',
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

  Widget _buildChat(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.hubGraph.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.hub_outlined,
                      size: 13, color: AppColors.hubGraph.withValues(alpha: 0.9)),
                  const SizedBox(width: 4),
                  Text(
                    '${_claims.length}개 발언',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.hubGraph.withValues(alpha: 0.95),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$_conceptCount개 개념',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent.withValues(alpha: 0.95),
                ),
              ),
            ),
            const Spacer(),
            Text(
              '확정 후 수정 불가',
              style: TextStyle(
                fontSize: 10,
                color: context.shell.mutedText,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (widget.onReopenSpeakers != null) ...[
          _SpeakerLockBanner(onReopen: _handleReopenSpeakers),
          const SizedBox(height: 8),
        ],
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: widget.maxBodyHeight),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _claims.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _ClaimCard(
              claim: _claims[i],
              index: i + 1,
              personCandidates: _personCandidates,
              chatStyle: true,
              onDelete: () => _deleteClaim(i),
              onConceptsChanged: () => setState(() {}),
              onReopenSpeakers:
                  widget.onReopenSpeakers == null ? null : _handleReopenSpeakers,
            ),
          ),
        ),
        if (_claims.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '검토할 항목이 없습니다.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: context.shell.mutedText,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '개념 탭 → 중요도 · 길게 → 정체성 · 👤 탭 → 연결',
          style: TextStyle(
            fontSize: 10,
            color: context.shell.mutedText,
          ),
        ),
        const SizedBox(height: 10),
        _confirmButton(context, chatStyle: true),
      ],
    );
  }

  Widget _confirmButton(BuildContext context, {bool chatStyle = false}) {
    if (chatStyle) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.hubGraph,
              AppColors.hubGraph.withValues(alpha: 0.82),
            ],
          ),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: AppColors.hubGraph.withValues(alpha: 0.28),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
          onPressed: _submitting ? null : _confirm,
          icon: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.check_circle_outline_rounded, size: 18),
          label: Text(_submitting ? '확정 중…' : '지식그래프에 확정'),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: _submitting ? null : _confirm,
      icon: _submitting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.check_circle_outline),
      label: Text(_submitting ? '확정 중…' : '확정하고 지식그래프에 추가'),
    );
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
    this.onReopenSpeakers,
  });

  final _ClaimDraft claim;
  final int index;
  final List<_PersonCandidate> personCandidates;
  final bool chatStyle;
  final VoidCallback onDelete;
  final VoidCallback onConceptsChanged;
  final VoidCallback? onReopenSpeakers;

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

  Widget _speakerBadge(BuildContext context, String name, {required bool chatStyle}) {
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
              name.isEmpty ? '화자' : name,
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
      message: '화자는 여기서 수정할 수 없습니다',
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
        title: const Text('개념 추가'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '개념(Concept) 이름'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('추가'),
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
        ? '→ ${c.resIsSelf ? '${c.resName ?? c.name}(본인)' : (c.resName ?? c.name)}'
        : suggested
            ? '≈ ${c.resName ?? ''}?'
            : '· 새 개체';
    return InputChip(
      avatar: CircleAvatar(
        backgroundColor: tone.withValues(alpha: 0.22),
        child: Icon(
          suggested
              ? Icons.auto_awesome
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

  @override
  Widget build(BuildContext context) {
    if (chatStyle) return _buildChatCard(context);
    return _buildFullCard(context);
  }

  Widget _buildChatCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.shell.panelBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.shell.panelBorder),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.hubGraph.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.hubGraph.withValues(alpha: 0.95),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _speakerBadge(
                  context,
                  claim.speaker.text,
                  chatStyle: true,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: '삭제',
                onPressed: onDelete,
                icon: Icon(Icons.close_rounded,
                    size: 16, color: context.shell.mutedText),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: claim.statement,
            minLines: 1,
            maxLines: 4,
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
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: context.shell.panelBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: context.shell.panelBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.hubGraph.withValues(alpha: 0.45)),
              ),
            ),
          ),
          if (claim.concepts.isEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '개념 없음 — 고립 노드가 될 수 있어요',
              style: TextStyle(
                fontSize: 10,
                color: AppColors.accentWarm.withValues(alpha: 0.85),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final c in claim.concepts)
                if (c.isPerson)
                  _chatPersonChip(context, c)
                else
                  _chatConceptChip(context, c),
              _chatAddChip(context),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chatConceptChip(BuildContext context, _ConceptDraft c) {
    return GestureDetector(
      onLongPress: () {
        c.kind = 'person';
        c.resAction = null;
        onConceptsChanged();
        _resolvePerson(context, c);
      },
      child: Material(
        color: AppColors.accent.withValues(alpha: 0.12 + 0.04 * c.importance),
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: () {
            c.importance = c.importance >= 5 ? 1 : c.importance + 1;
            onConceptsChanged();
          },
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${c.importance}',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: AppColors.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  c.name,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    claim.concepts.remove(c);
                    onConceptsChanged();
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Icon(Icons.close,
                        size: 12, color: AppColors.accent.withValues(alpha: 0.7)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chatPersonChip(BuildContext context, _ConceptDraft c) {
    final linked = c.resAction == 'link';
    final suggested = c.resAction == 'suggest';
    final color = linked
        ? (c.resIsSelf ? const Color(0xFF4C8DFF) : const Color(0xFF35C08A))
        : suggested
            ? const Color(0xFFB07BFF)
            : AppColors.accentWarm;
    final suffix = linked
        ? '→ ${c.resIsSelf ? '${c.resName ?? c.name}(본인)' : (c.resName ?? c.name)}'
        : suggested
            ? '≈ ${c.resName ?? ''}?'
            : '· 새 개체';
    return Material(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: () => _resolvePerson(context, c),
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                suggested ? Icons.auto_awesome : Icons.person_rounded,
                size: 12,
                color: color,
              ),
              const SizedBox(width: 4),
              Text(
                '${c.name} $suffix',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              GestureDetector(
                onTap: () {
                  claim.concepts.remove(c);
                  onConceptsChanged();
                },
                child: Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Icon(Icons.close, size: 12, color: color.withValues(alpha: 0.7)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chatAddChip(BuildContext context) {
    final onSurface = context.shell.primaryText;
    return Material(
      color: context.shell.subtleSurface,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: () => _addConcept(context),
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 13, color: onSurface),
              const SizedBox(width: 2),
              Text(
                '추가',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: onSurface,
                ),
              ),
            ],
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
              IconButton(
                tooltip: '이 항목 삭제',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, color: AppColors.accentWarm),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: claim.statement,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Statement (내용)',
              isDense: true,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '개념·정체성 — 개념: 탭=중요도, 길게=정체성 전환 · 👤 정체성: 탭=연결 대상 지정',
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
                      '개념이 없습니다 — 이대로 확정하면 이 Statement는 그래프에서 고립됩니다. 최소 1개를 추가하세요.',
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
                  GestureDetector(
                    onLongPress: () {
                      c.kind = 'person';
                      c.resAction = null;
                      onConceptsChanged();
                      _resolvePerson(context, c);
                    },
                    child: InputChip(
                      label: Text('${c.name} · ${c.importance}'),
                      avatar: CircleAvatar(
                        backgroundColor: AppColors.accent
                            .withValues(alpha: 0.15 + 0.15 * c.importance),
                        child: Text(
                          '${c.importance}',
                          style: const TextStyle(
                              fontSize: 10, fontWeight: FontWeight.w700),
                        ),
                      ),
                      onPressed: () {
                        c.importance = c.importance >= 5 ? 1 : c.importance + 1;
                        onConceptsChanged();
                      },
                      onDeleted: () {
                        claim.concepts.remove(c);
                        onConceptsChanged();
                      },
                    ),
                  ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('추가'),
                onPressed: () => _addConcept(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpeakerLockBanner extends StatelessWidget {
  const _SpeakerLockBanner({required this.onReopen});

  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.hubVoice.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.hubVoice.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded,
              size: 14, color: AppColors.hubVoice.withValues(alpha: 0.85)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '화자는 여기서 수정할 수 없습니다. 잘못 지정했다면 화자 설정으로 돌아가세요.',
              style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: context.shell.primaryText.withValues(alpha: 0.85),
              ),
            ),
          ),
          TextButton(
            onPressed: onReopen,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('화자 다시 설정', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}
