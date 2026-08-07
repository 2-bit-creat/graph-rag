import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/widgets/quiz/flip_card.dart';
import 'package:graphrag_mobile/widgets/quiz/swipe_deck.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 300, height: 400, child: child),
        ),
      ),
    );

void main() {
  group('SwipeDeck', () {
    late List<(int, SwipeDirection)> swipes;
    late SwipeDeckController controller;

    Widget deck({int itemCount = 3}) {
      return _host(
        SwipeDeck(
          controller: controller,
          itemCount: itemCount,
          onSwipe: (index, direction) => swipes.add((index, direction)),
          itemBuilder: (context, index) => Container(
            key: ValueKey('card$index'),
            color: Colors.blue,
            child: Text('card$index'),
          ),
        ),
      );
    }

    setUp(() {
      swipes = [];
      controller = SwipeDeckController();
    });

    tearDown(() => controller.dispose());

    testWidgets('dragging right past the threshold reports a right swipe',
        (tester) async {
      await tester.pumpWidget(deck());
      await tester.drag(find.text('card0'), const Offset(200, 0));
      await tester.pumpAndSettle();

      expect(swipes, [(0, SwipeDirection.right)]);
    });

    testWidgets('dragging left past the threshold reports a left swipe',
        (tester) async {
      await tester.pumpWidget(deck());
      await tester.drag(find.text('card0'), const Offset(-200, 0));
      await tester.pumpAndSettle();

      expect(swipes, [(0, SwipeDirection.left)]);
    });

    testWidgets('a short drag springs back without reporting a swipe',
        (tester) async {
      await tester.pumpWidget(deck());
      // 20px against a 300px deck is well under the 28% commit threshold.
      await tester.drag(find.text('card0'), const Offset(20, 0));
      await tester.pumpAndSettle();

      expect(swipes, isEmpty);
    });

    testWidgets('a fast flick commits even when the card stayed under the '
        'distance threshold', (tester) async {
      await tester.pumpWidget(deck());
      // 64px total across 64ms = 1000px/s. Under the 84px (28% of 300) commit
      // distance but over the 800px/s velocity threshold, so only the velocity
      // rule can carry this one.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('card0')),
      );
      for (var i = 1; i <= 8; i++) {
        await gesture.moveBy(
          const Offset(8, 0),
          timeStamp: Duration(milliseconds: 8 * i),
        );
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(swipes, [(0, SwipeDirection.right)]);
    });

    testWidgets('the controller swipes programmatically', (tester) async {
      await tester.pumpWidget(deck());
      controller.swipe(SwipeDirection.left);
      await tester.pumpAndSettle();

      expect(swipes, [(0, SwipeDirection.left)]);
    });

    testWidgets('an empty deck renders nothing and ignores the controller',
        (tester) async {
      await tester.pumpWidget(deck(itemCount: 0));
      controller.swipe(SwipeDirection.right);
      await tester.pumpAndSettle();

      expect(find.text('card0'), findsNothing);
      expect(swipes, isEmpty);
    });

    testWidgets('only the top two cards are built', (tester) async {
      await tester.pumpWidget(deck(itemCount: 5));
      expect(find.text('card0'), findsOneWidget);
      expect(find.text('card1'), findsOneWidget);
      expect(find.text('card2'), findsNothing);
    });
  });

  group('FlipCard', () {
    testWidgets('shows the front until flipped, then the back',
        (tester) async {
      Widget card(bool showBack) => _host(
            FlipCard(
              showBack: showBack,
              front: const Text('front'),
              back: const Text('back'),
            ),
          );

      await tester.pumpWidget(card(false));
      expect(find.text('front'), findsOneWidget);
      expect(find.text('back'), findsNothing);

      await tester.pumpWidget(card(true));
      await tester.pumpAndSettle();
      expect(find.text('back'), findsOneWidget);
      expect(find.text('front'), findsNothing);

      // And back again — the controller must reverse, not re-run forward.
      await tester.pumpWidget(card(false));
      await tester.pumpAndSettle();
      expect(find.text('front'), findsOneWidget);
    });

    testWidgets('only one face is mounted mid-rotation', (tester) async {
      await tester.pumpWidget(
        _host(
          const FlipCard(
            showBack: false,
            front: Text('front'),
            back: Text('back'),
          ),
        ),
      );
      await tester.pumpWidget(
        _host(
          const FlipCard(
            showBack: true,
            front: Text('front'),
            back: Text('back'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 120));

      expect(
        find.text('front').evaluate().length +
            find.text('back').evaluate().length,
        1,
      );
    });
  });
}
