import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

void main() {
  group('atMentionLineSpeakers', () {
    test('registers speakers from pasted "@이름:" dialogue', () {
      const text = '@나: 부부장님, 체크리스트 얘기 드릴게요.\n'
          '@부부장님: 산업별로 다 나누면 AHP 설문이 폭증해.\n'
          '@나: 그러면 2안으로 가겠습니다.';
      expect(atMentionLineSpeakers(text), ['나', '부부장님']);
    });

    test('ignores an @ that is not a line-leading speaker label', () {
      expect(atMentionLineSpeakers('메일은 a@b.com 으로 보냈어'), isEmpty);
      expect(atMentionLineSpeakers('중간에 @부부장님 이라고만 썼다'), isEmpty);
    });

    test('a registered @이름 splits the text per speaker', () {
      const text = '@나: 첫 발언\n@부부장님: 두 번째 발언';
      final names = atMentionLineSpeakers(text);
      final hits = findMentions(
        text,
        names.toList()..sort((a, b) => b.length.compareTo(a.length)),
      );
      expect(hits.length, 2);
      expect(toLabeledLines(splitByMentions(text, hits)),
          '[나]: 첫 발언\n[부부장님]: 두 번째 발언');
    });
  });

  group('unregisteredMentionTokens', () {
    test('flags @names that were never confirmed as speakers', () {
      expect(
        unregisteredMentionTokens('@나: 안녕 @부부장님: 반가워', ['나']),
        ['부부장님'],
      );
    });

    test('says nothing when every mention is known', () {
      expect(
        unregisteredMentionTokens('@나: 안녕 @부부장님: 반가워', ['나', '부부장님']),
        isEmpty,
      );
    });

    test('does not treat an email address as a mention', () {
      expect(unregisteredMentionTokens('보내기: a@b.com', ['나']), isEmpty);
    });
  });
}
