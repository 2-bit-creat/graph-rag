import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/paragraph_formatter.dart';

void main() {
  group('paragraph_formatter', () {
    test('buildParagraphText formats speaker lines', () {
      const full = '안녕하세요. 네 알겠습니다.';
      final text = buildParagraphText(full, [
        const LabeledSpanInput(start: 0, end: 6, speaker: '팀장'),
        const LabeledSpanInput(start: 7, end: 15, speaker: '나'),
      ]);
      expect(text, '[팀장]: 안녕하세요.\n[나]: 네 알겠습니다.');
    });

    test('buildParagraphText excludes ignore spans', () {
      const full = '비밀구간공개구간';
      final text = buildParagraphText(full, [
        const LabeledSpanInput(start: 0, end: 4, speaker: ignoreSpeaker),
        const LabeledSpanInput(start: 4, end: 8, speaker: '나'),
      ]);
      expect(text, '[나]: 공개구간');
    });
  });

  group('PrecisionTextLabelingPanel', () {
    testWidgets('highlights labeled span and submits paragraph', (tester) async {
      var submitted = '';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _TestLabelingHarness(
              onSubmit: (p) async {
                submitted = p;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '팀장 안녕하세요');
      await tester.tap(find.text('화자 라벨링 시작'));
      await tester.pumpAndSettle();

      final selectable = tester.widget<SelectableText>(find.byType(SelectableText));
      selectable.onSelectionChanged?.call(
        const TextSelection(baseOffset: 0, extentOffset: 3),
        SelectionChangedCause.tap,
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(ActionChip, '팀장'));
      await tester.pumpAndSettle();

      final rich = tester.widget<SelectableText>(find.byType(SelectableText));
      final span = rich.textSpan!;
      expect(span.children, isNotEmpty);
      final hasHighlight = span.children!.any(
        (c) => c is TextSpan && c.style?.backgroundColor != null,
      );
      expect(hasHighlight, isTrue);

      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();

      expect(submitted, startsWith('[팀장]:'));
    });
  });
}

class _TestLabelingHarness extends StatefulWidget {
  const _TestLabelingHarness({required this.onSubmit});

  final Future<void> Function(String paragraphText) onSubmit;

  @override
  State<_TestLabelingHarness> createState() => _TestLabelingHarnessState();
}

class _TestLabelingHarnessState extends State<_TestLabelingHarness> {
  @override
  Widget build(BuildContext context) {
    return PrecisionTextLabelingPanelHarness(
      onSubmit: widget.onSubmit,
    );
  }
}

/// Minimal harness without API calls for widget tests.
class PrecisionTextLabelingPanelHarness extends StatefulWidget {
  const PrecisionTextLabelingPanelHarness({
    super.key,
    required this.onSubmit,
  });

  final Future<void> Function(String paragraphText) onSubmit;

  @override
  State<PrecisionTextLabelingPanelHarness> createState() =>
      _PrecisionTextLabelingPanelHarnessState();
}

class _PrecisionTextLabelingPanelHarnessState
    extends State<PrecisionTextLabelingPanelHarness> {
  final _composeCtrl = TextEditingController();
  bool _labeling = false;
  String _fullText = '';
  final List<_Span> _spans = [];
  TextSelection? _selection;

  static const _palette = [Color(0xFF6366F1)];

  @override
  void dispose() {
    _composeCtrl.dispose();
    super.dispose();
  }

  void _startLabeling() {
    setState(() {
      _fullText = _composeCtrl.text.trim();
      _labeling = true;
      _spans.clear();
    });
  }

  void _applySpeaker(String speaker) {
    final sel = _selection;
    if (sel == null || !sel.isValid || sel.isCollapsed) return;
    setState(() {
      _spans
        ..removeWhere((s) => !(s.end <= sel.start || s.start >= sel.end))
        ..add(_Span(sel.start, sel.end, speaker));
      _selection = null;
    });
  }

  String _buildParagraph() {
    return buildParagraphText(
      _fullText,
      _spans.map((s) => LabeledSpanInput(start: s.start, end: s.end, speaker: s.speaker)).toList(),
    );
  }

  TextSpan _highlighted() {
    if (_spans.isEmpty) {
      return TextSpan(text: _fullText);
    }
    final children = <InlineSpan>[];
    var cursor = 0;
    final sorted = [..._spans]..sort((a, b) => a.start.compareTo(b.start));
    for (final span in sorted) {
      if (span.start > cursor) {
        children.add(TextSpan(text: _fullText.substring(cursor, span.start)));
      }
      children.add(
        TextSpan(
          text: _fullText.substring(span.start, span.end),
          style: TextStyle(backgroundColor: _palette.first.withValues(alpha: 0.35)),
        ),
      );
      cursor = span.end;
    }
    if (cursor < _fullText.length) {
      children.add(TextSpan(text: _fullText.substring(cursor)));
    }
    return TextSpan(children: children);
  }

  @override
  Widget build(BuildContext context) {
    if (!_labeling) {
      return Column(
        children: [
          TextField(controller: _composeCtrl, maxLines: 3),
          ElevatedButton(onPressed: _startLabeling, child: const Text('화자 라벨링 시작')),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText.rich(
          _highlighted(),
          onSelectionChanged: (sel, _) => setState(() => _selection = sel),
        ),
        ActionChip(label: const Text('팀장'), onPressed: () => _applySpeaker('팀장')),
        ElevatedButton(
          onPressed: () => widget.onSubmit(_buildParagraph()),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class _Span {
  _Span(this.start, this.end, this.speaker);
  final int start;
  final int end;
  final String speaker;
}
