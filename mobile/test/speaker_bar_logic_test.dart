// The pure logic behind the speaker bar: color assignment, turn counting, and
// the two text rewrites its chip offers.
//
// Color is the thread that ties the composer badges, the review sheet, the
// transcript and the graph together, so "two speakers, two colors" is a
// correctness property here, not a style preference.

import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/mention_editor_core.dart';

void main() {
  group('colorForSpeaker', () {
    test('나 is always the fixed self color', () {
      expect(colorForSpeaker('나', ['나', '제니']), kSelfMentionColor);
      expect(colorForSpeaker('나', ['제니', '나']), kSelfMentionColor);
    });

    test('distinct speakers get distinct colors', () {
      final badges = ['나', '제니', '민수', '수아'];
      final colors = badges.map((n) => colorForSpeaker(n, badges)).toSet();
      expect(colors.length, badges.length);
    });

    // The old implementation subtracted one from indexOf, which assumed 나 sat
    // at index 0. A saved entry's speaker list or an OCR result need not contain
    // 나 at all, and then the first two speakers collided on one color.
    test('distinct colors hold when 나 is absent', () {
      final badges = ['제니', '민수'];
      expect(
        colorForSpeaker('제니', badges),
        isNot(colorForSpeaker('민수', badges)),
      );
    });

    test('a speaker keeps its color whether or not 나 is in the list', () {
      expect(
        colorForSpeaker('민수', ['나', '제니', '민수']),
        colorForSpeaker('민수', ['제니', '민수']),
      );
    });

    test('the palette wraps rather than crashing past its length', () {
      final many = [for (var i = 0; i < 20; i++) '화자$i'];
      expect(() => colorForSpeaker('화자19', many), returnsNormally);
    });
  });

  group('speakerColorOrder', () {
    test('puts 나 first and keeps the rest in first-appearance order', () {
      expect(speakerColorOrder(['제니', '나', '민수', '제니']),
          ['나', '제니', '민수']);
    });

    test('omits 나 when it never appears', () {
      expect(speakerColorOrder(['제니', '민수']), ['제니', '민수']);
    });

    test('ignores blank names', () {
      expect(speakerColorOrder(['', '  ', '제니']), ['제니']);
    });
  });

  group('speakerTurns', () {
    test('counts turns per speaker in appearance order', () {
      final segments = [
        const MapEntry('제니', 'a'),
        const MapEntry('나', 'b'),
        const MapEntry('제니', 'c'),
      ];
      // MapEntry has no value equality, so compare the pairs themselves.
      expect(
        speakerTurns(segments).map((e) => '${e.key}:${e.value}').toList(),
        ['제니:2', '나:1'],
      );
    });

    // The shape a bad split takes: many speakers, one turn each. The bar prints
    // these numbers so that shape is visible before it reaches the graph.
    test('a glossary-shaped split shows as all-ones', () {
      final segments = [
        for (final term in ['약정액', '설정액', 'ROE']) MapEntry(term, '정의'),
      ];
      final turns = speakerTurns(segments);
      expect(turns.length, 3);
      expect(turns.every((e) => e.value == 1), isTrue);
    });
  });

  group('renameMentionInText', () {
    test('rewrites every occurrence', () {
      expect(
        renameMentionInText('@제니 안녕\n@나 반가워\n@제니 또 봐', '제니', '지니'),
        '@지니 안녕\n@나 반가워\n@지니 또 봐',
      );
    });

    test('handles a name that grows longer without corrupting later hits', () {
      expect(
        renameMentionInText('@제니 a\n@제니 b', '제니', '제니퍼팀장'),
        '@제니퍼팀장 a\n@제니퍼팀장 b',
      );
    });

    test('leaves the colon form intact', () {
      expect(
        renameMentionInText('@제니: 안녕', '제니', '지니'),
        '@지니: 안녕',
      );
    });

    test('is a no-op when the name is absent', () {
      expect(renameMentionInText('@나 안녕', '제니', '지니'), '@나 안녕');
    });
  });

  group('dissolveMentionInText', () {
    test('removes the marker and its separator', () {
      expect(dissolveMentionInText('@제니: 안녕', '제니'), '안녕');
    });

    test('removes a space-separated marker', () {
      expect(dissolveMentionInText('@제니 안녕', '제니'), '안녕');
    });

    test('folds every occurrence, leaving other speakers alone', () {
      expect(
        dissolveMentionInText('@나: 안녕\n@제니: 반가워\n@제니: 또 봐', '제니'),
        '@나: 안녕\n반가워\n또 봐',
      );
    });

    test('is a no-op when the name is absent', () {
      expect(dissolveMentionInText('@나: 안녕', '제니'), '@나: 안녕');
    });
  });
}
