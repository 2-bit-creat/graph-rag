import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/journal_audio_compose_panel.dart';
import '../widgets/precision_text_labeling_panel.dart';
import 'journal_hub_screen.dart';

enum JournalInputMode { voice, text }

// Source type: diary (나 혼자) vs 대화·소스 (나 외 화자가 1명이라도 있는 경우)
enum _SourceType { diary, external }

typedef _SourceCat = ({String key, IconData icon, String label});

const List<_SourceCat> _kExternalSources = [
  (key: '대화',  icon: Icons.forum_outlined,       label: '대화'),
  (key: '회의록', icon: Icons.people_rounded,     label: '회의록'),
  (key: '책',    icon: Icons.menu_book_rounded,   label: '책'),
  (key: '뉴스',  icon: Icons.newspaper_rounded,   label: '뉴스'),
  (key: '강연',  icon: Icons.mic_outlined,         label: '강연'),
  (key: '논문',  icon: Icons.science_outlined,    label: '논문'),
];

/// 일기 작성 — 음성(녹음·파일) 또는 텍스트, 개인 일기(나 혼자) 또는 대화·소스(여러 화자/출처).
class JournalComposeScreen extends StatefulWidget {
  const JournalComposeScreen({
    super.key,
    this.initialMode = JournalInputMode.voice,
    this.initialSourceType = _SourceType.diary,
  });

  final JournalInputMode initialMode;
  final _SourceType initialSourceType;

  @override
  State<JournalComposeScreen> createState() => _JournalComposeScreenState();
}

class _JournalComposeScreenState extends State<JournalComposeScreen> {
  late JournalInputMode _inputMode;
  late _SourceType _sourceType;
  String _sourceCategory = _kExternalSources.first.key;
  bool _creatingText = false;

  @override
  void initState() {
    super.initState();
    _inputMode = widget.initialMode;
    _sourceType = widget.initialSourceType;
  }

  void _openEntry(String entryId) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => JournalHubScreen(initialEntryId: entryId),
      ),
    );
  }

  Future<void> _submitText(String paragraphText) async {
    setState(() => _creatingText = true);
    try {
      final sourceType = _sourceType == _SourceType.external ? _sourceCategory : null;
      final entry = await apiClient.createTextJournalEntry(
        paragraphText,
        sourceType: sourceType,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('기록을 저장했습니다.')),
      );
      final id = entry['id']?.toString();
      if (id != null) _openEntry(id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _creatingText = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isExternal = _sourceType == _SourceType.external;

    return Scaffold(
      appBar: AppHubAppBar(
        title: '일기 쓰기',
        subtitle: isExternal ? '대화·소스 · $_sourceCategory' : '음성 또는 텍스트로 기록',
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Source type toggle ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageH, AppSpacing.md, AppSpacing.pageH, 0,
            ),
            child: SegmentedButton<_SourceType>(
              segments: const [
                ButtonSegment(
                  value: _SourceType.diary,
                  icon: Icon(Icons.book_outlined, size: 16),
                  label: Text('개인 일기'),
                ),
                ButtonSegment(
                  value: _SourceType.external,
                  icon: Icon(Icons.forum_outlined, size: 16),
                  label: Text('대화·소스'),
                ),
              ],
              selected: {_sourceType},
              onSelectionChanged: (v) {
                if (v.isEmpty) return;
                setState(() => _sourceType = v.first);
              },
            ),
          ),

          // ── External source category picker ────────────────────────────────
          if (isExternal)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageH, AppSpacing.sm, AppSpacing.pageH, 0,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _kExternalSources.map((src) {
                    final selected = _sourceCategory == src.key;
                    return Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: FilterChip(
                        avatar: Icon(src.icon, size: 14),
                        label: Text(src.label),
                        selected: selected,
                        onSelected: (_) =>
                            setState(() => _sourceCategory = src.key),
                        visualDensity: VisualDensity.compact,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

          // ── Input mode toggle ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageH, AppSpacing.sm, AppSpacing.pageH, AppSpacing.sm,
            ),
            child: SegmentedButton<JournalInputMode>(
              segments: const [
                ButtonSegment(
                  value: JournalInputMode.voice,
                  icon: Icon(Icons.mic_rounded, size: 18),
                  label: Text('음성'),
                ),
                ButtonSegment(
                  value: JournalInputMode.text,
                  icon: Icon(Icons.edit_note_rounded, size: 18),
                  label: Text('텍스트'),
                ),
              ],
              selected: {_inputMode},
              onSelectionChanged: (value) {
                if (value.isEmpty) return;
                setState(() => _inputMode = value.first);
              },
            ),
          ),

          // ── Content panel ───────────────────────────────────────────────────
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: switch (_inputMode) {
                JournalInputMode.voice => JournalAudioComposePanel(
                    key: ValueKey('voice-$_sourceType'),
                    onEntryCreated: _openEntry,
                    sourceType: _sourceType == _SourceType.external
                        ? _sourceCategory
                        : null,
                  ),
                JournalInputMode.text => SingleChildScrollView(
                    key: ValueKey('text-$_sourceType'),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.pageH, 0, AppSpacing.pageH, AppSpacing.xxl,
                    ),
                    child: PrecisionTextLabelingPanel(
                      onSubmit: _submitText,
                      busy: _creatingText,
                    ),
                  ),
              },
            ),
          ),
        ],
      ),
    );
  }
}
