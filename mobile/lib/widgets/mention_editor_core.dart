import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey, MaxLengthEnforcement;

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../utils/graph_layout.dart' show isSpeakerLikeType, isStatementHeadType;

// 추출 품질이 급격히 떨어지는 지점 이전으로 캡 (백엔드 JournalTextEntryRequest와 동일).
const kMaxJournalTextChars = 4000;

/// Mentions used to render in one flat link blue, Slack-style, with per-speaker
/// colors reserved for pickers and graph views. That was decided before color
/// carried meaning: now a speaker's hue runs from the composer through the
/// speaker bar to the graph, and painting every mention the same blue broke the
/// thread exactly where the learner is deciding who said what — "@하승목" and
/// "@나" were the same color in the very text that distinguishes them.
///
/// Kept only as the fallback for a mention whose speaker has no color yet.
const kMentionLinkColor = Color(0xFF1264A3);

/// A single space separates words in a name; extra or trailing whitespace does
/// not make a different speaker. `르브론 제임스` is preserved, while `나  ` is
/// normalized to `나`.
String normalizeMentionName(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

String _mentionNameKey(String value) => normalizeMentionName(value).toLowerCase();

/// '나' 배지 고정 색 — 화자 확인 칩의 확정(초록) 톤과 맞춘다.
const kSelfMentionColor = Color(0xFF2E7D32);

/// 그 외 화자 배지 색 팔레트 — 등장 순서대로 배정.
const kSpeakerPalette = <Color>[
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
class MentionHit {
  const MentionHit(this.start, this.end, this.name);

  final int start; // '@' 위치
  final int end; // 이름 끝 (exclusive)
  final String name;
}

/// @ 팝업 후보: 세션에서 만든 배지 + 지식그래프의 화자·출처 노드.
class SpeakerOption {
  const SpeakerOption(this.name, {this.isSource = false});

  final String name;
  final bool isSource;
}

/// "[이름]: …" 형식 붙여넣기 지원 — 백엔드 pre_slice와 같은 규칙.
class ParsedDialogue {
  const ParsedDialogue(this.lines);

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

/// "@이름: 발화" — the shape people actually paste back into journal mode after
/// composing elsewhere. Without this, the pasted @names were never registered as
/// badges, [findMentions] matched nothing, and the whole multi-speaker text was
/// silently attributed to "나".
final _atLineRe =
    RegExp(r'^\s*@([A-Za-z가-힣][A-Za-z0-9가-힣 ._\-]{0,19}?)\s*[:：]\s*(.+)$');

/// Speakers named by "@이름:" lines, in order of first appearance.
List<String> atMentionLineSpeakers(String text) {
  if (!text.contains('@')) return const <String>[];
  final seen = <String>{};
  final out = <String>[];
  for (final line in text.split('\n')) {
    final m = _atLineRe.firstMatch(line);
    if (m == null) continue;
    final name = normalizeMentionName(m.group(1)!);
    if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
    out.add(name);
  }
  return out;
}

/// "@무언가" tokens that are not (yet) registered speakers. Used to warn before
/// a save silently drops them into the previous speaker's text.
List<String> unregisteredMentionTokens(String text, List<String> knownNames) {
  if (!text.contains('@')) return const <String>[];
  final known = knownNames.map((n) => n.toLowerCase()).toSet();
  final seen = <String>{};
  final out = <String>[];
  for (final m in RegExp(r'(?:^|\s)@([^\s:：,.!?]{1,20})').allMatches(text)) {
    final name = normalizeMentionName(m.group(1)!);
    if (name.isEmpty) continue;
    final key = name.toLowerCase();
    if (known.contains(key) || !seen.add(key)) continue;
    out.add(name);
  }
  return out;
}

/// 화자는 오직 명시적 표기로만 갈린다: `@이름` 멘션, 그리고 이 함수가 보는
/// `[이름]: …` 라벨. 콜론이 붙었다는 이유만으로 줄을 화자로 승격시키지 않는다.
///
/// 예전에는 대괄호가 없을 때 맨살 "이름: 내용" 줄을 휴리스틱으로 대화로
/// 인정했다. 명분은 "카톡·회의록 붙여넣기 자동 분리"였는데, 실제 카톡
/// 내보내기 두 포맷 중 어느 것도 그 정규식에 걸리지 않았다:
///   Android — `2026년 8월 11일 오후 3:20, 홍길동 : 안녕`  (숫자로 시작)
///   PC/iOS  — `[홍길동] [오후 3:20] 안녕`                  (`]` 뒤가 `:`가 아님)
/// 잡으려던 것은 하나도 못 잡고, 대신 콜론이 흔한 문서를 잘랐다 — 24줄짜리
/// 금융 용어 정리가 화자 23명("약정액", "설정액", "ROE", "수탁은행" …)짜리
/// 대화가 되어 개념마다 인물 노드가 그래프에 박혔다. 턴 수 조건을 걸어 완화해
/// 봐도 `질문:/답변:`, `장점:/단점:` 같은 메모는 여전히 통과한다. 신호 자체가
/// 화자를 뜻하지 않으므로 임계값으로는 고칠 수 없어 규칙을 걷어냈다.
///
/// 스크린샷에서 온 대화는 OCR이 화자를 `@이름:` 형태로 붙여 오고, 그러면 이
/// 함수가 아니라 [findMentions] 경로를 탄다.
ParsedDialogue? parseDialogueLines(String text) {
  final rawLines =
      text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (rawLines.isEmpty) return null;

  final lines = <MapEntry<String, String>>[];
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
  return matched > 0 ? ParsedDialogue(lines) : null;
}

/// [badges] 등장 순서 기준 색 — '나'는 [kSelfMentionColor], 나머지는 [kSpeakerPalette].
///
/// 팔레트 번호는 '나'를 **건너뛴 순번**이다. 예전 구현은 `indexOf`에서 1을 빼는
/// 방식이라 목록에 '나'가 없으면(저장된 항목의 화자 목록, OCR 인식 결과처럼)
/// 첫째와 둘째 화자가 같은 색을 받았다. 색이 신원을 뜻하는 이상 두 사람이 같은
/// 색인 것은 그냥 틀린 것이므로, '나'의 존재 여부와 무관하게 세도록 바꿨다.
/// '나'가 맨 앞에 있는 기존 호출은 결과가 이전과 완전히 동일하다.
Color colorForSpeaker(String name, List<String> badges) {
  if (name == '나') return kSelfMentionColor;
  var idx = 0;
  for (final badge in badges) {
    if (badge == '나') continue;
    if (badge == name) break;
    idx++;
  }
  return kSpeakerPalette[idx % kSpeakerPalette.length];
}

/// 화자 이름을 색 배정 순서로 정렬 — '나'가 있으면 항상 맨 앞, 나머지는 첫 등장 순.
///
/// 작성창의 배지 목록과 저장된 항목의 세그먼트 목록을 같은 규칙으로 통과시켜야
/// 한 화자가 저장 전후로 같은 색을 유지한다.
List<String> speakerColorOrder(Iterable<String> appearanceOrder) {
  final others = <String>[];
  var hasSelf = false;
  for (final raw in appearanceOrder) {
    final name = normalizeMentionName(raw);
    if (name.isEmpty) continue;
    if (name == '나') {
      hasSelf = true;
      continue;
    }
    if (!others.contains(name)) others.add(name);
  }
  return [if (hasSelf) '나', ...others];
}

/// 매칭 대상 이름 목록으로 본문의 @멘션을 찾는다 (긴 이름 우선 매칭은 호출측 정렬).
List<MentionHit> findMentions(String text, List<String> matchableNames) {
  if (matchableNames.isEmpty || !text.contains('@')) {
    return const <MentionHit>[];
  }
  final re = RegExp('@(${matchableNames.map(RegExp.escape).join('|')})');
  final hits = <MentionHit>[];
  for (final m in re.allMatches(text)) {
    // 이름 뒤에 글자가 바로 이어지면 다른 단어의 일부 → 제외.
    if (m.end < text.length &&
        RegExp(r'[A-Za-z0-9가-힣]').hasMatch(text[m.end])) {
      continue;
    }
    // '@' 앞은 시작 또는 공백이어야 멘션.
    if (m.start > 0 && !RegExp(r'\s').hasMatch(text[m.start - 1])) continue;
    hits.add(MentionHit(m.start, m.end, m.group(1)!));
  }
  return hits;
}

/// @멘션 위치 기준 (화자, 발화) 분리. 첫 멘션 앞 내용은 '나'(글쓴이) 소유.
List<MapEntry<String, String>> splitByMentions(
  String text,
  List<MentionHit> hits,
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

String toLabeledLines(List<MapEntry<String, String>> segs) {
  return segs.map((e) => '[${e.key}]: ${e.value}').join('\n');
}

/// Per-speaker segments for a mention field's current text.
///
/// The one place the @-mention → per-speaker rule lives. The speaker bar above
/// the composer and the text that actually gets saved both read it, so the bar
/// cannot promise a split the save does not deliver.
List<MapEntry<String, String>> segmentsFromMentionField(
  MentionAutocompleteFieldState field,
) {
  final raw = field.text;
  final text = raw.trim();
  if (text.isEmpty) return const [];
  final hits = findMentions(raw, field.matchableNames());
  if (hits.isNotEmpty) return splitByMentions(raw, hits);
  final legacy = parseDialogueLines(text);
  if (legacy != null) return legacy.lines;
  return [MapEntry('나', text)];
}

/// Speaker-labeled lines ("[name]: text") built from a mention field's current
/// text — shared by every composer that saves journal text.
String labeledTextFromMentionField(MentionAutocompleteFieldState field) {
  final segments = segmentsFromMentionField(field);
  return segments.isEmpty ? '' : toLabeledLines(segments);
}

/// (화자, 턴 수) — 등장 순서. 화자 바가 "제니 · 8" 을 그리는 근거.
///
/// 턴 수는 장식이 아니라 안전장치다. 잘못된 분리는 거의 항상 "화자 여럿이 각각
/// 1턴"으로 나타난다 — 용어사전이 23명짜리 대화로 잘렸을 때가 정확히 그 모양이다.
List<MapEntry<String, int>> speakerTurns(
  List<MapEntry<String, String>> segments,
) {
  final counts = <String, int>{};
  final order = <String>[];
  for (final segment in segments) {
    final name = normalizeMentionName(segment.key);
    if (name.isEmpty) continue;
    if (!counts.containsKey(name)) order.add(name);
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return [for (final name in order) MapEntry(name, counts[name]!)];
}

/// 본문의 "@옛이름" 멘션을 전부 "@새이름"으로 바꾼다.
///
/// 뒤에서부터 치환한다 — 앞에서 하면 길이가 달라지는 순간 뒤쪽 히트의 위치가
/// 전부 어긋난다.
String renameMentionInText(String text, String oldName, String newName) {
  final hits = findMentions(text, [oldName]);
  if (hits.isEmpty) return text;
  final buffer = StringBuffer();
  var idx = 0;
  for (final hit in hits) {
    buffer
      ..write(text.substring(idx, hit.start))
      ..write('@$newName');
    idx = hit.end;
  }
  buffer.write(text.substring(idx));
  return buffer.toString();
}

/// "@이름" 표시를 걷어내 그 발화를 앞 화자에게 합친다 (칩의 '화자 아님').
///
/// 멘션 바로 뒤의 구분자(":"·",")와 이어지는 공백까지 함께 지운다. 그것이 남으면
/// 합쳐진 문장이 콜론으로 시작한다.
String dissolveMentionInText(String text, String name) {
  final hits = findMentions(text, [name]);
  if (hits.isEmpty) return text;
  final buffer = StringBuffer();
  var idx = 0;
  for (final hit in hits) {
    buffer.write(text.substring(idx, hit.start));
    var after = hit.end;
    final trailing = RegExp(r'^[ \t]*[:：,·]?[ \t]*').firstMatch(
      text.substring(after),
    );
    if (trailing != null) after += trailing.end;
    idx = after;
  }
  buffer.write(text.substring(idx));
  return buffer.toString();
}

/// Colors the "@배지" runs of the text.
///
/// Color is the ONLY thing this may change. Anything that alters a glyph's
/// advance — weight, letter spacing, font — desynchronizes the canvas text from
/// the hidden DOM input that resolves taps into caret positions, and taps then
/// land on the wrong character. See the note in [buildTextSpan].
class MentionStyledController extends TextEditingController {
  MentionStyledController({
    required this.mentionsOf,
    required this.colorOf,
  });

  final List<MentionHit> Function(String text) mentionsOf;
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
      // COLOR ONLY. Nothing here may change a glyph's advance width.
      //
      // Flutter syncs a single flat style to the hidden DOM input that the
      // browser uses to resolve a tap into a text offset — fontFamily, fontSize,
      // fontWeight, letterSpacing, wordSpacing, lineHeight, all taken from the
      // field's ONE base style (EditableText._getTextInputStyle). Per-run
      // styling cannot be represented there. Making mentions bolder and tighter
      // therefore laid them out narrower on the canvas than in the DOM, so every
      // character after a mention sat at a different x in the two — and taps
      // landed on the wrong character. Every line of a pasted dialogue starts
      // with "@이름:", which is why placing the caret was worst near the left.
      spans.add(TextSpan(
        text: full.substring(h.start, h.end),
        style: style?.copyWith(color: colorOf(h.name)),
      ));
      segColor = null;
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

/// Stops `showOnScreen` from travelling out of its subtree.
///
/// This is what makes tap-to-place-caret work in a scrollable composer.
/// `EditableText` calls `_scheduleShowCaretOnScreen()` whenever the field gains
/// focus (editable_text.dart, `_handleFocusChanged`) and whenever the keyboard
/// inset grows — and that ends in
/// `renderEditable.showOnScreen(rect: caretRect)`, which [RenderObject.showOnScreen]
/// forwards to `parent?.showOnScreen(...)` all the way up until some scrollable
/// obeys it.
///
/// On web the tap's new selection arrives from the hidden DOM input a frame
/// AFTER focus is granted, so the post-frame reveal still sees the OLD caret and
/// scrolls back to it — the tap looks ignored. Moving the scrolling somewhere
/// else does not help: the request simply follows it to whichever ancestor
/// scrolls. Cutting the chain here is the only thing that does.
///
/// Deliberate caret-following (typing at the end of the draft) is done by the
/// composer instead, where it can be limited to the cases the user wants.
class BlockShowOnScreen extends SingleChildRenderObjectWidget {
  const BlockShowOnScreen({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBlockShowOnScreen();
}

class _RenderBlockShowOnScreen extends RenderProxyBox {
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    // Swallow it. Do not call super — that is the propagation being stopped.
  }
}

/// Bakes the platform text scale into [base] so the size the canvas paints and
/// the size the tap-measuring DOM input is given are the same number.
///
/// `EditableText` paints with `MediaQuery.textScalerOf(context)` but hands the
/// hidden DOM input `widget.style.fontSize` untouched (`_style` in
/// editable_text.dart is the raw widget style). At any scale other than 1.0 the
/// DOM therefore measures text SMALLER than the canvas draws it, so the same
/// touch distance covers more characters and the caret lands to the right of
/// where the user pressed — further right the longer the line.
///
/// Pair this with `textScaler: TextScaler.noScaling` on the field, or the scale
/// gets applied twice. Accessibility scaling is preserved either way: the text
/// really is bigger, it is just already bigger in the number both sides use.
TextStyle textScaleBakedIn(BuildContext context, TextStyle base) {
  final scaler = MediaQuery.textScalerOf(context);
  final size = base.fontSize ?? 14.0;
  return base.copyWith(fontSize: scaler.scale(size));
}

/// Stops descendants from applying the platform text scale a second time.
///
/// Use around a field whose style already went through [textScaleBakedIn].
class NoTextScaling extends StatelessWidget {
  const NoTextScaling({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: child,
      );
}

/// A multi-line text field the caret cannot drag around.
///
/// Wrap ANY multi-line input in this and give the field `maxLines: null`. Two
/// things have to be true together, and either one alone leaves the bug:
///
///  * `maxLines: null` — a capped maxLines gives the field its own scroll
///    viewport, and `_scheduleShowCaretOnScreen` scrolls that viewport straight
///    to the caret. Growing freely inside this box removes that viewport.
///  * [BlockShowOnScreen] — the same routine then asks its ANCESTORS to reveal
///    the caret instead, which would scroll this box exactly as before.
///
/// The box still looks and behaves like a normal composer: it grows to
/// [maxHeight] and scrolls after that. It just does not move on its own.
///
/// Pass [controller] when the caller wants to follow the caret deliberately
/// (e.g. while typing at the very end of the draft).
class CaretStableField extends StatelessWidget {
  const CaretStableField({
    super.key,
    required this.maxHeight,
    required this.child,
    this.controller,
  });

  final double maxHeight;
  final ScrollController? controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        controller: controller,
        child: BlockShowOnScreen(child: child),
      ),
    );
  }
}

/// @멘션 자동완성 텍스트 필드 — 컴포즈·채팅 바가 각자 스타일링할 수 있도록
/// min/maxLines·decoration·focusNode 등을 파라미터화한다.
///
/// 하나의 룰:
/// 1. 그냥 쓰면 전체가 나의 글.
/// 2. @를 치면 커서에 후보 팝업 — '나', 세션 배지, 지식그래프 화자·출처.
/// 3. 매칭이 없으면 새 이름 + Enter(또는 "새 화자" 탭) → 생성과 동시에 적용.
/// 4. @배지부터 다음 @배지 전까지가 그 화자의 발화.
class MentionAutocompleteField extends StatefulWidget {
  const MentionAutocompleteField({
    super.key,
    this.minLines = 1,
    this.maxLines = 1,
    this.decoration,
    this.focusNode,
    this.onSubmitted,
    this.onDirtyChanged,
    this.onChanged,
    this.initialText = '',
    this.enabled = true,
    this.showCounter = true,
    this.openUpward = false,
  });

  final int minLines;

  /// Null grows without a cap — used by the full-screen journal editor.
  final int? maxLines;
  final InputDecoration? decoration;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<bool>? onDirtyChanged;

  /// Raw text change callback (e.g. live character counter).
  final ValueChanged<String>? onChanged;
  final String initialText;
  final bool enabled;
  final bool showCounter;

  /// Open the @-mention popup ABOVE the caret instead of below. Needed when the
  /// field is docked at the bottom of the screen (e.g. the journal compose bar),
  /// where a downward popup would render off-screen and be unreachable.
  final bool openUpward;

  @override
  State<MentionAutocompleteField> createState() =>
      MentionAutocompleteFieldState();
}

class MentionAutocompleteFieldState extends State<MentionAutocompleteField> {
  late final MentionStyledController _controller;
  late final FocusNode _focusNode;
  late final bool _ownsFocusNode;
  // TextField가 내부적으로 스크롤될 때 하이라이트 페인터도 같은 오프셋만큼
  // 옮겨 그리도록 스크롤 위치를 공유한다 — 없으면 하이라이트가 화면에 고정돼
  // 텍스트만 스크롤되고 배지 배경이 어긋난다.
  final _scroll = ScrollController();
  final _popupLink = LayerLink();
  final _popupController = OverlayPortalController();
  static const _contentPadding =
      EdgeInsets.symmetric(horizontal: 12, vertical: 12);
  static const _popupWidth = 240.0;

  bool _lastDirty = false;
  String _lastText = '';

  /// 이 글에서 실제 배지로 인정되는 이름들(등장 순서 = 색 순서). '나'는 항상 첫째.
  final List<String> _badges = ['나'];

  /// 지식그래프에서 가져온 화자·출처 노드 (팝업 후보).
  List<SpeakerOption> _graphSpeakers = const [];

  // ── @팝업 상태 (텍스트/커서가 바뀔 때만 갱신, 키 입력으로 커서만 이동) ──────
  ({int at, String partial})? _mentionCtx;
  // Selecting a popup row writes a completed "@name " token. Its trailing
  // separator must start the message body, not immediately reopen the picker.
  ({int at, String token})? _completedMention;
  List<SpeakerOption> _popupOptions = const [];
  bool _popupCanCreate = false;
  static const _maxVisibleMentionRows = 5;

  /// 팝업에서 ↑↓로 고른 위치 (options 다음 한 칸은 "새 화자 만들기").
  int _optionCursor = 0;

  String get text => _controller.text;

  List<String> get badges => List.unmodifiable(_badges);

  /// Register a speaker without the learner having to pick it from the popup.
  ///
  /// Renaming a speaker from the composer's chip needs this: the rewritten text
  /// carries a name nothing has registered yet, and an unregistered name is not
  /// a mention — the rename would silently collapse that speaker's lines into
  /// the previous one.
  void ensureSpeaker(String name) {
    final normalized = normalizeMentionName(name);
    if (normalized.isEmpty) return;
    _ensureBadge(normalized);
    if (mounted) setState(() {});
  }

  /// 매칭 대상 이름: 세션 배지 + 그래프 화자 (긴 이름 우선).
  List<String> matchableNames() {
    // Graph speakers are suggestions only. A mention becomes active only
    // after the user explicitly picks a row from the suggestion list.
    final list = _badges.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return list;
  }

  List<MentionHit> findCurrentMentions() =>
      findMentions(_controller.text, matchableNames());

  Color colorFor(String name) => colorForSpeaker(name, _badges);

  void _ensureBadge(String name) {
    final normalized = normalizeMentionName(name);
    if (normalized.isEmpty) return;
    if (!_badges.any(
        (badge) => _mentionNameKey(badge) == _mentionNameKey(normalized))) {
      _badges.add(normalized);
    }
  }

  void _onTextChanged() {
    // The controller also notifies on pure caret moves. Rebuilding the TextField
    // in that same frame is what made a tap high up in a long, scrolled entry
    // snap the view back to the old caret instead of placing it where the user
    // tapped — so a selection-only change must stay a no-op unless the mention
    // popup's own state actually changed.
    final text = _controller.text;
    final textChanged = text != _lastText;
    _lastText = text;

    if (textChanged) {
      widget.onChanged?.call(text);
      final dirty = text.trim().isNotEmpty;
      if (dirty != _lastDirty) {
        _lastDirty = dirty;
        widget.onDirtyChanged?.call(dirty);
      }
      // "[이름]: …" / "@이름: …" 붙여넣기 → 화자를 배지로 자동 등록.
      for (final name in atMentionLineSpeakers(text)) {
        _ensureBadge(name);
      }
      final legacy = parseDialogueLines(text);
      if (legacy != null) {
        for (final name in legacy.speakers) {
          _ensureBadge(name);
        }
      }
    }

    final prevCtx = _mentionCtx;
    final prevOptions = _popupOptions;
    final prevCanCreate = _popupCanCreate;
    _mentionCtx = _computeMentionContext();
    if (_mentionCtx != null && _isCompletedMentionContext(_mentionCtx!)) {
      _mentionCtx = null;
    }
    _popupOptions = _mentionCtx == null
        ? const <SpeakerOption>[]
        : _computeMentionOptions(_mentionCtx!.partial);
    _popupCanCreate = _mentionCtx != null &&
        _mentionCtx!.partial.isNotEmpty &&
        ![..._badges, ..._graphSpeakers.map((option) => option.name)].any(
          (name) => _mentionNameKey(name) == _mentionNameKey(_mentionCtx!.partial),
        );
    final showPopup =
        _mentionCtx != null && (_popupOptions.isNotEmpty || _popupCanCreate);
    if (_mentionCtx?.partial != prevCtx?.partial) {
      _optionCursor = 0;
    }
    if (showPopup) {
      _popupController.show();
    } else {
      _popupController.hide();
    }

    final popupChanged = _mentionCtx?.at != prevCtx?.at ||
        _mentionCtx?.partial != prevCtx?.partial ||
        _popupCanCreate != prevCanCreate ||
        _popupOptions.length != prevOptions.length;
    if (mounted && (textChanged || popupChanged)) setState(() {});
  }

  /// Replace the whole draft — restoring an abandoned entry's original text, or
  /// dropping in text imported from a photo — and put the caret at the end.
  ///
  /// Writes through the controller so the normal change pipeline runs: an
  /// imported "@이름: 발화" transcript registers its badges on the way in, which
  /// is what makes those mentions live rather than literal text.
  void setText(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  /// True when the caret sits at the very end of the text — the "still typing"
  /// case, and the only one where following it with a scroll is welcome.
  bool get caretAtEnd {
    final selection = _controller.selection;
    if (!selection.isValid) return true;
    return selection.isCollapsed && selection.baseOffset >= _controller.text.length;
  }

  /// "@무언가" tokens the user typed but never confirmed as a speaker.
  List<String> unconfirmedMentions() => unregisteredMentionTokens(
        _controller.text,
        [..._badges, ..._graphSpeakers.map((o) => o.name)],
      );

  Future<void> _loadGraphSpeakers() async {
    try {
      final graph = await apiClient.getGraph();
      final nodes = graph['nodes'] as List<dynamic>? ?? [];
      final seen = <String>{};
      final out = <SpeakerOption>[];
      for (final raw in nodes) {
        if (raw is! Map) continue;
        final type = raw['type']?.toString();
        if (!isStatementHeadType(type)) continue;
        final name = normalizeMentionName(raw['name']?.toString() ?? '');
        if (name.isEmpty || name == '나' || !seen.add(name)) continue;
        out.add(SpeakerOption(name, isSource: !isSpeakerLikeType(type)));
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
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = MentionStyledController(
      mentionsOf: (t) => findMentions(t, matchableNames()),
      colorOf: colorFor,
    );
    _controller.text = widget.initialText;
    _controller.addListener(_onTextChanged);
    // Seed badges from any restored draft — the assignment above predates the
    // listener, so nothing would have registered its speakers. The popup is not
    // touched here: its OverlayPortal is not mounted yet.
    for (final name in atMentionLineSpeakers(widget.initialText)) {
      _ensureBadge(name);
    }
    _lastText = widget.initialText;
    _lastDirty = widget.initialText.trim().isNotEmpty;
    unawaited(_loadGraphSpeakers());
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── @멘션 감지·삽입 ─────────────────────────────────────────────────────

  /// 커서가 "@부분입력" 위에 있으면 (@ 위치, 입력 중 텍스트) 반환.
  ({int at, String partial})? _computeMentionContext() {
    final sel = _controller.selection;
    final text = _controller.text;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final upto = text.substring(0, sel.start);
    final at = upto.lastIndexOf('@');
    if (at < 0) return null;
    if (at > 0 && !RegExp(r'\s').hasMatch(upto[at - 1])) return null;
    final partial = upto.substring(at + 1);
    // A confirmed mention is followed by one separator before its message.
    // Detect it from the text itself (not ephemeral popup state), so rebuilds
    // can never reopen autocomplete over a selected speaker.
    for (final name in matchableNames()) {
      final tokenEnd = at + 1 + name.length;
      if (upto.length > tokenEnd &&
          upto.substring(at + 1, tokenEnd) == name &&
          RegExp(r'\s').hasMatch(upto[tokenEnd])) {
        return null;
      }
    }
    // Speaker names may contain spaces (for example "김 철수"). Keep the
    // autocomplete context alive while the user is typing the full name;
    // only a newline ends a mention because it starts a new dialogue line.
    if (partial.length > 40 || partial.contains('\n')) return null;
    return (at: at, partial: partial);
  }

  bool _isCompletedMentionContext(({int at, String partial}) context) {
    final completed = _completedMention;
    if (completed == null) return false;
    final selection = _controller.selection;
    final end = completed.at + completed.token.length;
    final stillSameToken =
        context.at == completed.at &&
        _controller.text.length >= end &&
        _controller.text.substring(completed.at, end) == completed.token;
    if (!stillSameToken || !selection.isValid || selection.start < end) {
      _completedMention = null;
      return false;
    }
    return true;
  }

  /// 팝업 후보: 기존 화자를 먼저 보여 주고, 입력하면 접두 일치 → 포함
  /// 일치 순으로 정렬한다. 화면에는 최대 다섯 줄만 렌더링한다.
  List<SpeakerOption> _computeMentionOptions(String partial) {
    final q = _mentionNameKey(partial);
    final seen = <String>{};
    final candidates = <SpeakerOption>[];
    for (final name in _badges) {
      if (seen.add(name)) candidates.add(SpeakerOption(name));
    }
    for (final opt in _graphSpeakers) {
      if (seen.add(opt.name)) candidates.add(opt);
    }

    final matches = candidates
        .where((option) =>
            q.isEmpty || _mentionNameKey(option.name).contains(q))
        .toList();
    matches.sort((a, b) {
      int rank(SpeakerOption option) {
        if (q.isEmpty) return _badges.contains(option.name) ? 0 : 1;
        return _mentionNameKey(option.name).startsWith(q) ? 0 : 1;
      }

      final rankComparison = rank(a).compareTo(rank(b));
      if (rankComparison != 0) return rankComparison;
      final badgeComparison = (_badges.contains(b.name) ? 1 : 0)
          .compareTo(_badges.contains(a.name) ? 1 : 0);
      if (badgeComparison != 0) return badgeComparison;
      return a.name.compareTo(b.name);
    });

    // A typed, new name needs one row for its create action.
    final limit =
        q.isEmpty ? _maxVisibleMentionRows : _maxVisibleMentionRows - 1;
    return matches.take(limit).toList();
  }

  /// 생성과 동시에 적용: 배지 등록 + 본문 삽입 한 번에.
  void _applyMention(String name) {
    final ctx = _mentionCtx;
    if (ctx == null) return;
    final normalized = normalizeMentionName(name);
    if (normalized.isEmpty) return;
    _ensureBadge(normalized);
    final text = _controller.text;
    final sel = _controller.selection;
    final replaced =
        '${text.substring(0, ctx.at)}@$normalized ${text.substring(sel.start)}';
    _completedMention = (at: ctx.at, token: '@$normalized ');
    _controller.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: ctx.at + normalized.length + 2),
    );
    _focusNode.requestFocus();
  }

  /// One backspace on a just-selected token reopens it as an editable query,
  /// instead of making the user delete the name character by character.
  bool _reopenCompletedMention() {
    final completed = _completedMention;
    final selection = _controller.selection;
    if (completed == null || !selection.isValid || !selection.isCollapsed) {
      return false;
    }
    final end = completed.at + completed.token.length;
    if (selection.start != end || _controller.text.length < end) return false;
    if (_controller.text.substring(completed.at, end) != completed.token) {
      _completedMention = null;
      return false;
    }
    final editable = completed.token.trimRight();
    final updated = _controller.text.replaceRange(completed.at, end, editable);
    _completedMention = null;
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: completed.at + editable.length),
    );
    return true;
  }

  /// ↑↓로 후보 이동, Enter로 현재 고른 후보(또는 새 화자)를 확정.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        _reopenCompletedMention()) {
      return KeyEventResult.handled;
    }
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

  /// Caret-anchored popup geometry, all relative to the field's top-left.
  /// [belowY] is where the popup's top sits when opening downward; [aboveY] is
  /// where its bottom sits when opening upward (just above the caret line).
  ({double dx, double belowY, double aboveY}) _caretMenuGeometry({
    required double fieldWidth,
    required TextStyle textStyle,
    required EdgeInsets contentPadding,
  }) {
    final selection = _controller.selection;
    final caretIndex = selection.isValid
        ? selection.extentOffset.clamp(0, _controller.text.length)
        : _controller.text.length;
    final beforeCaret = _controller.text.substring(0, caretIndex);
    final painter = TextPainter(
      text: TextSpan(text: beforeCaret, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: fieldWidth - contentPadding.horizontal);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: beforeCaret.length),
      Rect.zero,
    );
    final lineTop = contentPadding.top + caret.dy;
    return (
      dx: contentPadding.left + caret.dx,
      belowY: lineTop + painter.preferredLineHeight + 6,
      aboveY: lineTop - 6,
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
    return SizedBox(
      height: 48,
      child: MouseRegion(
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
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 16, color: iconColor),
                  ),
                  const SizedBox(width: 11),
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Plain style, no strut override and no custom leading distribution. Those
    // existed to keep MentionHighlightPainter's chip backgrounds from wobbling,
    // and that painter is gone — while the overrides kept moving the canvas
    // baseline away from the plain line box the hidden DOM input uses to resolve
    // taps, costing vertical accuracy on a multi-line draft for nothing.
    final textStyle = textScaleBakedIn(
      context,
      (theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16))
          .copyWith(height: 1.5),
    );
    final ctx = _mentionCtx;
    final baseDecoration = widget.decoration ?? const InputDecoration();
    final contentPadding =
        baseDecoration.contentPadding?.resolve(TextDirection.ltr) ??
            _contentPadding;
    final decoration = baseDecoration.copyWith(
      contentPadding: contentPadding,
      counterText: widget.showCounter ? baseDecoration.counterText : '',
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Only the popup needs caret geometry, and computing it lays out the
        // whole text-before-caret with a fresh TextPainter. On a long pasted
        // draft that is a full text layout every single build — pure waste
        // whenever the popup is closed, which is nearly always.
        final geometry = ctx == null
            ? (dx: 0.0, belowY: 0.0, aboveY: 0.0)
            : _caretMenuGeometry(
                fieldWidth: constraints.maxWidth,
                textStyle: textStyle,
                contentPadding: contentPadding,
              );
        final maxLeft = constraints.maxWidth > _popupWidth + 16
            ? constraints.maxWidth - _popupWidth - 8
            : 8.0;
        final left = geometry.dx.clamp(8.0, maxLeft).toDouble();

        final popupRows = <Widget>[
          for (var i = 0; i < _popupOptions.length; i++)
            _popupRow(
              icon: _popupOptions[i].name == '나'
                  ? Icons.person_rounded
                  : _popupOptions[i].isSource
                      ? Icons.menu_book_rounded
                      : Icons.person_outline_rounded,
              iconColor: _badges.contains(_popupOptions[i].name)
                  ? colorFor(_popupOptions[i].name)
                  : theme.colorScheme.primary,
              label: _popupOptions[i].name == '나'
                  ? selfSpeakerLabel
                  : _popupOptions[i].name,
              trailing: !_badges.contains(_popupOptions[i].name)
                  ? tr('mention.fromGraphTrailing')
                  : null,
              selected: i == _optionCursor,
              onTap: () => _applyMention(_popupOptions[i].name),
              onHover: () => setState(() => _optionCursor = i),
            ),
          if (_popupCanCreate)
            _popupRow(
              icon: Icons.add_circle_outline_rounded,
              iconColor: theme.colorScheme.primary,
              label: tr(
                  'mention.createNewSpeaker', {'partial': ctx?.partial ?? ''}),
              trailing: 'Enter',
              selected: _optionCursor == _popupOptions.length,
              onTap: () => _applyMention(ctx?.partial ?? ''),
              onHover: () => setState(
                () => _optionCursor = _popupOptions.length,
              ),
            ),
        ];
        final popupHeight = popupRows.length * 48.0;
        final popupContent = SizedBox(
          width: _popupWidth,
          height: popupHeight,
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
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
                ),
              ),
              // Never give the overlay a fixed scroll viewport. A fixed height
              // combined with an upward anchor was what produced the large
              // empty panel when the diary had accumulated many speakers.
              child:
                  Column(mainAxisSize: MainAxisSize.min, children: popupRows),
            ),
          ),
        );

        return CompositedTransformTarget(
          link: _popupLink,
          child: OverlayPortal(
            controller: _popupController,
            overlayChildBuilder: (context) {
              if (ctx == null) return const SizedBox.shrink();
              // When docked at the bottom of the screen the popup opens upward:
              // anchor the follower's BOTTOM to the caret line so it grows up,
              // regardless of its measured height.
              return CompositedTransformFollower(
                link: _popupLink,
                showWhenUnlinked: false,
                targetAnchor: Alignment.topLeft,
                followerAnchor: widget.openUpward
                    ? Alignment.bottomLeft
                    : Alignment.topLeft,
                offset: Offset(
                  left,
                  widget.openUpward ? geometry.aboveY : geometry.belowY,
                ),
                // OverlayPortal gives its child the whole overlay's loose
                // bounds. Align with size factors prevents that height from
                // becoming the popup's own height before it is anchored up.
                child: Align(
                  alignment: Alignment.bottomLeft,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: popupContent,
                ),
              );
            },
            // Do not paint a second text layer behind the field. It cannot
            // share Flutter's final glyph layout and was the source of the
            // detached, block-shaped highlight. Slack-style mentions here are
            // inline rich-text links rendered by the TextEditingController.
            child: Focus(
              onKeyEvent: _onKey,
              // The scale is already inside textStyle.fontSize. Scaling again
              // here would paint larger than the size the DOM input was told,
              // which is the mismatch this is all about.
              child: NoTextScaling(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  scrollController: _scroll,
                  enabled: widget.enabled,
                  style: textStyle,
                  maxLines: widget.maxLines,
                  minLines: widget.minLines,
                  maxLength: kMaxJournalTextChars,
                  maxLengthEnforcement: MaxLengthEnforcement.none,
                  decoration: decoration,
                  onSubmitted: widget.onSubmitted,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
