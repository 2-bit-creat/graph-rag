// The @ picker's scope is Person ∪ Source ∪ Identity.
//
// It used to filter on isStatementHeadType, which is Person ∪ Source only. Most
// new mentions are typed as Identity — the category exists precisely so a first
// mention is not forced into "person" (마야 is a cat) — so filtering that way
// dropped nearly everything the graph knew and the popup looked empty on a
// graph full of identities.
//
// Mirrors backend/app/entity_types.py `is_identity_type`. Keep the two in sync.

import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/graph_layout.dart';

void main() {
  group('isSpeakerAssignableType', () {
    test('accepts person-like types', () {
      for (final t in ['Person', 'person', 'Speaker', 'Individual']) {
        expect(isSpeakerAssignableType(t), isTrue, reason: t);
      }
    });

    test('accepts sources — a book or an outlet can be attributed', () {
      expect(isSpeakerAssignableType('Source'), isTrue);
    });

    test('accepts the wider Identity category', () {
      for (final t in ['Identity', 'Animal', 'pet', 'Organization', 'group']) {
        expect(isSpeakerAssignableType(t), isTrue, reason: t);
      }
    });

    test('still rejects concepts and statements', () {
      for (final t in ['Concept', 'Statement', 'Event', '']) {
        expect(isSpeakerAssignableType(t), isFalse, reason: t);
      }
      expect(isSpeakerAssignableType(null), isFalse);
    });

    test('is strictly wider than the layout predicate', () {
      // The canvas hierarchy keeps using isStatementHeadType; these are two
      // different questions and must not be collapsed into one.
      expect(isStatementHeadType('Identity'), isFalse);
      expect(isSpeakerAssignableType('Identity'), isTrue);
    });
  });
}
