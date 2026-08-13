// Selecting extracted expressions and deleting them (with their quizzes).
//
// Extraction has emitted things that are not vocabulary at all — people's names
// romanized out of a group chat — so the learner needs to select the bad ones
// and remove them in one action, and the request must carry every selection.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/api/client.dart';
import 'package:graphrag_mobile/widgets/node_expression_sheet.dart';

class _CapturingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>);
    final items = (options.data as Map)['items'] as List;
    return ResponseBody.fromString(
      jsonEncode({
        'removed_count': items.length,
        'quizzes_deleted': items.length,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _expressions = {
  'german': [
    {'expression': 'gut sein', 'meaning': '좋다'},
    {'expression': 'es heißt eui-jun und seung-hyun', 'meaning': '의준과 승현이라고 말한다'},
    {'expression': 'euijun seunghyeon ist', 'meaning': '의준이 승현이다'},
  ],
};

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showNodeExpressionSheet(
              context: context,
              nodeId: 'node-1',
              expressionsByLanguage: Map<String, dynamic>.from(_expressions),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  late _CapturingAdapter adapter;

  setUp(() {
    adapter = _CapturingAdapter();
    apiClient.dio.httpClientAdapter = adapter;
  });

  testWidgets('nothing is deletable until something is selected',
      (tester) async {
    await _openSheet(tester);

    expect(find.text('gut sein'), findsOneWidget);
    expect(find.textContaining('삭제'), findsNothing);
  });

  testWidgets('selected expressions are deleted together', (tester) async {
    await _openSheet(tester);

    await tester.tap(find.text('es heißt eui-jun und seung-hyun'));
    await tester.tap(find.text('euijun seunghyeon ist'));
    await tester.pumpAndSettle();

    expect(find.text('2개 선택됨'), findsOneWidget);
    await tester.tap(find.text('2개 삭제'));
    await tester.pumpAndSettle();

    // The dialog states the consequence before anything is removed.
    expect(find.textContaining('빈칸 문제도 함께 삭제'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    final sent = (adapter.requests.single['items'] as List)
        .map((item) => (item as Map)['expression'])
        .toList();
    expect(sent, [
      'es heißt eui-jun und seung-hyun',
      'euijun seunghyeon ist',
    ]);

    // Deleted rows leave the list; the untouched one stays.
    expect(find.text('es heißt eui-jun und seung-hyun'), findsNothing);
    expect(find.text('euijun seunghyeon ist'), findsNothing);
    expect(find.text('gut sein'), findsOneWidget);
  });

  testWidgets('select all covers every language group', (tester) async {
    await _openSheet(tester);

    await tester.tap(find.text('전체 선택'));
    await tester.pumpAndSettle();

    expect(find.text('3개 선택됨'), findsOneWidget);
    expect(find.text('3개 삭제'), findsOneWidget);
  });

  testWidgets('cancelling the dialog deletes nothing', (tester) async {
    await _openSheet(tester);

    await tester.tap(find.text('gut sein'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1개 삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();

    expect(adapter.requests, isEmpty);
    expect(find.text('gut sein'), findsOneWidget);
  });
}
