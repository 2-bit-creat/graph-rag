import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey, MaxLengthEnforcement;

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart' show isSpeakerLikeType, isStatementHeadType;
import '../widgets/app_ui.dart';

// 추출 품질이 급격히 떨어지는 지점 이전으로 캡 (백엔드 JournalTextEntryRequest와 동일).
const kMaxJournalTextChars = 4000;

/// '나' 배지 고정 색 — 화자 확인 칩의 확정(초록) 톤과 맞춘다.
const _selfColor = Color(0xFF2E7D32);

/// 그 외 화자 배지 색 팔레트 — 등장 순서대로 배정.
const _speakerPalette = <Color>[
  Color(0xFF6750A4), // 보라
  Color(0xFF00639B), // 파랑
  Color(0xFFB3261E), // 빨강
  Color(0xFF7D5260), // 로즈
  Color(0xFF9A6400), // 앰버
  Color(0xFF006A60), // 청록
  Color(0xFF8E4585), // 자주
  Color(0xFF5B6236), // 올리브
];

/// 본문에서 발견된 "@배지" 멘션.
class _MentionHit {
  const _MentionHit(this.start, this.end, this.name);

  final int start; // '@' 위치
  final int end; // 이름 끝 (exclusive)
  final String name;
}

/// @ 팝업 후보: 세션에서 만든 배지 + 지식그래프의 화자·출처 노드.
class _SpeakerOption {
  const _SpeakerOption(this.name, {this.isSource = false});

  final String name;
  final bool isSource;
}

/// "[이름]: …" / "이름: …" 형식 붙여넣기 지원 — 백엔드 pre_slice와 같은 규칙.
class _ParsedDialogue {
  const _ParsedDialogue(this.lines);

  final List<MapEntry<String, String>> lines;

  List<String> get speakers {
    final seen = <String>{};
    final out = <String>[];
    for (final e in lines) {
      if (seen.add(e.key)) out.add(e.key);
    }
    return out;
  }
}

final _bracketLineRe = RegExp(r'^\s*\[([^\]]+)\]\s*[:：]\s*(.+)$');
final _bareLineRe =
    RegExp(r'^\s*([A-Za-z가-힣][A-Za-z가-힣 ._\-]{0,11}?)\s*[:：]\s*(.+)$');

_ParsedDialogue? _parseDialogueLines(String text) {
  final rawLines =
      text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (rawLines.isEmpty) return null;

  var lines = <MapEntry<String, String>>[];
  var matched = 0;
  for (final line in rawLines) {
    final m = _bracketLineRe.firstMatch(line);
    if (m != null) {
      lines.add(MapEntry(m.group(1)!.trim(), m.group(2)!.trim()));
      matched++;
    } else if (lines.isNotEmpty) {
      final last = lines.removeLast();
      lines.add(MapEntry(last.key, '${last.value}\n$line'.trim()));
    }
  }
  if (matched > 0) return _ParsedDialogue(lines);

  lines = <MapEntry<String, String>>[];
  matched = 0;
  for (final line in rawLines) {
    final m = _bareLineRe.firstMatch(line);
    final body = m?.group(2)?.trim() ?? '';
    if (m != null && !body.startsWith('//')) {
      lines.add(MapEntry(m.group(1)!.trim(), body));
      matched++;
    } else if (lines.isNotEmpty) {
      final last = lines.removeLast();
      lines.add(MapEntry(last.key, '${last.value}\n$line'.trim()));
    }
  }
  final counts = <String, int>{};
  for (final e in lines) {
    counts[e.key] = (counts[e.key] ?? 0) + 1;
  }
  final multiTurn = counts.values.any((c) => c >= 2) || matched >= 4;
  if (counts.length >= 2 && multiTurn && matched * 5 >= rawLines.length * 3) {
    return _ParsedDialogue(lines);
  }
  return null;
}

/// @멘션 부분(배지)의 흰 글자만 그려주는 컨트롤러 — 배지의 색 배경 자체는
/// [_MentionHighlightPainter]가 실제 글자 상자(getBoxesForSelection) 기준으로
/// 따로 그린다. TextStyle.background로 직접 칠하면 굵기가 다른 런(run)끼리
/// 글자 상자 높이가 미묘하게 달라 배경이 삐뚤빼뚤해지므로 이 방식을 쓴다.
class _MentionStyledController extends TextEditingController {
  _MentionStyledController({
    required this.mentionsOf,
    required this.colorOf,
  });

  final List<_MentionHit> Function(String text) mentionsOf;
  final Color Function(String name) colorOf;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final full = text;
    final hits = mentionsOf(full);
    if (hits.isEmpty) return TextSpan(style: style, text: full);

    final spans = <TextSpan>[];
    var idx = 0;
    Color? segColor; // 현재 화자에 종속된 본문 색
    for (final h in hits) {
      if (h.start > idx) {
        spans.add(TextSpan(
          text: full.substring(idx, h.start),
          style: style?.copyWith(color: segColor),
        ));
      }
      final c = colorOf(h.name);
      spans.add(TextSpan(
        text: full.substring(h.start, h.end),
        style: style?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ));
      segColor = Color.lerp(c, Colors.black, 0.2);
      idx = h.end;
    }
    if (idx < full.length) {
      spans.add(TextSpan(
        text: full.substring(idx),
        style: style?.copyWith(color: segColor),
      ));
    }
    return TextSpan(style: style, children: spans);
  }
}

/// @멘션 배지의 둥근 색 배경을 텍스트 필드 뒤에 그리는 페인터.
///
/// TextField와 완전히 동일한 style·strutStyle·폭으로 다시 레이아웃한 뒤
/// [TextPainter.getBoxesForSelection]으로 얻은 실제 글자 상자를 그대로
/// 사용한다 — Flutter의 텍스트 선택(드래그 하이라이트) 배경과 같은 방식이라
/// 줄바꿈·굵기와 무관하게 항상 매끈하고 높이가 일정하다.
class _MentionHighlightPainter extends CustomPainter {
  _MentionHighlightPainter({
    required this.text,
    required this.textStyle,
    required this.strutStyle,
    required this.hits,
    required this.colorOf,
    required this.scroll,
  }) : super(repaint: scroll);

  final String text;
  final TextStyle textStyle;
  final StrutStyle strutStyle;
  final List<_MentionHit> hits;
  final Color Function(String name) colorOf;
  // TextField의 내부 스크롤 위치. 텍스트가 위로 스크롤된 만큼 하이라이트도
  // 위로 옮겨 그린다(= 캔버스를 -offset만큼 이동). Listenable로 넘겨
  // 스크롤 시 자동 repaint 되게 한다.
  final ScrollController scroll;

  static const _radius = Radius.circular(6);
  static const _hPad = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (hits.isEmpty) return;
    // 스크롤로 화면 밖으로 나간 배지가 패딩 영역을 침범하지 않도록 클립한다.
    canvas.clipRect(Offset.zero & size);
    final scrollOffset = scroll.hasClients ? scroll.offset : 0.0;
    canvas.translate(0, -scrollOffset);
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
      strutStyle: strutStyle,
    )..layout(maxWidth: size.width);
    // getBoxesForSelection의 top/bottom을 격자 스냅·박스 중심 등으로 어림잡던
    // 이전 방식은 strut 계산과 미세하게 어긋나 글자가 계속 하이라이트 위쪽에
    // 붙어 보였다. computeLineMetrics()는 실제로 렌더링될 줄의 baseline·
    // ascent·descent를 그대로 알려주므로(런별 굵기 차이도 이미 한 줄 기준으로
    // 반영됨) 이걸 그대로 상자 경계로 쓰면 항상 실제 글자와 일치한다.
    final lines = painter.computeLineMetrics();
    if (lines.isEmpty) return;
    for (final hit in hits) {
      final paint = Paint()..color = colorOf(hit.name);
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: hit.start, extentOffset: hit.end),
      );
      if (boxes.isEmpty) continue;
      // "@" + 이름처럼 스크립트가 섞이면 Skia가 런 경계에서 박스를 여러 개로
      // 쪼개 돌려준다. 각각 따로 둥글리면 이어붙는 자리에서 모서리끼리 만나
      // 가운데가 파인 것처럼 보이므로, 같은 줄의 박스는 하나로 합쳐 통짜
      // 사각형 하나만 그린다.
      final byLine = <int, List<double>>{}; // lineIndex -> [left, right]
      for (final box in boxes) {
        final centerY = (box.top + box.bottom) / 2;
        var lineIndex = lines.length - 1;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (centerY <= line.baseline + line.descent) {
            lineIndex = i;
            break;
          }
        }
        final span = byLine[lineIndex];
        if (span == null) {
          byLine[lineIndex] = [box.left, box.right];
        } else {
          if (box.left < span[0]) span[0] = box.left;
          if (box.right > span[1]) span[1] = box.right;
        }
      }
      byLine.forEach((lineIndex, span) {
        final line = lines[lineIndex];
        final top = line.baseline - line.ascent;
        final bottom = line.baseline + line.descent;
        final rect = Rect.fromLTRB(span[0] - _hPad, top, span[1] + _hPad, bottom);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, _radius), paint);
      });
    }
  }

  @override
  bool shouldRepaint(covariant _MentionHighlightPainter oldDelegate) {
    if (oldDelegate.text != text || oldDelegate.hits.length != hits.length) {
      return true;
    }
    for (var i = 0; i < hits.length; i++) {
      final a = oldDelegate.hits[i];
      final b = hits[i];
      if (a.start != b.start || a.end != b.end || a.name != b.name) {
        return true;
      }
    }
    return false;
  }
}

/// 텍스트 일기 입력 — 하나의 룰:
///
/// 1. 그냥 쓰면 전체가 나의 글(자동 확정).
/// 2. 본문에서 @를 치면 커서 위치에 후보 팝업 — '나', 이 글에서 만든 배지,
///    그리고 기존 지식그래프의 화자·출처 노드가 나온다. ↑↓로 후보를 고르고
///    Enter로 확정한다.
/// 3. 매칭이 없으면 새 이름을 마저 쓰고 Enter(또는 "새 화자" 탭) → 생성과
///    동시에 본문에 적용.
/// 4. @배지부터 다음 @배지 전까지가 그 화자의 발화 — 배지·본문이 화자별
///    색으로 칠해져 종속 관계가 즉시 보인다.
///
/// 일기·외부 출처·다중 화자를 같은 룰로 처리하므로 업프론트 모드 선택이 없다.
class PrecisionTextLabelingPanel extends StatefulWidget {
  const PrecisionTextLabelingPanel({
    super.key,
    required this.onSubmit,
    this.initialText = '',
    this.busy = false,
    this.onDirtyChanged,
  });

  final Future<void> Function(
    String paragraphText, {
    String? attributionKind,
    String? attributionName,
  }) onSubmit;
  final String initialText;
  final bool busy;

  /// 저장 안 된 텍스트가 있을 때 true — 화면 이탈 확인용.
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<PrecisionTextLabelingPanel> createState() =>
      _PrecisionTextLabelingPanelState();
}

class _PrecisionTextLabelingPanelState
    extends State<PrecisionTextLabelingPanel> {
  late final _MentionStyledController _composeCtrl;
  final _composeFocus = FocusNode();
  // TextField가 내부적으로 스크롤될 때 하이라이트 페인터도 같은 오프셋만큼
  // 옮겨 그리도록 스크롤 위치를 공유한다 — 없으면 하이라이트가 화면에 고정돼
  // 텍스트만 스크롤되고 배지 배경이 어긋난다.
  final _composeScroll = ScrollController();
  final _popupLink = LayerLink();
  final _popupController = OverlayPortalController();
  static const _composeContentPadding =
      EdgeInsets.symmetric(horizontal: 12, vertical: 12);
  static const _popupWidth = 240.0;

  bool _lastDirty = false;

  /// 이 글에서 실제 배지로 인정되는 이름들(등장 순서 = 색 순서). '나'는 항상 첫째.
  final List<String> _badges = ['나'];

  /// 지식그래프에서 가져온 화자·출처 노드 (팝업 후보).
  List<_SpeakerOption> _graphSpeakers = const [];

  // ── @팝업 상태 (텍스트/커서가 바뀔 때만 갱신, 키 입력으로 커서만 이동) ──────
  ({int at, String partial})? _mentionCtx;
  List<_SpeakerOption> _popupOptions = const [];
  bool _popupCanCreate = false;

  /// 팝업에서 ↑↓로 고른 위치 (options 다음 한 칸은 "새 화자 만들기").
  int _optionCursor = 0;

  Color _colorFor(String name) {
    if (name == '나') return _selfColor;
    final i = _badges.indexOf(name);
    final idx = i <= 0 ? 0 : i - 1; // '나' 제외한 순번
    return _speakerPalette[idx % _speakerPalette.length];
  }

  void _ensureBadge(String name) {
    if (name.trim().isEmpty) return;
    if (!_badges.contains(name)) _badges.add(name);
  }

  void _onComposeChanged() {
    final dirty = _composeCtrl.text.trim().isNotEmpty;
    if (dirty != _lastDirty) {
      _lastDirty = dirty;
      widget.onDirtyChanged?.call(dirty);
    }
    // "[이름]: …" 형식 붙여넣기 → 화자를 배지로 자동 등록.
    final legacy = _parseDialogueLines(_composeCtrl.text);
    if (legacy != null) {
      for (final name in legacy.speakers) {
        _ensureBadge(name);
      }
    }

    final prevPartial = _mentionCtx?.partial;
    _mentionCtx = _computeMentionContext();
    _popupOptions = _mentionCtx == null
        ? const <_SpeakerOption>[]
        : _computeMentionOptions(_mentionCtx!.partial);
    _popupCanCreate = _mentionCtx != null &&
        _mentionCtx!.partial.isNotEmpty &&
        !_popupOptions.any(
          (o) => o.name.toLowerCase() == _mentionCtx!.partial.toLowerCase(),
        );
    final showPopup =
        _mentionCtx != null && (_popupOptions.isNotEmpty || _popupCanCreate);
    if (_mentionCtx?.partial != prevPartial) {
      _optionCursor = 0;
    }
    if (showPopup) {
      _popupController.show();
    } else {
      _popupController.hide();
    }

    // 팝업·하이라이트·미리보기가 커서 위치에 반응해야 하므로 매 변경 리빌드.
    if (mounted) setState(() {});
  }

  Future<void> _loadGraphSpeakers() async {
    try {
      final graph = await apiClient.getGraph();
      final nodes = graph['nodes'] as List<dynamic>? ?? [];
      final seen = <String>{};
      final out = <_SpeakerOption>[];
      for (final raw in nodes) {
        if (raw is! Map) continue;
        final type = raw['type']?.toString();
        if (!isStatementHeadType(type)) continue;
        final name = raw['name']?.toString().trim() ?? '';
        if (name.isEmpty || name == '나' || !seen.add(name)) continue;
        out.add(_SpeakerOption(name, isSource: !isSpeakerLikeType(type)));
      }
      out.sort((a, b) => a.name.compareTo(b.name));
      if (mounted) setState(() => _graphSpeakers = out);
    } catch (_) {
      // 그래프가 아직 없거나 실패해도 입력은 정상 동작해야 한다.
    }
  }

  @override
  void initState() {
    super.initState();
    _composeCtrl = _MentionStyledController(
      mentionsOf: _findMentions,
      colorOf: _colorFor,
    );
    _composeCtrl.text = widget.initialText;
    _composeCtrl.addListener(_onComposeChanged);
    unawaited(_loadGraphSpeakers());
  }

  @override
  void dispose() {
    _composeCtrl.removeListener(_onComposeChanged);
    _composeCtrl.dispose();
    _composeFocus.dispose();
    _composeScroll.dispose();
    super.dispose();
  }

  // ── @멘션 감지·삽입·분리 ─────────────────────────────────────────────────

  /// 매칭 대상 이름: 세션 배지 + 그래프 화자 (긴 이름 우선).
  List<String> _matchableNames() {
    final names = <String>{..._badges, ..._graphSpeakers.map((o) => o.name)};
    final list = names.toList()..sort((a, b) => b.length.compareTo(a.length));
    return list;
  }

  List<_MentionHit> _findMentions(String text) {
    final names = _matchableNames();
    if (names.isEmpty || !text.contains('@')) return const <_MentionHit>[];
    final re = RegExp('@(${names.map(RegExp.escape).join('|')})');
    final hits = <_MentionHit>[];
    for (final m in re.allMatches(text)) {
      // 이름 뒤에 글자가 바로 이어지면 다른 단어의 일부 → 제외.
      if (m.end < text.length &&
          RegExp(r'[A-Za-z0-9가-힣]').hasMatch(text[m.end])) {
        continue;
      }
      // '@' 앞은 시작 또는 공백이어야 멘션.
      if (m.start > 0 && !RegExp(r'\s').hasMatch(text[m.start - 1])) continue;
      hits.add(_MentionHit(m.start, m.end, m.group(1)!));
    }
    return hits;
  }

  /// 커서가 "@부분입력" 위에 있으면 (@ 위치, 입력 중 텍스트) 반환.
  ({int at, String partial})? _computeMentionContext() {
    final sel = _composeCtrl.selection;
    final text = _composeCtrl.text;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final upto = text.substring(0, sel.start);
    final at = upto.lastIndexOf('@');
    if (at < 0) return null;
    if (at > 0 && !RegExp(r'\s').hasMatch(upto[at - 1])) return null;
    final partial = upto.substring(at + 1);
    if (partial.length > 20 || partial.contains(RegExp(r'\s'))) return null;
    return (at: at, partial: partial);
  }

  /// 팝업 후보: '나' → 세션 배지 → 그래프 화자·출처, partial로 필터.
  List<_SpeakerOption> _computeMentionOptions(String partial) {
    final q = partial.toLowerCase();
    final seen = <String>{};
    final out = <_SpeakerOption>[];
    for (final name in _badges) {
      if (name.toLowerCase().startsWith(q) && seen.add(name)) {
        out.add(_SpeakerOption(name));
      }
    }
    for (final opt in _graphSpeakers) {
      if (opt.name.toLowerCase().startsWith(q) && seen.add(opt.name)) {
        out.add(opt);
      }
    }
    return out;
  }

  /// 생성과 동시에 적용: 배지 등록 + 본문 삽입 한 번에.
  void _applyMention(String name) {
    final ctx = _mentionCtx;
    if (ctx == null) return;
    _ensureBadge(name);
    final text = _composeCtrl.text;
    final sel = _composeCtrl.selection;
    final replaced =
        '${text.substring(0, ctx.at)}@$name ${text.substring(sel.start)}';
    _composeCtrl.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: ctx.at + name.length + 2),
    );
    _composeFocus.requestFocus();
  }

  /// ↑↓로 후보 이동, Enter로 현재 고른 후보(또는 새 화자)를 확정.
  KeyEventResult _onComposeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctx = _mentionCtx;
    if (ctx == null) return KeyEventResult.ignored;
    final total = _popupOptions.length + (_popupCanCreate ? 1 : 0);
    if (total == 0) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _optionCursor = (_optionCursor + 1) % total);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _optionCursor = (_optionCursor - 1 + total) % total);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      final idx = _optionCursor.clamp(0, total - 1);
      if (idx < _popupOptions.length) {
        _applyMention(_popupOptions[idx].name);
      } else {
        _applyMention(ctx.partial);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// @멘션 위치 기준 (화자, 발화) 분리. 첫 멘션 앞 내용은 '나'(글쓴이) 소유.
  List<MapEntry<String, String>> _splitByMentions(
    String text,
    List<_MentionHit> hits,
  ) {
    // 멘션 뒤 구분자(":"·",")만 떼고, 가로 공백은 접되 사용자가 넣은 줄바꿈은
    // 보존한다 — 목록·문단 구조가 그대로 화자별 스크립트에 남게 하기 위함.
    String clean(String s) => s
        .replaceAll(RegExp(r'^[\s:,·]+'), '')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r' *\n *'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    final segs = <MapEntry<String, String>>[];
    final pre = clean(text.substring(0, hits.first.start));
    if (pre.isNotEmpty) segs.add(MapEntry('나', pre));
    for (var i = 0; i < hits.length; i++) {
      final end = i + 1 < hits.length ? hits[i + 1].start : text.length;
      final body = clean(text.substring(hits[i].end, end));
      if (body.isNotEmpty) segs.add(MapEntry(hits[i].name, body));
    }
    return segs;
  }

  static String _toLabeledLines(List<MapEntry<String, String>> segs) {
    return segs.map((e) => '[${e.key}]: ${e.value}').join('\n');
  }

  // ── 제출 ────────────────────────────────────────────────────────────────

  Future<void> _showTooLongDialog(int length) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('입력이 너무 깁니다'),
        content: Text(
          '현재 $length자 / 최대 $kMaxJournalTextChars자입니다.\n'
          '너무 긴 텍스트는 추출 품질이 떨어질 수 있어요. '
          '내용을 나눠서 여러 번 입력해 주세요.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final raw = _composeCtrl.text;
    final text = raw.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('텍스트를 입력해 주세요')),
      );
      return;
    }
    if (text.length > kMaxJournalTextChars) {
      await _showTooLongDialog(text.length);
      return;
    }

    final hits = _findMentions(raw);
    if (hits.isNotEmpty) {
      // @멘션 규칙: 배지부터 다음 배지 전까지가 그 화자의 발화.
      await widget.onSubmit(_toLabeledLines(_splitByMentions(raw, hits)));
      return;
    }
    // "[이름]: …" 형식 붙여넣기 → 표준형으로 정규화해 전달.
    final legacy = _parseDialogueLines(text);
    if (legacy != null) {
      await widget.onSubmit(_toLabeledLines(legacy.lines));
      return;
    }
    // 화자가 나 혼자여도 다중 화자와 같은 라벨 형식으로 '나'를 명시 등록해
    // 화자 등록 여부와 무관하게 항상 같은 경로를 타도록 통일한다.
    await widget.onSubmit(_toLabeledLines([MapEntry('나', text)]));
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  Offset _caretMenuOffset({
    required double fieldWidth,
    required TextStyle textStyle,
  }) {
    final selection = _composeCtrl.selection;
    final caretIndex = selection.isValid
        ? selection.extentOffset.clamp(0, _composeCtrl.text.length)
        : _composeCtrl.text.length;
    final beforeCaret = _composeCtrl.text.substring(0, caretIndex);
    final painter = TextPainter(
      text: TextSpan(text: beforeCaret, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: fieldWidth - _composeContentPadding.horizontal);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: beforeCaret.length),
      Rect.zero,
    );
    return Offset(
      _composeContentPadding.left + caret.dx,
      _composeContentPadding.top + caret.dy + painter.preferredLineHeight + 6,
    );
  }

  Widget _popupRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    String? trailing,
    required bool selected,
    required VoidCallback onTap,
    required VoidCallback onHover,
  }) {
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: iconColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildComposeField(BuildContext context) {
    final theme = Theme.of(context);
    // height·leadingDistribution을 명시해 줄 상자를 고정 — 화자 배지(bold)와
    // 본문(regular)의 폰트 메트릭 차이로 하이라이트 배경 높이가 들쭉날쭉해지는
    // 문제 방지. StrutStyle.forceStrutHeight로 실제 렌더링에도 강제 적용.
    final textStyle =
        (theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16)).copyWith(
      height: 1.5,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final strutStyle = StrutStyle(
      fontSize: textStyle.fontSize,
      height: textStyle.height,
      forceStrutHeight: true,
    );
    final ctx = _mentionCtx;

    return LayoutBuilder(
      builder: (context, constraints) {
        final popupOffset = _caretMenuOffset(
          fieldWidth: constraints.maxWidth,
          textStyle: textStyle,
        );
        final maxLeft = constraints.maxWidth > _popupWidth + 16
            ? constraints.maxWidth - _popupWidth - 8
            : 8.0;
        final left = popupOffset.dx.clamp(8.0, maxLeft).toDouble();

        return CompositedTransformTarget(
          link: _popupLink,
          child: OverlayPortal(
            controller: _popupController,
            overlayChildBuilder: (context) {
              if (ctx == null) return const SizedBox.shrink();
              return CompositedTransformFollower(
                link: _popupLink,
                showWhenUnlinked: false,
                offset: Offset(left, popupOffset.dy),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: _popupWidth,
                    child: Material(
                      elevation: 10,
                      borderRadius: BorderRadius.circular(14),
                      color: theme.colorScheme.surface,
                      shadowColor: Colors.black.withValues(alpha: 0.18),
                      clipBehavior: Clip.antiAlias,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant
                                .withValues(alpha: 0.8),
                          ),
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220),
                          child: ListView(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            shrinkWrap: true,
                            children: [
                              for (var i = 0; i < _popupOptions.length; i++)
                                _popupRow(
                                  icon: _popupOptions[i].name == '나'
                                      ? Icons.person_rounded
                                      : _popupOptions[i].isSource
                                          ? Icons.menu_book_rounded
                                          : Icons.person_outline_rounded,
                                  iconColor:
                                      _badges.contains(_popupOptions[i].name)
                                          ? _colorFor(_popupOptions[i].name)
                                          : theme.colorScheme.primary,
                                  label: _popupOptions[i].name,
                                  trailing:
                                      !_badges.contains(_popupOptions[i].name)
                                          ? '그래프'
                                          : null,
                                  selected: i == _optionCursor,
                                  onTap: () =>
                                      _applyMention(_popupOptions[i].name),
                                  onHover: () =>
                                      setState(() => _optionCursor = i),
                                ),
                              if (_popupCanCreate)
                                _popupRow(
                                  icon: Icons.add_circle_outline_rounded,
                                  iconColor: theme.colorScheme.primary,
                                  label: "'${ctx.partial}' 새 화자 만들기",
                                  trailing: 'Enter',
                                  selected:
                                      _optionCursor == _popupOptions.length,
                                  onTap: () => _applyMention(ctx.partial),
                                  onHover: () => setState(
                                    () => _optionCursor = _popupOptions.length,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: Padding(
                      padding: _composeContentPadding,
                      child: SizedBox.expand(
                        child: CustomPaint(
                          painter: _MentionHighlightPainter(
                            text: _composeCtrl.text,
                            textStyle: textStyle,
                            strutStyle: strutStyle,
                            hits: _findMentions(_composeCtrl.text),
                            colorOf: _colorFor,
                            scroll: _composeScroll,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Focus(
                  onKeyEvent: _onComposeKey,
                  child: TextField(
                    controller: _composeCtrl,
                    focusNode: _composeFocus,
                    scrollController: _composeScroll,
                    style: textStyle,
                    strutStyle: strutStyle,
                    maxLines: 12,
                    minLines: 6,
                    maxLength: kMaxJournalTextChars,
                    maxLengthEnforcement: MaxLengthEnforcement.none,
                    decoration: InputDecoration(
                      hintText: '그냥 쓰면 나의 일기가 돼요.\n'
                          '@를 입력해 화자·출처를 지정할 수 있어요. '
                          '예: @나 내일 회의 몇 시야?  @엄마 10시.',
                      border: const OutlineInputBorder(),
                      contentPadding: _composeContentPadding,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 저장 시 분리 결과 미리보기 — 배지·본문과 같은 색.
  Widget _buildSplitPreview(BuildContext context) {
    final raw = _composeCtrl.text;
    if (raw.trim().isEmpty) return const SizedBox.shrink();

    List<MapEntry<String, String>> segs;
    final hits = _findMentions(raw);
    if (hits.isNotEmpty) {
      segs = _splitByMentions(raw, hits);
    } else {
      final legacy = _parseDialogueLines(raw);
      if (legacy == null) return const SizedBox.shrink();
      segs = legacy.lines;
    }
    if (segs.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final counts = <String, int>{};
    for (final e in segs) {
      counts[e.key] = (counts[e.key] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('분리 미리보기', style: theme.textTheme.labelMedium),
          for (final entry in counts.entries)
            Chip(
              avatar: Icon(
                entry.key == '나'
                    ? Icons.check_circle_rounded
                    : Icons.person_outline_rounded,
                size: 14,
                color: _colorFor(entry.key),
              ),
              label: Text(
                '${entry.key} · ${entry.value}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color.lerp(_colorFor(entry.key), Colors.black, 0.2),
                ),
              ),
              visualDensity: VisualDensity.compact,
              backgroundColor: _colorFor(entry.key).withValues(alpha: 0.1),
              side: BorderSide(
                color: _colorFor(entry.key).withValues(alpha: 0.35),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      tint: AppColors.hubVoice,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildComposeField(context),
          _buildSplitPreview(context),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 14,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '@ 없이 쓰면 전체가 나의 글로 저장돼요 · @화자를 지정하면 '
                  '다음 @화자 전까지가 그 화자의 발화가 돼요',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11.5, color: AppColors.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: widget.busy ? null : _submit,
            icon: widget.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.save_alt_outlined),
            label: Text(widget.busy ? '저장 중…' : '일기 저장'),
          ),
        ],
      ),
    );
  }
}
