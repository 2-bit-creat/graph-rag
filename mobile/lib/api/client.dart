import 'package:dio/dio.dart';

import 'config.dart';

export 'config.dart' show apiBaseUrl, resolveMediaUrl, resolvedApiBaseUrl;

class ApiClient {
  ApiClient() {
    _dio = Dio(BaseOptions(
      baseUrl: resolvedApiBaseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 2),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
    ));
  }

  late final Dio _dio;

  Future<List<dynamic>> listEntries() async {
    try {
      final resp = await _dio.get('/journal/entries');
      return resp.data as List<dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '기록 목록');
    }
  }

  Exception _friendlyError(DioException e, String action) {
    final status = e.response?.statusCode;
    final detail = e.response?.data?.toString();
    if (e.type == DioExceptionType.connectionError || e.type == DioExceptionType.unknown) {
      return Exception(
        '$action 실패: 서버에 연결할 수 없습니다 ($resolvedApiBaseUrl).\n'
        '백엔드 실행: cd backend && py -3.12 -m uvicorn app.main:app --reload --port 8000',
      );
    }
    if (status == 404 && action == '퀴즈 생성') {
      return Exception(
        '$action 실패 (HTTP 404): /quiz API가 없습니다.\n'
        '백엔드를 최신 코드로 재시작하세요:\n'
        'cd backend && py -3.12 -m uvicorn app.main:app --reload --port 8000',
      );
    }
    if (status != null) {
      return Exception('$action 실패 (HTTP $status)${detail != null ? ': $detail' : ''}');
    }
    return Exception('$action 실패: ${e.message}');
  }

  Future<Map<String, dynamic>> getEntry(String id) async {
    try {
      final resp = await _dio.get('/journal/entries/$id');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '기록 상세');
    }
  }

  Future<Map<String, dynamic>> getEntryTrace(String id) async {
    final resp = await _dio.get('/journal/entries/$id/trace');
    return resp.data as Map<String, dynamic>;
  }

  Future<void> deleteEntry(String id) async {
    try {
      await _dio.delete('/journal/entries/$id');
    } on DioException catch (e) {
      throw _friendlyError(e, '일기 삭제');
    }
  }

  /// Delete every journal entry for the current user. Returns the count deleted.
  Future<int> deleteAllEntries() async {
    try {
      final resp = await _dio.delete('/journal/entries');
      final data = resp.data;
      if (data is Map && data['deleted'] is num) {
        return (data['deleted'] as num).toInt();
      }
      return 0;
    } on DioException catch (e) {
      throw _friendlyError(e, '전체 삭제');
    }
  }

  Future<Map<String, dynamic>> getFlowBlueprint() async {
    final resp = await _dio.get('/journal/pipeline/flow-blueprint');
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getQuizFlowBlueprint() async {
    final resp = await _dio.get('/quiz/pipeline/flow-blueprint');
    return resp.data as Map<String, dynamic>;
  }

  String artifactUrl(String entryId, String relativePath) {
    return '$resolvedApiBaseUrl/journal/entries/$entryId/artifacts/$relativePath';
  }

  Future<String> fetchArtifactText(String entryId, String relativePath) async {
    final resp = await _dio.get<String>(
      '/journal/entries/$entryId/artifacts/$relativePath',
      options: Options(responseType: ResponseType.plain),
    );
    return resp.data ?? '';
  }

  Future<Map<String, dynamic>> uploadAudio(
    String filePath, {
    String? filename,
    String? sourceType,
  }) async {
    final name = filename ?? 'recording.m4a';
    final fields = <String, dynamic>{
      'file': await MultipartFile.fromFile(filePath, filename: name),
    };
    if (sourceType != null) fields['source_type'] = sourceType;
    final formData = FormData.fromMap(fields);
    final resp = await _dio.post(
      '/journal/upload',
      data: formData,
      options: Options(contentType: 'multipart/form-data'),
    );
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> uploadAudioBytes(
    List<int> bytes, {
    required String filename,
    String mimeType = 'audio/wav',
    String? sourceType,
  }) async {
    final fields = <String, dynamic>{
      'file': MultipartFile.fromBytes(bytes, filename: filename, contentType: DioMediaType.parse(mimeType)),
    };
    if (sourceType != null) fields['source_type'] = sourceType;
    final formData = FormData.fromMap(fields);
    final resp = await _dio.post(
      '/journal/upload',
      data: formData,
      options: Options(contentType: 'multipart/form-data'),
    );
    return resp.data as Map<String, dynamic>;
  }

  /// [attributionKind]: 'self' (내 생각) / 'person' (저자·강연자) / 'source' (매체·AI).
  /// null이면 기존 화자 라벨링 흐름. 'person'은 [attributionName] 필수.
  Future<Map<String, dynamic>> createTextJournalEntry(
    String paragraphText, {
    String? sourceType,
    String? attributionKind,
    String? attributionName,
  }) async {
    try {
      final body = <String, dynamic>{'paragraph_text': paragraphText};
      if (sourceType != null) body['source_type'] = sourceType;
      if (attributionKind != null) body['attribution_kind'] = attributionKind;
      if (attributionName != null && attributionName.trim().isNotEmpty) {
        body['attribution_name'] = attributionName.trim();
      }
      final resp = await _dio.post('/journal/entries', data: body);
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '텍스트 기록 저장');
    }
  }

  /// @deprecated Use [createTextJournalEntry] with paragraph_text.
  Future<Map<String, dynamic>> createTextJournalEntryDialogue(
    List<Map<String, String>> dialogue,
  ) async {
    try {
      final resp = await _dio.post(
        '/journal/entries',
        data: {
          'dialogue': dialogue
              .map((line) => {'speaker': line['speaker'], 'text': line['text']})
              .toList(),
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '텍스트 기록 저장');
    }
  }

  Future<Map<String, dynamic>> generateQuizItem(
    String entryId,
    String quizType, {
    bool? isFreedomOn,
    String? selectedVocabId,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (isFreedomOn != null) body['is_freedom_on'] = isFreedomOn;
      if (selectedVocabId != null) body['selected_vocab_id'] = selectedVocabId;
      final resp = await _dio.post(
        '/journal/entries/$entryId/quiz/generate',
        queryParameters: {'quiz_type': quizType},
        data: body.isEmpty ? null : body,
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '퀴즈 생성');
    }
  }

  Future<Map<String, dynamic>> generateQuizGraph(
    String quizType, {
    String? selectedVocabId,
    String? language,
    String sourceMode = 'journal',
    int count = 1,
    String difficulty = 'normal',
  }) async {
    try {
      final body = <String, dynamic>{
        if (selectedVocabId != null) 'selected_vocab_id': selectedVocabId,
        if (quizType == 'composition') ...{
          'source_mode': sourceMode,
          'count': count,
          'difficulty': difficulty,
        },
      };
      final params = <String, dynamic>{'quiz_type': quizType};
      if (language != null) params['language'] = language;
      final resp = await _dio.post(
        '/quiz/generate',
        queryParameters: params,
        data: body.isEmpty ? null : body,
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '퀴즈 생성');
    }
  }

  Future<Map<String, dynamic>> listQuizGenerations({int limit = 50, int offset = 0}) async {
    final resp = await _dio.get('/quiz/generations', queryParameters: {
      'limit': limit,
      'offset': offset,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getQuizGenerationTrace(String quizId) async {
    final resp = await _dio.get('/quiz/generations/$quizId/trace');
    return resp.data as Map<String, dynamic>;
  }

  Future<String> fetchQuizArtifactText(String quizId, String relativePath) async {
    final resp = await _dio.get<String>(
      '/quiz/generations/$quizId/artifacts/$relativePath',
      options: Options(responseType: ResponseType.plain),
    );
    return resp.data ?? '';
  }

  Future<Map<String, dynamic>> getQuizProfile() async {
    try {
      final resp = await _dio.get('/quiz/profile');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '학습 프로필');
    }
  }

  Future<Map<String, dynamic>> listQuizQueueItems({
    required String queueKind,
    String? quizType,
    int limit = 50,
    int offset = 0,
    String order = 'desc',
  }) async {
    try {
      final resp = await _dio.get('/quiz/queue/items', queryParameters: {
        'queue_kind': queueKind,
        if (quizType != null) 'quiz_type': quizType,
        'limit': limit,
        'offset': offset,
        'order': order,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '퀴즈 큐');
    }
  }

  Future<Map<String, dynamic>> deleteQuizItem(
    String quizId, {
    bool permanent = false,
  }) async {
    try {
      final resp = await _dio.delete(
        '/quiz/$quizId',
        queryParameters: permanent ? {'permanent': 'true'} : null,
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '퀴즈 삭제');
    }
  }

  Future<Map<String, dynamic>> updateQuizLevel(int level) async {
    return updateQuizProfileSettings(level: level);
  }

  Future<Map<String, dynamic>> updateQuizProfileSettings({
    int? level,
    bool? isFreedomOn,
  }) async {
    try {
      final resp = await _dio.patch('/quiz/profile/settings', data: {
        if (level != null) 'level': level,
        if (isFreedomOn != null) 'is_freedom_on': isFreedomOn,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '학습 설정');
    }
  }

  Future<Map<String, dynamic>> startQuizSession({
    required String quizType,
    int size = 10,
    String? entryId,
    List<String>? quizIds,
    String? vocabSource,
    String? language,
  }) async {
    try {
      final resp = await _dio.post('/quiz/session', data: {
        'quiz_type': quizType,
        'size': size,
        if (entryId != null) 'entry_id': entryId,
        if (quizIds != null && quizIds.isNotEmpty) 'quiz_ids': quizIds,
        if (vocabSource != null) 'vocab_source': vocabSource,
        if (language != null && language.isNotEmpty) 'language': language,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '퀴즈 세션');
    }
  }

  /// Kick off a background quiz-queue top-up (generates from the graph).
  Future<void> refillQuizzes() async {
    try {
      await _dio.post('/quiz/refill');
    } on DioException catch (e) {
      throw _friendlyError(e, '문제 생성');
    }
  }

  Future<Map<String, dynamic>> submitQuizAnswer({
    required String quizId,
    String? answer,
    List<int>? order,
    int? selectedIndex,
    String? entryId,
  }) async {
    try {
      final resp = await _dio.post('/quiz/$quizId/submit', data: {
        if (answer != null) 'answer': answer,
        if (order != null) 'order': order,
        if (selectedIndex != null) 'selected_index': selectedIndex,
        if (entryId != null) 'entry_id': entryId,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '답안 제출');
    }
  }

  Future<List<dynamic>> generateQuiz(String entryId) async {
    final resp = await _dio.post('/journal/entries/$entryId/quiz');
    return (resp.data as Map<String, dynamic>)['cards'] as List<dynamic>;
  }

  Future<Map<String, dynamic>> buildGraph(String entryId, {bool force = false}) async {
    try {
      final resp = await _dio.post(
        '/journal/entries/$entryId/graph',
        queryParameters: force ? {'force': 'true'} : null,
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final data = e.response?.data;
        if (data is Map && data['detail'] is Map) {
          final detail = Map<String, dynamic>.from(data['detail'] as Map);
          final pending = detail['pending_labels'];
          if (pending is List && pending.isNotEmpty) {
            throw Exception(
              '화자 확인이 필요합니다: ${pending.map((e) => e.toString()).join(', ')}',
            );
          }
          final msg = detail['message']?.toString();
          if (msg != null && msg.isNotEmpty) {
            throw Exception(msg);
          }
        }
      }
      throw _friendlyError(e, 'GraphRAG');
    }
  }

  /// Commit a reviewed graph draft into immutable nodes. Pass the (possibly
  /// user-edited) [claims]; when null the server commits the stored draft as-is.
  Future<Map<String, dynamic>> applyEntryGraph(
    String entryId, {
    List<Map<String, dynamic>>? claims,
    String? contextType,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (claims != null) body['claims'] = claims;
      if (contextType != null) body['context_type'] = contextType;
      final resp = await _dio.post(
        '/journal/entries/$entryId/graph/apply',
        data: body.isEmpty ? null : body,
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final data = e.response?.data;
        if (data is Map && data['detail'] is Map) {
          final msg = (data['detail'] as Map)['message']?.toString();
          if (msg != null && msg.isNotEmpty) throw Exception(msg);
        }
      }
      throw _friendlyError(e, '지식 그래프 확정');
    }
  }

  Future<Map<String, dynamic>> clearGraph() async {
    try {
      final resp = await _dio.delete('/graph');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '지식 그래프 삭제');
    }
  }

  /// Concept nodes whose name matches an existing Person/self identity — likely
  /// people mis-stored as concepts before mention-resolution existed.
  Future<List<Map<String, dynamic>>> personMigrationSuggestions() async {
    try {
      final resp = await _dio.get('/kg/nodes/person-migration-suggestions');
      final data = resp.data as Map<String, dynamic>;
      return ((data['suggestions'] as List?) ?? [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } on DioException catch (e) {
      throw _friendlyError(e, '인물 마이그레이션 제안');
    }
  }

  /// Backfill alias embeddings for identity nodes missing them (fuzzy-match
  /// readiness for aliases learned before embedding indexing existed).
  Future<int> reindexAliasEmbeddings() async {
    try {
      final resp = await _dio.post('/kg/aliases/reindex');
      final data = resp.data as Map<String, dynamic>;
      return (data['indexed'] as num?)?.toInt() ?? 0;
    } on DioException catch (e) {
      throw _friendlyError(e, '별칭 임베딩 생성');
    }
  }

  /// Retype a node in place (e.g. Concept → Person), or — when [mergeInto] is
  /// given — merge it into that identity (reassigning edges, deleting the source).
  Future<Map<String, dynamic>> reclassifyNode(
    String nodeId, {
    String toType = 'Person',
    String? mergeInto,
  }) async {
    try {
      final resp = await _dio.post(
        '/kg/nodes/$nodeId/reclassify',
        data: {
          'to_type': toType,
          if (mergeInto != null) 'merge_into': mergeInto,
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '노드 재분류');
    }
  }

  Future<Map<String, dynamic>> generateExamples(String entryId) async {
    final resp = await _dio.post('/journal/entries/$entryId/examples');
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> graphSummary() async {
    final resp = await _dio.get('/journal/graph/summary');
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> speakerRecommend({
    required String journalEntryId,
    required String speakerLabel,
  }) async {
    try {
      final resp = await _dio.get(
        '/api/v1/graphs/speaker-recommend',
        queryParameters: {
          'journal_entry_id': journalEntryId,
          'speaker_label': speakerLabel,
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '화자 추천');
    }
  }

  Future<Map<String, dynamic>> speakerConfirm({
    required String journalEntryId,
    required String speakerProfileId,
    String? sessionLabel,
    String? nodeId,
    String? newNodeName,
    String? wrongName,
    bool asSelf = false,
    bool asSource = false,
  }) async {
    try {
      final resp = await _dio.post(
        '/api/v1/graphs/speaker-confirm',
        data: {
          'journal_entry_id': journalEntryId,
          'speaker_profile_id': speakerProfileId,
          if (sessionLabel != null && sessionLabel.isNotEmpty)
            'session_label': sessionLabel,
          if (nodeId != null) 'node_id': nodeId,
          if (newNodeName != null) 'new_node_name': newNodeName,
          if (wrongName != null) 'wrong_name': wrongName,
          if (asSelf) 'as_self': true,
          if (asSource) 'as_source': true,
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '화자 확정');
    }
  }

  /// Confirm/override the entry's content type (the LLM-suggested label).
  Future<Map<String, dynamic>> setSourceType(String entryId, String sourceType) async {
    try {
      final resp = await _dio.patch(
        '/journal/entries/$entryId/source-type',
        data: {'source_type': sourceType},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '유형 변경');
    }
  }

  /// Reversibly fix diarization over-split: merge speakers, collapse all to '나',
  /// or reset to the original diarization.
  Future<Map<String, dynamic>> remapSpeakers(
    String entryId, {
    Map<String, String>? groupMap,
    Map<String, String>? merges,
    bool mergeAll = false,
    bool toSelf = false,
    bool reset = false,
  }) async {
    try {
      final resp = await _dio.post(
        '/journal/entries/$entryId/speakers/remap',
        data: {
          if (groupMap != null) 'group_map': groupMap,
          if (merges != null) 'merges': merges,
          'merge_all': mergeAll,
          'to_self': toSelf,
          'reset': reset,
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '화자 정리');
    }
  }

  Future<List<dynamic>> graphNodeTypes() async {
    final resp = await _dio.get('/graph/node-types');
    return resp.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> getGraph() async {
    try {
      final resp = await _dio.get('/graph');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '지식 그래프');
    }
  }

  Future<Map<String, dynamic>> getNode(String nodeId) async {
    try {
      final resp = await _dio.get('/graph/nodes/$nodeId');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '노드 상세');
    }
  }

  Future<Map<String, dynamic>> getOntology() async {
    try {
      final resp = await _dio.get('/ontology');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '온톨로지');
    }
  }

  Future<List<dynamic>> listOntologyPresets() async {
    final resp = await _dio.get('/ontology/presets');
    return resp.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> applyOntologyPreset(String presetName) async {
    final resp = await _dio.post('/ontology/presets/$presetName/apply');
    return resp.data as Map<String, dynamic>;
  }

  /// Manually add a node from the KG edit surface (dedupes by name+type).
  Future<Map<String, dynamic>> createNode({
    required String name,
    required String type,
    String? description,
  }) async {
    try {
      final resp = await _dio.post('/graph/nodes', data: {
        'name': name,
        'type': type,
        if (description != null) 'description': description,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '노드 추가');
    }
  }

  Future<Map<String, dynamic>> updateNode(
    String nodeId, {
    required String name,
    required String type,
    String? description,
  }) async {
    try {
      final resp = await _dio.patch('/graph/nodes/$nodeId', data: {
        'name': name,
        'type': type,
        if (description != null) 'description': description,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final data = e.response?.data;
        if (data is Map && data['detail'] is Map) {
          final msg = (data['detail'] as Map)['message']?.toString();
          if (msg != null && msg.isNotEmpty) throw Exception(msg);
        }
      }
      throw _friendlyError(e, '노드 수정');
    }
  }

  Future<void> deleteNode(String nodeId) async {
    await _dio.delete('/graph/nodes/$nodeId');
  }

  Future<Map<String, dynamic>> getNodeDeletionImpact(String nodeId) async {
    try {
      final resp = await _dio.get('/graph/nodes/$nodeId/deletion-impact');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '삭제 영향 조회');
    }
  }

  Future<Map<String, dynamic>> deleteNodeCascade(String nodeId) async {
    try {
      final resp = await _dio.delete('/graph/nodes/$nodeId/cascade');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '노드 연쇄 삭제');
    }
  }

  Future<List<dynamic>> listTrash() async {
    try {
      final resp = await _dio.get('/graph/trash');
      return (resp.data as Map<String, dynamic>)['nodes'] as List<dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '휴지통 목록');
    }
  }

  Future<void> restoreFromTrash(String nodeId) async {
    try {
      await _dio.post('/graph/trash/$nodeId/restore');
    } on DioException catch (e) {
      throw _friendlyError(e, '노드 복구');
    }
  }

  Future<void> purgeFromTrash(String nodeId) async {
    try {
      await _dio.delete('/graph/trash/$nodeId/purge');
    } on DioException catch (e) {
      throw _friendlyError(e, '영구 삭제');
    }
  }

  Future<Map<String, dynamic>> unlinkNodeVoice(String nodeId) async {
    try {
      final resp = await _dio.delete('/graph/nodes/$nodeId/voice-link');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '목소리 임베딩 해제');
    }
  }

  Future<Map<String, dynamic>> updateEdge(String edgeId, {required String relation}) async {
    final resp = await _dio.patch('/graph/edges/$edgeId', data: {'relation': relation});
    return resp.data as Map<String, dynamic>;
  }

  Future<void> deleteEdge(String edgeId) async {
    await _dio.delete('/graph/edges/$edgeId');
  }

  Future<Map<String, dynamic>> createEdge({
    required String sourceId,
    required String targetId,
    required String relation,
  }) async {
    final resp = await _dio.post('/graph/edges', data: {
      'source_id': sourceId,
      'target_id': targetId,
      'relation': relation,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getJob(String jobId) async {
    final resp = await _dio.get('/jobs/$jobId');
    return resp.data as Map<String, dynamic>;
  }

  // --- Vocabulary ----------------------------------------------------------

  Future<List<dynamic>> listVocabularies() async {
    try {
      final resp = await _dio.get('/vocabularies');
      final data = resp.data as Map<String, dynamic>;
      return data['items'] as List<dynamic>? ?? [];
    } on DioException catch (e) {
      throw _friendlyError(e, '단어장 목록');
    }
  }

  Future<Map<String, dynamic>> getVocabulary(String vocabId) async {
    try {
      final resp = await _dio.get('/vocabularies/$vocabId');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '단어장 상세');
    }
  }

  Future<Map<String, dynamic>> createVocabulary({
    required String name,
    String? description,
  }) async {
    try {
      final resp = await _dio.post('/vocabularies', data: {
        'name': name,
        if (description != null && description.isNotEmpty) 'description': description,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '단어장 생성');
    }
  }

  Future<void> deleteVocabulary(String vocabId) async {
    try {
      await _dio.delete('/vocabularies/$vocabId');
    } on DioException catch (e) {
      throw _friendlyError(e, '단어장 삭제');
    }
  }

  Future<Map<String, dynamic>> updateVocabulary(
    String vocabId, {
    String? name,
    String? description,
  }) async {
    try {
      final resp = await _dio.patch('/vocabularies/$vocabId', data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '단어장 수정');
    }
  }

  Future<Map<String, dynamic>> addVocabularyWord(
    String vocabId, {
    required String word,
    String meaning = '',
    String? linkedDiaryId,
  }) async {
    try {
      final resp = await _dio.post('/vocabularies/$vocabId/words', data: {
        'word': word,
        'meaning': meaning,
        if (linkedDiaryId != null) 'linked_diary_id': linkedDiaryId,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '단어 추가');
    }
  }

  Future<void> deleteVocabularyWord(String vocabId, String word) async {
    try {
      await _dio.delete('/vocabularies/$vocabId/words/${Uri.encodeComponent(word)}');
    } on DioException catch (e) {
      throw _friendlyError(e, '단어 삭제');
    }
  }

  Future<Map<String, dynamic>> updateVocabularyWord(
    String vocabId,
    String word, {
    required String meaning,
  }) async {
    try {
      final resp = await _dio.patch(
        '/vocabularies/$vocabId/words/${Uri.encodeComponent(word)}',
        data: {'meaning': meaning},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '단어 뜻 수정');
    }
  }

  // --- Knowledge Graph Build (HITL pipeline) --------------------------------

  /// Stage 1: send raw Korean text to LLM extractor.
  ///
  /// [mode] is 'diary' or 'external'.
  /// Diary mode: speaker fixed to '나', returns single-claim structure
  ///   {nodes: {statement}, concepts, isExistingNodeMatched}.
  /// External mode: LLM splits by speaker, returns multi-claim structure
  ///   {contextTypeOptions, claims: [{speaker, statement, concepts, speaker_matched, concepts_matched}]}.
  Future<Map<String, dynamic>> extractKgFromText({
    required String mode,
    String? fixedSpeaker,
    String? sourceCategory,
    required String text,
    List<String> existingNodes = const [],
  }) async {
    try {
      final resp = await _dio.post('/kg/extract', data: {
        'mode': mode,
        if (fixedSpeaker != null) 'fixed_speaker': fixedSpeaker,
        if (sourceCategory != null) 'source_category': sourceCategory,
        'text': text,
        'existing_nodes': existingNodes,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, 'KG 추출');
    }
  }

  /// Stage 2: persist the human-verified claims into the graph DB.
  /// [claims] is a list of {speaker, statement, concepts}.
  /// Works for both diary mode (1 claim) and external mode (N claims).
  /// Called only after the user confirms the HITL review card.
  Future<Map<String, dynamic>> commitKgDraft({
    required List<Map<String, dynamic>> claims,
    required String contextType,
    required String originalText,
    String? journalEntryId,
  }) async {
    try {
      final resp = await _dio.post('/kg/commit', data: {
        'claims': claims,
        'context_type': contextType,
        'original_text': originalText,
        if (journalEntryId != null) 'journal_entry_id': journalEntryId,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, 'KG 저장');
    }
  }

  Future<Map<String, dynamic>> getKgStats() async {
    try {
      final resp = await _dio.get('/kg/stats');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, 'KG 통계');
    }
  }

  Future<List<dynamic>> getKgDebugRuns() async {
    try {
      final resp = await _dio.get('/kg/debug/runs');
      return resp.data as List<dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, 'KG 디버그');
    }
  }

  Future<Map<String, dynamic>> getKgCalendarData() async {
    try {
      final resp = await _dio.get('/kg/calendar-data');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '캘린더 데이터');
    }
  }

  /// Entry-centric timeline: one card per uploaded file. Returns {cards: [...]}.
  Future<List<Map<String, dynamic>>> getKgTimeline() async {
    try {
      final resp = await _dio.get('/kg/timeline');
      final cards = (resp.data as Map)['cards'] as List? ?? [];
      return cards.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on DioException catch (e) {
      throw _friendlyError(e, '타임라인');
    }
  }

  /// STT + speaker diarization for KG build audio input.
  /// Returns {transcript, plain_transcript, speaker_count, segments}.
  Future<Map<String, dynamic>> transcribeAudioForKg(
    List<int> bytes, {
    required String filename,
    String mimeType = 'audio/wav',
  }) async {
    try {
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
          contentType: DioMediaType.parse(mimeType),
        ),
      });
      final resp = await _dio.post(
        '/kg/transcribe',
        data: formData,
        options: Options(contentType: 'multipart/form-data'),
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '음성 변환');
    }
  }

  /// Load user profile (level + quiz settings + language/goal).
  Future<Map<String, dynamic>> getUserProfile() async {
    try {
      final resp = await _dio.get('/quiz/profile');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '프로필');
    }
  }


  /// Update native language (모국어 — explanations generated in this language).
  Future<void> updateNativeLanguage(String language) async {
    try {
      await _dio.patch('/quiz/profile/settings', data: {'native_language': language});
    } on DioException catch (e) {
      throw _friendlyError(e, '모국어 저장');
    }
  }

  /// Update per-language levels map {english: 50, german: 10}.
  Future<void> updateLanguageLevels(Map<String, int> levels) async {
    try {
      await _dio.patch('/quiz/profile/settings', data: {'language_levels': levels});
    } on DioException catch (e) {
      throw _friendlyError(e, '레벨 저장');
    }
  }

  /// Delete all expressions for a language and trigger re-extraction.
  Future<Map<String, dynamic>> deleteAndReextractLanguage(String language) async {
    try {
      final resp = await _dio.delete('/vocabularies/statement-bank/language/$language');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '표현 재추출');
    }
  }

  /// Update target languages list (multi-select).
  Future<void> updateActiveTargetLanguage(String language) async {
    try {
      await _dio.patch('/quiz/profile/settings', data: {
        'target_language': language,
      });
    } on DioException catch (e) {
      throw _friendlyError(e, '연습 언어 저장');
    }
  }

  Future<void> updateTargetLanguages(List<String> languages) async {
    try {
      await _dio.patch('/quiz/profile/settings', data: {
        'target_languages': languages,
      });
    } on DioException catch (e) {
      throw _friendlyError(e, '언어 설정 저장');
    }
  }

  /// Dry-run info before triggering retroactive extraction.
  Future<Map<String, dynamic>> getReprocessInfo(List<String> languages) async {
    try {
      final resp = await _dio.get(
        '/vocabularies/statement-bank/reprocess-info',
        queryParameters: {'languages': languages.join(',')},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '추출 정보');
    }
  }

  /// Trigger retroactive expression extraction after user confirms.
  Future<Map<String, dynamic>> triggerReprocess(List<String> languages) async {
    try {
      final resp = await _dio.post(
        '/vocabularies/statement-bank/reprocess',
        data: languages,
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '추출 실행');
    }
  }

  /// Get all extracted expressions grouped by language for a graph node.
  Future<Map<String, dynamic>> getNodeExpressions(String nodeId) async {
    try {
      final resp = await _dio.get('/graph/nodes/$nodeId/expressions');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '표현 불러오기');
    }
  }

  /// Delete a single expression from the statement bank.
  /// Delete an expression from the statement bank. By default removes the lemma
  /// from ALL origin nodes (the merged card's "remove from vocab"); pass [nodeId]
  /// to scope the delete to a single origin.
  Future<void> deleteStatementExpression({
    required String language,
    required String expression,
    String? nodeId,
  }) async {
    try {
      await _dio.delete(
        '/vocabularies/statement-bank/expressions',
        queryParameters: {
          'language': language,
          'expression': expression,
          if (nodeId != null) 'node_id': nodeId,
        },
      );
    } on DioException catch (e) {
      throw _friendlyError(e, '표현 삭제');
    }
  }

  // --- Tutor (작문 드릴) -----------------------------------------------------

  /// Save several tutor expressions at once. Returns the count saved.
  Future<int> saveTutorExpressionsBatch(List<Map<String, dynamic>> items) async {
    try {
      final resp = await _dio.post('/tutor/vocab/batch', data: {'items': items});
      return (resp.data as Map<String, dynamic>)['saved'] as int? ?? 0;
    } on DioException catch (e) {
      throw _friendlyError(e, '표현 저장');
    }
  }

  /// Recent completed drill rounds (activity log), most-recent-first.
  Future<List<Map<String, dynamic>>> getTutorHistory({int limit = 20}) async {
    try {
      final resp = await _dio.get('/tutor/history', queryParameters: {'limit': limit});
      final items = (resp.data as Map<String, dynamic>)['items'] as List? ?? [];
      return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on DioException catch (e) {
      throw _friendlyError(e, '드릴 기록');
    }
  }

  /// Free follow-up conversation with the tutor about the current drill.
  Future<String> tutorChat({
    required List<Map<String, String>> messages,
    String language = 'english',
    String? drillPrompt,
  }) async {
    try {
      final resp = await _dio.post('/tutor/chat', data: {
        'messages': messages,
        'language': language,
        if (drillPrompt != null) 'drill_prompt': drillPrompt,
      });
      return (resp.data as Map<String, dynamic>)['answer'] as String? ?? '';
    } on DioException catch (e) {
      throw _friendlyError(e, '튜터 대화');
    }
  }

  /// Delete a saved tutor expression.
  Future<void> deleteTutorExpression({
    required String expression,
    String language = 'english',
  }) async {
    try {
      await _dio.delete('/tutor/vocab', queryParameters: {
        'expression': expression,
        'language': language,
      });
    } on DioException catch (e) {
      throw _friendlyError(e, '표현 삭제');
    }
  }

  /// List expressions saved in the tutor vocabulary. Returns {items, total}.
  /// [language] filters to one target language (null = all).
  Future<Map<String, dynamic>> getTutorVocab({String? language}) async {
    try {
      final resp = await _dio.get('/tutor/vocab', queryParameters: {
        if (language != null && language.isNotEmpty) 'language': language,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '튜터 단어장');
    }
  }

  // --- Graph chat (지식그래프 대화 — 다중 채팅방) -----------------------------

  /// Chat rooms, newest-activity-first. Returns [{id, title, preview, ...}].
  Future<List<Map<String, dynamic>>> listChatSessions() async {
    try {
      final resp = await _dio.get('/graph/chat/sessions');
      return ((resp.data['items'] as List?) ?? [])
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅방 목록');
    }
  }

  Future<Map<String, dynamic>> createChatSession({String? title}) async {
    try {
      final resp = await _dio.post(
        '/graph/chat/sessions',
        data: {if (title != null) 'title': title},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅방 생성');
    }
  }

  Future<Map<String, dynamic>> renameChatSession(String id, String? title) async {
    try {
      final resp = await _dio
          .patch('/graph/chat/sessions/$id', data: {'title': title});
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅방 이름 변경');
    }
  }

  Future<void> deleteChatSession(String id) async {
    try {
      await _dio.delete('/graph/chat/sessions/$id');
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅방 삭제');
    }
  }

  /// Messages of a room, oldest-first. Returns {items, total}.
  Future<Map<String, dynamic>> getChatMessages(String id,
      {int limit = 200}) async {
    try {
      final resp = await _dio.get(
        '/graph/chat/sessions/$id/messages',
        queryParameters: {'limit': limit},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '대화 기록');
    }
  }

  /// Send one message; the answer is grounded in the user's journal graph.
  /// Returns {answer, referenced_node_ids, user_message_id, assistant_message_id}.
  Future<Map<String, dynamic>> sendChatMessage(String id, String message) async {
    try {
      final resp = await _dio.post(
        '/graph/chat/sessions/$id/messages',
        data: {'message': message},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '그래프 대화');
    }
  }

  /// Append a non-LLM record (e.g. an inline quiz prompt/result) to a room.
  Future<Map<String, dynamic>> appendChatEvent(
    String id, {
    String role = 'assistant',
    String kind = 'text',
    String content = '',
    List<String> referencedNodeIds = const [],
    Map<String, dynamic>? meta,
  }) async {
    try {
      final resp = await _dio.post(
        '/graph/chat/sessions/$id/events',
        data: {
          'role': role,
          'kind': kind,
          'content': content,
          'referenced_node_ids': referencedNodeIds,
          if (meta != null) 'meta': meta,
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '대화 기록 저장');
    }
  }

  // --- Chat → journal distillation --------------------------------------------

  /// Distill the conversation into a diary draft (user-only new info, dedup-flagged).
  /// Returns {draft_id, sentences:[{text, included, duplicate, matched_statement, ...}]}.
  Future<Map<String, dynamic>> distillDraft(String id) async {
    try {
      final resp = await _dio.post('/graph/chat/sessions/$id/distill/draft');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '대화 정리');
    }
  }

  /// Conversationally rewrite the current draft ("첫 문단 빼줘" 등).
  Future<Map<String, dynamic>> distillRefine(String id, String instruction) async {
    try {
      final resp = await _dio.post(
        '/graph/chat/sessions/$id/distill/refine',
        data: {'instruction': instruction},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '초안 수정');
    }
  }

  /// Persist per-sentence include toggles without re-running the LLM.
  Future<Map<String, dynamic>> updateDistillState(
      String id, List<bool> included) async {
    try {
      final resp = await _dio
          .patch('/graph/chat/sessions/$id/distill', data: {'included': included});
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '초안 상태 저장');
    }
  }

  // --- Composition drill queue (Quiz table — quiz_type=composition) ---------

  /// Batch-generate composition drills into the quiz queue.
  /// [difficulty]: 'easy' | 'normal' | 'hard' — 프롬프트 난이도만 조절.
  Future<Map<String, dynamic>> generateCompositionQuizzes({
    String language = 'english',
    String sourceMode = 'journal',
    int count = 3,
    String difficulty = 'normal',
  }) async {
    return generateQuizGraph(
      'composition',
      language: language,
      sourceMode: sourceMode,
      count: count,
      difficulty: difficulty,
    );
  }

  /// Generation-order (oldest-first) composition quizzes waiting in the queue.
  Future<List<Map<String, dynamic>>> getCompositionQuizQueue({
    String? language,
  }) async {
    try {
      final resp = await listQuizQueueItems(
        queueKind: 'new',
        quizType: 'composition',
        limit: 100,
        order: 'asc',
      );
      final items = (resp['items'] as List?) ?? [];
      final mapped = items
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (language == null || language.isEmpty) return mapped;
      return mapped
          .where((q) =>
              (q['quiz_data']?['language']?.toString() ?? '') == language)
          .toList();
    } on DioException catch (e) {
      throw _friendlyError(e, '작문 드릴 큐 조회');
    }
  }

  /// Delete one composition quiz from the queue.
  Future<void> deleteCompositionQuiz(String quizId) async {
    await deleteQuizItem(quizId, permanent: true);
  }

  /// Save a confused expression into the tutor vocabulary.
  Future<void> saveTutorExpression({
    required String expression,
    String meaning = '',
    String example = '',
    String language = 'english',
    String note = '',
    String promptKo = '',
    String userAttempt = '',
  }) async {
    try {
      await _dio.post('/tutor/vocab', data: {
        'expression': expression,
        'meaning': meaning,
        'example': example,
        'language': language,
        'note': note,
        'prompt_ko': promptKo,
        'user_attempt': userAttempt,
      });
    } on DioException catch (e) {
      throw _friendlyError(e, '표현 저장');
    }
  }

  /// Get statement bank expressions for a given language.
  Future<Map<String, dynamic>> getStatementBank(String language) async {
    try {
      final resp = await _dio.get(
        '/vocabularies/statement-bank',
        queryParameters: {'language': language},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, 'Statement 단어장');
    }
  }
}

final apiClient = ApiClient();
