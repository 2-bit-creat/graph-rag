import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Bottom sheet: confirm who a diarized/session speaker label actually is.
///
/// The graph's 정체성 (identity) category spans Person ∪ Source ∪ generic
/// Identity — ANY recurring identity can be a "화자" (speaker), not just
/// people (e.g. an external Source like "기업은행" publishing a statement).
/// So the two top-level choices when there's no strong voice match are always
/// "새 정체성 등록" (create) and "기존 정체성에서 고르기" (pick existing) — never
/// a single ambiguous "직접 입력" button that buries the existing-picker one
/// level deeper.
Future<bool?> showSpeakerIdentitySheet({
  required BuildContext context,
  required String entryId,
  required String speakerLabel,
  required String speakerProfileId,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _SpeakerIdentitySheet(
      entryId: entryId,
      speakerLabel: speakerLabel,
      speakerProfileId: speakerProfileId,
    ),
  );
}

class _SpeakerIdentitySheet extends StatefulWidget {
  const _SpeakerIdentitySheet({
    required this.entryId,
    required this.speakerLabel,
    required this.speakerProfileId,
  });

  final String entryId;
  final String speakerLabel;
  final String speakerProfileId;

  @override
  State<_SpeakerIdentitySheet> createState() => _SpeakerIdentitySheetState();
}

enum _Mode { main, pickOther, manual }

class _SpeakerIdentitySheetState extends State<_SpeakerIdentitySheet> {
  _Mode _mode = _Mode.main;
  Map<String, dynamic>? _rec;
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  final _manualController = TextEditingController();
  String _search = '';

  /// Type toggle for a brand-new identity — shared by the manual-create screen
  /// and the inline "no match, register new" row on the existing-picker screen.
  bool _newIsSource = false;

  @override
  void initState() {
    super.initState();
    _loadRecommend();
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _loadRecommend() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rec = await apiClient.speakerRecommend(
        journalEntryId: widget.entryId,
        speakerLabel: widget.speakerLabel,
      );
      if (!mounted) return;
      setState(() {
        _rec = rec;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _popResult(bool value) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    Navigator.of(context).pop(value);
  }

  Future<void> _confirm({
    String? nodeId,
    String? newNodeName,
    String? wrongName,
    bool asSource = false,
  }) async {
    if (_submitting) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await apiClient.speakerConfirm(
        journalEntryId: widget.entryId,
        speakerProfileId: widget.speakerProfileId,
        sessionLabel: widget.speakerLabel,
        nodeId: nodeId,
        newNodeName: newNodeName,
        wrongName: wrongName,
        asSource: asSource,
      );
      if (!mounted) return;
      await _popResult(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _confirmRecommended() {
    final node = _rec?['recommended_node'] as Map<String, dynamic>?;
    if (node == null) return;
    _confirm(nodeId: node['id']?.toString());
  }

  /// Picking an EXISTING node — its type is already whatever it already is
  /// (Person/Source/Identity), so no asSource flag needed here.
  void _confirmPicked(Map<String, dynamic> node) {
    final pickedName = node['name']?.toString() ?? '';
    final wrong = _wrongNameForReject();
    _confirm(
      nodeId: node['id']?.toString(),
      newNodeName: pickedName.isNotEmpty ? pickedName : null,
      wrongName: wrong.isNotEmpty && wrong != pickedName ? wrong : null,
    );
  }

  void _confirmManual() {
    _confirmNewName(_manualController.text, asSource: _newIsSource);
  }

  void _confirmNewName(String raw, {bool asSource = false}) {
    final name = raw.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('speakerId.nameRequired'));
      return;
    }
    if (_submitting) return;
    final wrong = _wrongNameForReject();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _confirm(
        newNodeName: name,
        wrongName: wrong.isNotEmpty && wrong != name ? wrong : null,
        asSource: asSource,
      );
    });
  }

  String _wrongNameForReject() {
    final recommended = _rec?['recommended_node'] as Map<String, dynamic>?;
    final confirmed = _rec?['confirmed_node'] as Map<String, dynamic>?;
    return recommended?['name']?.toString()
        ?? confirmed?['name']?.toString()
        ?? '';
  }

  bool _existingNameMatches(String name) {
    final q = name.trim().toLowerCase();
    if (q.isEmpty) return false;
    for (final node in _pickerItems()) {
      if ((node['name']?.toString().toLowerCase() ?? '') == q) return true;
    }
    return false;
  }

  /// Existing identities offered in the "기존 정체성에서 고르기" list — the whole
  /// identity category (Person/Source/Identity), not just people. Voice-matched
  /// [candidates] only ever surface Person nodes in practice (Source rarely has
  /// a voiceprint), so including them here is harmless.
  List<Map<String, dynamic>> _pickerItems() {
    final items = <String, Map<String, dynamic>>{};
    for (final raw in _rec?['candidates'] as List<dynamic>? ?? []) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString();
      if (id != null) items[id] = Map<String, dynamic>.from(raw);
    }
    for (final raw in _rec?['person_nodes'] as List<dynamic>? ?? []) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString();
      if (id != null) items.putIfAbsent(id, () => Map<String, dynamic>.from(raw));
    }
    var list = items.values.toList();
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list.where((n) => (n['name']?.toString().toLowerCase() ?? '').contains(q)).toList();
    }
    list.sort((a, b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
    return list;
  }

  // `type` is always "Identity" now — is_source is what used to be a distinct
  // "Source" type string (see backend entity_types.py). Falls back to the
  // literal string for any stale cached payload from before that change.
  bool _isSourceType(Map<String, dynamic> node) =>
      node['is_source'] == true ||
      (node['type']?.toString() ?? '').trim().toLowerCase() == 'source';

  /// The OTHER speaker label in this entry already confirmed as this identity.
  String? _claimedLabel(Map<String, dynamic> node) {
    final label = node['claimed_by_label']?.toString().trim();
    return (label == null || label.isEmpty) ? null : label;
  }

  /// Treat this label and the one that already owns the identity as one person.
  ///
  /// The case this exists for: OCR read the same name two ways ("정승헌" and
  /// "정승현"), so the entry has two speaker labels that are one person. Simply
  /// confirming both onto the same node is not enough — the transcript still
  /// carries two speakers, and the graph would get two. Remapping the labels is
  /// what actually merges them, and it stays reversible because the original
  /// diarization label is kept per segment.
  Future<void> _mergeWithLabel(Map<String, dynamic> node) async {
    final target = _claimedLabel(node);
    if (target == null || _submitting) return;
    final source = widget.speakerLabel;
    if (source == target) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('speakerId.mergeLabelsTitle')),
        content: Text(tr(
          'speakerId.mergeLabelsBody',
          {'from': source, 'to': target},
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('speakerId.mergeLabelsConfirm')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await apiClient.remapSpeakers(
        widget.entryId,
        merges: {source: target},
      );
      if (!mounted) return;
      await _popResult(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final availableHeight = MediaQuery.sizeOf(context).height - bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: availableHeight * 0.86),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: _loading
              ? const SizedBox(
                  height: 160,
                  child: Center(child: CircularProgressIndicator()),
                )
              : _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final already = _rec?['already_confirmed'] == true;
    final confirmed = _rec?['confirmed_node'] as Map<String, dynamic>?;
    final recommended = _rec?['recommended_node'] as Map<String, dynamic>?;
    final above = _rec?['above_threshold'] == true;
    final likelyUnregistered = _rec?['likely_unregistered'] == true;
    final conflictHint = _rec?['session_conflict_hint']?.toString();
    final score = _rec?['match_score'];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.speakerLabel,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, style: TextStyle(color: Colors.red[700], fontSize: 12)),
          ),
        if (_mode == _Mode.main) ...[
          if (already && confirmed != null) ...[
            Text(
              tr('speakerId.confirmedAs', {'name': confirmed['name']}),
              style: TextStyle(color: Colors.green[800]),
            ),
            if (score != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  tr('speakerId.voiceSimilarity', {'score': (score as num).toStringAsFixed(2)}),
                  style: TextStyle(fontSize: 12, color: context.mutedText),
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _submitting ? null : () => setState(() => _mode = _Mode.pickOther),
              icon: const Icon(Icons.edit),
              label: Text(tr('speakerId.pickExisting')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _submitting
                  ? null
                  : () {
                      _manualController.clear();
                      _newIsSource = false;
                      setState(() => _mode = _Mode.manual);
                    },
              icon: const Icon(Icons.person_add_outlined),
              label: Text(tr('speakerId.registerNew')),
            ),
          ] else if (likelyUnregistered || (conflictHint != null && conflictHint.isNotEmpty)) ...[
            Text(
              conflictHint ??
                  tr('speakerId.likelyUnregisteredHint', {'label': widget.speakerLabel}),
              style: TextStyle(fontSize: 14, color: Colors.orange[900]),
            ),
            const SizedBox(height: 16),
            _actionButton(
              label: tr('speakerId.pickExisting'),
              onPressed: () => setState(() => _mode = _Mode.pickOther),
              filled: true,
            ),
            ..._altCandidateButtons(null, skipPickOtherFallback: true),
            const SizedBox(height: 8),
            _actionButton(
              label: tr('speakerId.registerNew'),
              onPressed: () {
                _manualController.clear();
                _newIsSource = false;
                setState(() => _mode = _Mode.manual);
              },
            ),
          ] else if (above && recommended != null) ...[
            Text(
              tr('speakerId.voiceSimilarTo', {'name': recommended['name']}),
              style: const TextStyle(fontSize: 15),
            ),
            if (score != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  tr('speakerId.voiceSimilarity', {'score': (score as num).toStringAsFixed(2)}),
                  style: TextStyle(fontSize: 12, color: context.mutedText),
                ),
              ),
            const SizedBox(height: 16),
            _actionButton(
              label: tr('speakerId.correctName', {'name': recommended['name']}),
              onPressed: _confirmRecommended,
              filled: true,
            ),
            ..._altCandidateButtons(recommended),
            const SizedBox(height: 8),
            _actionButton(
              label: tr('speakerId.pickOrRegisterNew'),
              onPressed: () => setState(() => _mode = _Mode.pickOther),
            ),
          ] else ...[
            // The plain "who is this?" case — no voice match to lean on. Always
            // present the two top-level choices side by side: every identity
            // (not just a "person") can be this segment's speaker.
            Text(
              tr('speakerId.whoIsSpeaker', {'label': widget.speakerLabel}),
              style: const TextStyle(fontSize: 15),
            ),
            if (score != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  tr('speakerId.topSimilarityBelowThreshold', {'score': (score as num).toStringAsFixed(2)}),
                  style: TextStyle(fontSize: 12, color: context.mutedText),
                ),
              ),
            const SizedBox(height: 12),
            ..._altCandidateButtons(null, filledFirst: true, skipPickOtherFallback: true),
            const SizedBox(height: 8),
            _actionButton(
              label: tr('speakerId.registerNew'),
              onPressed: () {
                _manualController.clear();
                _newIsSource = false;
                setState(() => _mode = _Mode.manual);
              },
              filled: true,
            ),
            const SizedBox(height: 8),
            _actionButton(
              label: tr('speakerId.pickExisting'),
              onPressed: () => setState(() => _mode = _Mode.pickOther),
            ),
          ],
        ] else if (_mode == _Mode.pickOther) ...[
          _buildPickOther(context),
        ] else ...[
          _buildManual(context),
        ],
      ],
    );
  }

  /// "기존 정체성에서 고르기" — search box on top, full identity list below.
  /// Each row's icon distinguishes Person from Source; a Source never merges
  /// with a same-name Person, so both can legitimately appear.
  Widget _buildPickOther(BuildContext context) {
    final items = _pickerItems();
    final noMatch = _search.isNotEmpty && !_existingNameMatches(_search);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr('speakerId.pickOrRegisterHint'),
          style: TextStyle(fontSize: 13, color: context.subtleText),
        ),
        const SizedBox(height: 10),
        TextField(
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('speakerId.nameSearchLabel'),
            hintText: tr('speakerId.nameSearchHint'),
            prefixIcon: const Icon(Icons.search),
            isDense: true,
          ),
          textInputAction: TextInputAction.done,
          onChanged: (v) => setState(() => _search = v.trim()),
          onSubmitted: (v) {
            final name = v.trim();
            if (name.isEmpty || _existingNameMatches(name)) return;
            _confirmNewName(name, asSource: _newIsSource);
          },
        ),
        if (noMatch) ...[
          const SizedBox(height: 10),
          _typeToggle(),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _submitting
                ? null
                : () => _confirmNewName(_search, asSource: _newIsSource),
            icon: Icon(_newIsSource ? Icons.menu_book_rounded : Icons.person_add),
            label: Text(
              _newIsSource
                  ? tr('speakerId.registerAsSource', {'name': _search})
                  : tr('speakerId.registerAsNewIdentity', {'name': _search}),
            ),
          ),
        ],
        if (items.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(tr('speakerId.existingIdentities'), style: TextStyle(fontSize: 12, color: context.mutedText)),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.32,
            ),
            child: ListView(
              shrinkWrap: true,
              children: items.map((node) {
                final score = node['match_score'];
                final isSource = _isSourceType(node);
                // Already used by another label in THIS entry. Offered anyway —
                // that is usually the same person under two OCR spellings, and
                // hiding it was what left the typo unfixable. Tapping it merges
                // the two labels instead of confirming a second link.
                final claimed = _claimedLabel(node);
                return ListTile(
                  dense: true,
                  leading: Icon(
                    claimed != null
                        ? Icons.merge_rounded
                        : isSource
                            ? Icons.menu_book_rounded
                            : Icons.person_outline,
                    size: 20,
                    color: claimed != null
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(node['name']?.toString() ?? ''),
                  subtitle: claimed != null
                      ? Text(
                          tr('speakerId.claimedByLabel', {'label': claimed}),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        )
                      : score != null
                          ? Text(tr('speakerId.voiceSimilarity', {'score': (score as num).toStringAsFixed(2)}))
                          : Text(isSource ? tr('speakerId.sourceInGraph') : tr('speakerId.identityInGraph')),
                  onTap: _submitting
                      ? null
                      : () => claimed != null
                          ? _mergeWithLabel(node)
                          : _confirmPicked(node),
                );
              }).toList(),
            ),
          ),
        ] else if (_search.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            tr('speakerId.noRegisteredIdentities'),
            style: TextStyle(fontSize: 12, color: context.mutedText),
          ),
        ],
        const SizedBox(height: 8),
        TextButton(
          onPressed: _submitting ? null : () => setState(() => _mode = _Mode.main),
          child: Text(tr('speakerId.backButton')),
        ),
      ],
    );
  }

  /// "새 정체성 등록" — a type toggle up front (인물 vs 출처), then the name.
  Widget _buildManual(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr('speakerId.manualIntro'),
          style: TextStyle(fontSize: 13, color: context.subtleText),
        ),
        const SizedBox(height: 10),
        _typeToggle(),
        const SizedBox(height: 10),
        TextField(
          controller: _manualController,
          autofocus: true,
          enabled: !_submitting,
          decoration: InputDecoration(
            labelText: _newIsSource ? tr('speakerId.newSourceNameLabel') : tr('speakerId.newPersonNameLabel'),
            hintText: _newIsSource ? tr('speakerId.newSourceNameHint') : tr('speakerId.newPersonNameHint'),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _confirmManual(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _submitting ? null : _confirmManual,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_newIsSource ? tr('speakerId.registerAsSourceButton') : tr('speakerId.registerAsPersonButton')),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _submitting ? null : () => setState(() => _mode = _Mode.main),
          child: Text(tr('speakerId.backButton')),
        ),
      ],
    );
  }

  /// 인물(Person) / 출처(Source) — which kind of identity a brand-new name is.
  /// Voice binding stays possible either way; it's just unlikely a Source
  /// (기업은행 같은) will ever actually carry one.
  Widget _typeToggle() {
    return SegmentedButton<bool>(
      segments: [
        ButtonSegment(
          value: false,
          label: Text(tr('speakerId.typePerson')),
          icon: const Icon(Icons.person_outline, size: 16),
        ),
        ButtonSegment(
          value: true,
          label: Text(tr('speakerId.typeSource')),
          icon: const Icon(Icons.menu_book_rounded, size: 16),
        ),
      ],
      selected: {_newIsSource},
      onSelectionChanged: _submitting
          ? null
          : (selection) => setState(() => _newIsSource = selection.first),
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  List<Widget> _altCandidateButtons(
    Map<String, dynamic>? recommended, {
    bool filledFirst = false,
    bool skipPickOtherFallback = false,
  }) {
    final recId = recommended?['id']?.toString();
    final widgets = <Widget>[];
    var idx = 0;
    for (final raw in _rec?['candidates'] as List<dynamic>? ?? []) {
      if (raw is! Map) continue;
      if (raw['id']?.toString() == recId) continue;
      final name = raw['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      if (idx >= 3) break;
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _actionButton(
          label: name,
          onPressed: () => _confirmPicked(Map<String, dynamic>.from(raw)),
          filled: filledFirst && idx == 0,
        ),
      ));
      idx++;
    }
    if (widgets.isEmpty && !filledFirst && !skipPickOtherFallback) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _actionButton(
          label: tr('speakerId.pickExisting'),
          onPressed: () => setState(() => _mode = _Mode.pickOther),
        ),
      ));
    } else if (widgets.isNotEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton(
          onPressed: _submitting ? null : () => setState(() => _mode = _Mode.pickOther),
          child: Text(tr('speakerId.seeMoreIdentities')),
        ),
      ));
    }
    return widgets;
  }

  Widget _actionButton({
    required String label,
    required VoidCallback onPressed,
    bool filled = false,
  }) {
    final child = Text(label);
    if (filled) {
      return FilledButton(
        onPressed: _submitting ? null : onPressed,
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: _submitting ? null : onPressed,
      child: child,
    );
  }
}
