import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/screens/expression_deck_screen.dart';

void main() {
  testWidgets('expression card flips from expression to meaning',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ExpressionDeckScreen(
          items: [
            {
              'expression': 'take over',
              'meaning': '인수하다',
              'example': 'They decided to take over the company.',
            },
          ],
        ),
      ),
    );

    expect(find.text('take over'), findsOneWidget);
    await tester.tap(find.text('take over'));
    await tester.pumpAndSettle();
    expect(find.text('인수하다'), findsOneWidget);
  });
}
