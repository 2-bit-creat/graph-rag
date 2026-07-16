import 'package:flutter/material.dart';

import '../api/client.dart';
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
      setState(() => _error = '이름을 입력해 주세요.');
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

  bool _isSourceType(Map<String, dynamic> node) =>
      (node['type']?.toString() ?? '').trim().toLowerCase() == 'source';

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + bottom),
      child: _loading
          ? const SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator()),
            )
          : _buildBody(context),
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
              '${confirmed['name']} (으)로 확인되었습니다.',
              style: TextStyle(color: Colors.green[800]),
            ),
            if (score != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '음성 유사도 ${(score as num).toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 12, color: context.mutedText),
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _submitting ? null : () => setState(() => _mode = _Mode.pickOther),
              icon: const Icon(Icons.edit),
              label: const Text('기존 정체성에서 고르기'),
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
              label: const Text('새 정체성 등록'),
            ),
          ] else if (likelyUnregistered || (conflictHint != null && conflictHint.isNotEmpty)) ...[
            Text(
              conflictHint ??
                  '「${widget.speakerLabel}」은 아직 등록되지 않은 정체성일 가능성이 높습니다.',
              style: TextStyle(fontSize: 14, color: Colors.orange[900]),
            ),
            const SizedBox(height: 16),
            _actionButton(
              icon: '🔍',
              label: '기존 정체성에서 고르기',
              onPressed: () => setState(() => _mode = _Mode.pickOther),
              filled: true,
            ),
            ..._altCandidateButtons(null, skipPickOtherFallback: true),
            const SizedBox(height: 8),
            _actionButton(
              icon: '✏️',
              label: '새 정체성 등록',
              onPressed: () {
                _manualController.clear();
                _newIsSource = false;
                setState(() => _mode = _Mode.manual);
              },
            ),
          ] else if (above && recommended != null) ...[
            Text(
              '목소리가 「${recommended['name']}」와(과) 비슷합니다. 맞나요?',
              style: const TextStyle(fontSize: 15),
            ),
            if (score != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '음성 유사도 ${(score as num).toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 12, color: context.mutedText),
                ),
              ),
            const SizedBox(height: 16),
            _actionButton(
              icon: '👍',
              label: '${recommended['name']} 맞아요',
              onPressed: _confirmRecommended,
              filled: true,
            ),
            ..._altCandidateButtons(recommended),
            const SizedBox(height: 8),
            _actionButton(
              icon: '✏️',
              label: '기존 정체성에서 고르기 / 새로 등록',
              onPressed: () => setState(() => _mode = _Mode.pickOther),
            ),
          ] else ...[
            // The plain "who is this?" case — no voice match to lean on. Always
            // present the two top-level choices side by side: every identity
            // (not just a "person") can be this segment's speaker.
            Text(
              '「${widget.speakerLabel}」 화자가 누구인가요?',
              style: const TextStyle(fontSize: 15),
            ),
            if (score != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '최고 유사도 ${(score as num).toStringAsFixed(2)} (임계값 미달)',
                  style: TextStyle(fontSize: 12, color: context.mutedText),
                ),
              ),
            const SizedBox(height: 12),
            ..._altCandidateButtons(null, filledFirst: true, skipPickOtherFallback: true),
            const SizedBox(height: 8),
            _actionButton(
              icon: '✨',
              label: '새 정체성 등록',
              onPressed: () {
                _manualController.clear();
                _newIsSource = false;
                setState(() => _mode = _Mode.manual);
              },
              filled: true,
            ),
            const SizedBox(height: 8),
            _actionButton(
              icon: '📋',
              label: '기존 정체성에서 고르기',
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
          '기존 정체성을 고르거나, 없으면 새로 등록하세요.',
          style: TextStyle(fontSize: 13, color: context.subtleText),
        ),
        const SizedBox(height: 10),
        TextField(
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '이름 검색 또는 새 이름',
            hintText: '예: 장덕환 · 기업은행',
            prefixIcon: Icon(Icons.search),
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
              _newIsSource ? '「$_search」 출처로 등록' : '「$_search」 새 정체성으로 등록',
            ),
          ),
        ],
        if (items.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('기존 정체성', style: TextStyle(fontSize: 12, color: context.mutedText)),
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
                return ListTile(
                  dense: true,
                  leading: Icon(
                    isSource ? Icons.menu_book_rounded : Icons.person_outline,
                    size: 20,
                  ),
                  title: Text(node['name']?.toString() ?? ''),
                  subtitle: score != null
                      ? Text('음성 유사도 ${(score as num).toStringAsFixed(2)}')
                      : Text(isSource ? '지식 그래프에 있는 출처' : '지식 그래프에 있는 정체성'),
                  onTap: _submitting ? null : () => _confirmPicked(node),
                );
              }).toList(),
            ),
          ),
        ] else if (_search.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '등록된 정체성이 없습니다. 이름을 입력해 새로 만드세요.',
            style: TextStyle(fontSize: 12, color: context.mutedText),
          ),
        ],
        const SizedBox(height: 8),
        TextButton(
          onPressed: _submitting ? null : () => setState(() => _mode = _Mode.main),
          child: const Text('뒤로'),
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
          '지식 그래프에 새 정체성을 만들고 이 화자에 연결합니다.',
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
            labelText: _newIsSource ? '새 출처 이름' : '새 인물 이름',
            hintText: _newIsSource ? '예: 기업은행 · 한국경제' : '예: 장덕환',
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
              : Text(_newIsSource ? '출처로 등록' : '인물로 등록'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _submitting ? null : () => setState(() => _mode = _Mode.main),
          child: const Text('뒤로'),
        ),
      ],
    );
  }

  /// 인물(Person) / 출처(Source) — which kind of identity a brand-new name is.
  /// Voice binding stays possible either way; it's just unlikely a Source
  /// (기업은행 같은) will ever actually carry one.
  Widget _typeToggle() {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(
          value: false,
          label: Text('인물'),
          icon: Icon(Icons.person_outline, size: 16),
        ),
        ButtonSegment(
          value: true,
          label: Text('출처'),
          icon: Icon(Icons.menu_book_rounded, size: 16),
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
          icon: '',
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
          icon: '🔍',
          label: '기존 정체성에서 고르기',
          onPressed: () => setState(() => _mode = _Mode.pickOther),
        ),
      ));
    } else if (widgets.isNotEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton(
          onPressed: _submitting ? null : () => setState(() => _mode = _Mode.pickOther),
          child: const Text('더 많은 정체성 보기'),
        ),
      ));
    }
    return widgets;
  }

  Widget _actionButton({
    required String icon,
    required String label,
    required VoidCallback onPressed,
    bool filled = false,
  }) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon.isNotEmpty) ...[
          Text(icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
        ],
        Text(label),
      ],
    );
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
