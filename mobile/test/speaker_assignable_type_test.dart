// The identity predicates: what can be a 화자, what gets the canvas head tier,
// and what shows the person icon rather than the book icon.
//
// Person was retired as a node type — everything is Identity or Source now, and
// "this identity is a real person" is a bound voice profile, not a type. Legacy
// spellings (Person/Speaker/화자) must still classify as Identity because the
// backfill is not simultaneous with the app release.
//
// Mirrors backend/app/entity_types.py. Keep the two in sync.

import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/utils/graph_layout.dart';

void main() {
  group('isSpeakerAssignableType', () {
    test('accepts the Identity category', () {
      for (final t in ['Identity', 'Animal', 'pet', 'Organization', 'group']) {
        expect(isSpeakerAssignableType(t), isTrue, reason: t);
      }
    });

    test('accepts sources — a book or an outlet can be attributed', () {
      expect(isSpeakerAssignableType('Source'), isTrue);
    });

    test('accepts legacy person-like spellings from un-migrated graphs', () {
      for (final t in ['Person', 'person', 'Speaker', 'Individual', '화자']) {
        expect(isSpeakerAssignableType(t), isTrue, reason: t);
      }
    });

    test('still rejects concepts and statements', () {
      for (final t in ['Concept', 'Statement', 'Event', '']) {
        expect(isSpeakerAssignableType(t), isFalse, reason: t);
      }
      expect(isSpeakerAssignableType(null), isFalse);
    });
  });

  group('isStatementHeadType', () {
    test('equals isSpeakerAssignableType', () {
      // These used to differ (head = Person ∪ Source, picker = plus Identity),
      // which left an Identity-typed speaker without the canvas head tier — no
      // speaker colour, no 2-hop focus, missing from the legend. Anything that
      // can be a speaker is exactly what can head a statement.
      for (final t in [
        'Identity',
        'Source',
        'Person',
        'Speaker',
        'pet',
        'Concept',
        'Statement',
        '',
      ]) {
        expect(isStatementHeadType(t), isSpeakerAssignableType(t), reason: t);
      }
    });

    test('an Identity node is a head', () {
      expect(isStatementHeadType('Identity'), isTrue);
    });
  });

  group('isNonSourceIdentityType', () {
    test('true for identities, false for sources', () {
      // Drives the person-vs-book icon in the pickers. Must be true for
      // 'Identity' or every speaker renders as a book after the migration.
      expect(isNonSourceIdentityType('Identity'), isTrue);
      expect(isNonSourceIdentityType('Person'), isTrue);
      expect(isNonSourceIdentityType('pet'), isTrue);
      expect(isNonSourceIdentityType('Source'), isFalse);
      expect(isNonSourceIdentityType('media'), isFalse);
      expect(isNonSourceIdentityType('Concept'), isFalse);
    });
  });

  group('graph tiering', () {
    test('an Identity node sits in the speaker tier', () {
      expect(graphFocusTier('Identity'), 'speaker');
      expect(graphFocusTier('Source'), 'speaker');
      expect(graphFocusTier('Person'), 'speaker');
      expect(graphFocusTier('Statement'), 'statement');
      expect(graphFocusTier('Concept'), 'concept');
    });

    test('statementHeadIndex finds an Identity head', () {
      final nodes = <Map<String, dynamic>>[
        {'id': 'a', 'name': '투자자', 'type': 'Identity'},
        {'id': 'b', 'name': '진술', 'type': 'Statement'},
      ];
      final edges = <Map<String, dynamic>>[
        {'source_id': 'a', 'target_id': 'b', 'relation': 'SPOKE_OR_PUBLISHED'},
      ];
      expect(statementHeadIndex(nodes, edges)['b'], 'a');
    });
  });

  group('entityTypeMatches', () {
    test('the Identity chip also catches legacy rows', () {
      expect(entityTypeMatches('Identity', 'Identity'), isTrue);
      expect(entityTypeMatches('Person', 'Identity'), isTrue);
      expect(entityTypeMatches('Speaker', 'Identity'), isTrue);
      // Source keeps its own chip.
      expect(entityTypeMatches('Source', 'Identity'), isFalse);
      expect(entityTypeMatches('Concept', 'Identity'), isFalse);
    });
  });
}
