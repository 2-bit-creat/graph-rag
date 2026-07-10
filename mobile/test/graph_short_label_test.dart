import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/graph_layout.dart';

void main() {
  test('graphShortLabel does not split Korean graphemes', () {
    const name = '대분류 설계 계획을 진행했다';
    final short = graphShortLabel(name, 28);
    expect(short.characters.length, lessThanOrEqualTo(15));
    expect(short, isNot(contains('\uFFFD')));
    expect(short, isNot(contains('…')));
  });

  test('graphRelationDisplayLabel caps at grapheme boundary', () {
    const rel = 'SPOKE_OR_PUBLISHED';
    final label = graphRelationDisplayLabel(rel, maxLen: 8);
    expect(label.characters.length, lessThanOrEqualTo(8));
    expect(label, isNot(contains('…')));
  });
}
