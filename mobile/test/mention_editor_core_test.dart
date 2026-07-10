import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

void main() {
  const sample = '@김태연상무님 모형공학부 부장님이 기업은행이 CES2025에서 발표한 '
      '성장성 발굴 플랫폼에 꽂히셨다. 그리고 해당 플랫폼에는 8가지의 Driver가 있다.\n'
      '@나 그럼 그 8가지의 Driver라는 게 정보영역 분리에서는 대분류 같은 개념이자 '
      '모형에서는 하부모형 같은 개념인가요?\n'
      '@김태연상무님 그렇게 볼 수 있을 거 같다.';

  test('scanAtMentionTokens finds all pasted speakers', () {
    final hits = scanAtMentionTokens(sample);
    expect(hits.length, 3);
    expect(hits[0].name, '김태연상무님');
    expect(hits[1].name, '나');
    expect(hits[2].name, '김태연상무님');
  });

  test('findMentions works before badges are registered', () {
    final hits = findMentions(sample, const ['나']);
    expect(hits.length, 3);
    expect(hits.first.start, 0);
  });

  test('findMentions accepts BOM before first mention', () {
    final text = '\uFEFF@나 안녕';
    final hits = findMentions(text, const ['나']);
    expect(hits.length, 1);
    expect(hits.first.name, '나');
  });

  test('splitByMentions keeps full first paragraph', () {
    final hits = scanAtMentionTokens(sample);
    final segs = splitByMentions(sample, hits);
    expect(segs.first.key, '김태연상무님');
    expect(segs.first.value, contains('Driver가 있다'));
    expect(segs.first.value, isNot('다.'));
  });
}
