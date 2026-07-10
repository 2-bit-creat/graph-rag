import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';

/// Bottom sheet: [👍 맞아요] [🔍 다른 사람 선택] [✏️ 직접 입력]
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
    _confirmNewName(_manualController.text);
  }

  void _confirmNewName(String raw) {
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
    for (final node in _pickerItems(personNodesOnly: true)) {
      if ((node['name']?.toString().toLowerCase() ?? '') == q) return true;
    }
    return false;
  }

  List<Map<String, dynamic>> _pickerItems({bool personNodesOnly = false}) {
    final items = <String, Map<String, dynamic>>{};
    if (!personNodesOnly) {
      for (final raw in _rec?['candidates'] as List<dynamic>? ?? []) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString();
        if (id != null) items[id] = Map<String, dynamic>.from(raw);
      }
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
              label: const Text('다른 사람으로 변경'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _submitting
                  ? null
                  : () {
                      _manualController.clear();
                      setState(() => _mode = _Mode.manual);
                    },
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('새 인물 만들기'),
            ),
          ] else if (likelyUnregistered || (conflictHint != null && conflictHint.isNotEmpty)) ...[
            Text(
              conflictHint ??
                  '「${widget.speakerLabel}」은 아직 등록되지 않은 사람일 가능성이 높습니다.',
              style: TextStyle(fontSize: 14, color: Colors.orange[900]),
            ),
            const SizedBox(height: 16),
            _actionButton(
              icon: '🔍',
              label: '다른 사람 선택',
              onPressed: () => setState(() => _mode = _Mode.pickOther),
              filled: true,
            ),
            ..._altCandidateButtons(null, skipPickOtherFallback: true),
            const SizedBox(height: 8),
            _actionButton(
              icon: '✏️',
              label: '새 인물로 직접 입력',
              onPressed: () => setState(() => _mode = _Mode.manual),
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
              label: '직접 입력',
              onPressed: () => setState(() => _mode = _Mode.manual),
            ),
          ] else ...[
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
            ..._altCandidateButtons(null, filledFirst: true),
            const SizedBox(height: 8),
            _actionButton(
              icon: '✏️',
              label: '직접 입력',
              onPressed: () => setState(() => _mode = _Mode.manual),
            ),
          ],
        ] else if (_mode == _Mode.pickOther) ...[
          Text(
            '기존 인물을 고르거나, 없으면 새 이름으로 등록하세요.',
            style: TextStyle(fontSize: 13, color: context.subtleText),
          ),
          const SizedBox(height: 10),
          TextField(
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '이름 검색 또는 새 이름',
              hintText: '예: 장덕환',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            textInputAction: TextInputAction.done,
            onChanged: (v) => setState(() => _search = v.trim()),
            onSubmitted: (v) {
              final name = v.trim();
              if (name.isEmpty) return;
              if (_existingNameMatches(name)) return;
              _confirmNewName(name);
            },
          ),
          if (_search.isNotEmpty && !_existingNameMatches(_search)) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _submitting ? null : () => _confirmNewName(_search),
              icon: const Icon(Icons.person_add),
              label: Text('「$_search」 새 인물로 등록'),
            ),
          ],
          if (_pickerItems(personNodesOnly: true).isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('기존 인물', style: TextStyle(fontSize: 12, color: context.mutedText)),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.3,
              ),
              child: ListView(
                shrinkWrap: true,
                children: _pickerItems(personNodesOnly: true).map((node) {
                  final score = node['match_score'];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_outline, size: 20),
                    title: Text(node['name']?.toString() ?? ''),
                    subtitle: score != null
                        ? Text('음성 유사도 ${(score as num).toStringAsFixed(2)}')
                        : const Text('지식 그래프에 있는 인물'),
                    onTap: _submitting ? null : () => _confirmPicked(node),
                  );
                }).toList(),
              ),
            ),
          ] else if (_search.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '등록된 인물이 없습니다. 이름을 입력해 새 인물을 만드세요.',
              style: TextStyle(fontSize: 12, color: context.mutedText),
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _submitting
                ? null
                : () {
                    _manualController.text = _search;
                    setState(() => _mode = _Mode.manual);
                  },
            icon: const Icon(Icons.edit_outlined),
            label: const Text('새 이름 직접 입력'),
          ),
          TextButton(
            onPressed: _submitting ? null : () => setState(() => _mode = _Mode.main),
            child: const Text('뒤로'),
          ),
        ] else ...[
          Text(
            '지식 그래프에 새 Speaker 노드를 만들고 이 화자에 연결합니다.',
            style: TextStyle(fontSize: 13, color: context.subtleText),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _manualController,
            autofocus: true,
            enabled: !_submitting,
            decoration: const InputDecoration(
              labelText: '새 인물 이름',
              hintText: '예: 장덕환',
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
                : const Text('새 인물로 등록'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _submitting ? null : () => setState(() => _mode = _Mode.pickOther),
            child: const Text('기존 인물에서 고르기'),
          ),
          TextButton(
            onPressed: _submitting ? null : () => setState(() => _mode = _Mode.main),
            child: const Text('뒤로'),
          ),
        ],
      ],
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
          label: '다른 사람 선택',
          onPressed: () => setState(() => _mode = _Mode.pickOther),
        ),
      ));
    } else if (widgets.isNotEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton(
          onPressed: _submitting ? null : () => setState(() => _mode = _Mode.pickOther),
          child: const Text('더 많은 사람 보기'),
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
