// A graph commit that the server finished must never be reported as a failure.
//
// The apply endpoint commits synchronously and can outrun the client's receive
// timeout on a long entry; when it did, the user saw "지식그래프 확정 실패" while
// the nodes were already in their graph. These lock in the two ways that ends:
// the transport gives up (reconcile against the server), and the retry hits an
// already-committed entry (409 graph_locked is the desired outcome, not an error).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphrag_mobile/api/client.dart';

/// Serves canned responses per path; records the request order.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;
  final List<String> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add('${options.method} ${options.path}');
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, int statusCode) =>
    ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  late ApiClient client;

  setUp(() => client = ApiClient());

  test('a timed-out commit that actually landed resolves as success', () async {
    var applyCalls = 0;
    var entryCalls = 0;
    final adapter = _FakeAdapter((options) {
      if (options.path.endsWith('/graph/apply')) {
        applyCalls++;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }
      entryCalls++;
      // The commit finished server-side just after the client gave up.
      return _json({'id': 'e1', 'status': 'graph_ready', 'graph_status': 'graph_ready'}, 200);
    });
    client.dio.httpClientAdapter = adapter;

    final result = await client.applyEntryGraph('e1', claims: const []);

    expect(result['status'], 'graph_ready');
    expect(applyCalls, 1, reason: 'the commit must not be re-sent');
    expect(entryCalls, 1);
  });

  test('an already-committed entry (409 graph_locked) is a success', () async {
    client.dio.httpClientAdapter = _FakeAdapter((options) {
      return _json({
        'detail': {'code': 'graph_locked', 'message': '이미 확정된 지식그래프가 있습니다.'}
      }, 409);
    });

    final result = await client.applyEntryGraph('e1', claims: const []);

    expect(result['status'], 'graph_ready');
  });

  test('a commit that truly failed still surfaces as an error', () async {
    client.dio.httpClientAdapter = _FakeAdapter((options) {
      if (options.path.endsWith('/graph/apply')) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return _json({'id': 'e1', 'status': 'graph_failed', 'graph_status': 'graph_failed'}, 200);
    });

    await expectLater(
      client.applyEntryGraph('e1', claims: const []),
      throwsA(isA<Exception>()),
    );
  });

  test('a rejected commit (400) is not reconciled away', () async {
    client.dio.httpClientAdapter = _FakeAdapter((options) {
      return _json({'detail': '검토할 그래프 드래프트가 없습니다.'}, 400);
    });

    await expectLater(
      client.applyEntryGraph('e1', claims: const []),
      throwsA(isA<Exception>()),
    );
  });
}
