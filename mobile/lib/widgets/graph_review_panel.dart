import 'package:flutter/material.dart';

import '../api/client.dart';
import '../chat/journal_task_controller.dart';
import '../compose/compose_session_controller.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';

/// Inline or full-screen graph draft review — edit claims, then confirm.
class GraphReviewPanel extends StatefulWidget {
  const GraphReviewPanel({
    super.key,
    required this.entryId,
    required this.staging,
    this.maxBodyHeight = 440,
    this.onApplied,
  });

  final String entryId;
  final Map<String, dynamic> staging;

  /// Scroll area cap when embedded in chat cards.
  final double maxBodyHeight;

  /// Called after a successful apply (optional — e.g. pop a route).
  final VoidCallback? onApplied;

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

  @override
  Widget build(BuildContext context) {
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
              personCandidates: _personCandidates,
              onDelete: () => _deleteClaim(i),
              onConceptsChanged: () => setState(() {}),
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
        FilledButton.icon(
          onPressed: _submitting ? null : _confirm,
          icon: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_circle_outline),
          label: Text(_submitting ? '확정 중…' : '확정하고 지식그래프에 추가'),
        ),
      ],
    );
  }
}

class _ClaimCard extends StatelessWidget {
  const _ClaimCard({
    required this.claim,
    required this.personCandidates,
    required this.onDelete,
    required this.onConceptsChanged,
  });

  final _ClaimDraft claim;
  final List<_PersonCandidate> personCandidates;
  final VoidCallback onDelete;
  final VoidCallback onConceptsChanged;

  Future<void> _resolvePerson(BuildContext context, _ConceptDraft c) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
                child: Text(
                  "'${c.name}' 은(는) 누구/무엇인가요?",
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
              ),
              if (c.resAction == 'suggest' && c.resNodeId != null) ...[
                Container(
                  margin: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: const Color(0x22FFB020),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x55FFB020)),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.auto_awesome,
                        color: Color(0xFFFFB020)),
                    title: Text('추천: ${c.resName ?? ''} 맞아요'),
                    subtitle: const Text('이름은 다르지만 같은 대상 같아요 — 확인하면 학습합니다.'),
                    onTap: () {
                      c.resAction = 'link';
                      Navigator.pop(ctx);
                      onConceptsChanged();
                    },
                  ),
                ),
              ],
              ListTile(
                leading: const Icon(Icons.person_add_alt_1),
                title: const Text('새 정체성으로 추가'),
                subtitle: const Text('사람·반려동물·단체 등 개체 노드를 새로 만듭니다.'),
                selected: c.resAction == null || c.resAction == 'new_person',
                onTap: () {
                  c.resAction = 'new_person';
                  c.resNodeId = null;
                  c.resName = null;
                  c.resIsSelf = false;
                  Navigator.pop(ctx);
                  onConceptsChanged();
                },
              ),
              ListTile(
                leading: const Icon(Icons.lightbulb_outline),
                title: const Text('개체가 아니라 개념으로'),
                subtitle: const Text('정체성이 아니라 일반 개념(Concept)으로 저장합니다.'),
                selected: c.resAction == 'concept',
                onTap: () {
                  c.kind = 'concept';
                  c.resAction = 'concept';
                  c.resNodeId = null;
                  c.resName = null;
                  c.resIsSelf = false;
                  Navigator.pop(ctx);
                  onConceptsChanged();
                },
              ),
              if (personCandidates.isNotEmpty) ...[
                const Divider(height: AppSpacing.lg),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                  child: Text('기존 정체성에 연결',
                      style: Theme.of(ctx).textTheme.bodySmall),
                ),
                for (final p in personCandidates)
                  ListTile(
                    leading: Icon(
                        p.isSelf ? Icons.account_circle : Icons.person_outline),
                    title: Text(p.isSelf ? '${p.name} (본인)' : p.name),
                    selected: c.resAction == 'link' && c.resNodeId == p.id,
                    trailing: (c.resAction == 'link' && c.resNodeId == p.id)
                        ? const Icon(Icons.check, color: AppColors.accent)
                        : null,
                    onTap: () {
                      c.resAction = 'link';
                      c.resNodeId = p.id;
                      c.resName = p.name;
                      c.resIsSelf = p.isSelf;
                      Navigator.pop(ctx);
                      onConceptsChanged();
                    },
                  ),
              ],
            ],
          ),
        );
      },
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
    return AppSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: claim.speaker,
                  style: Theme.of(context).textTheme.titleSmall,
                  decoration: const InputDecoration(
                    labelText: '화자',
                    isDense: true,
                  ),
                ),
              ),
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
