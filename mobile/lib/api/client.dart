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

  void setAuthToken(String token) {
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  void clearAuthToken() {
    _dio.options.headers.remove('Authorization');
  }

  Future<String> authenticateDevice(String deviceId) async {
    try {
      final resp = await _dio.post('/auth/device', data: {'device_id': deviceId});
      final data = resp.data;
      if (data is Map && data['access_token'] is String) {
        return data['access_token'] as String;
      }
      throw Exception('Device auth: missing access_token');
    } on DioException catch (e) {
      throw _friendlyError(e, '기기 인증');
    }
  }

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
      if (attributionName != null) body['attribution_name'] = attributionName;
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
    String? language,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (isFreedomOn != null) body['is_freedom_on'] = isFreedomOn;
      if (selectedVocabId != null) body['selected_vocab_id'] = selectedVocabId;
      final params = <String, dynamic>{'quiz_type': quizType};
      if (language != null) params['language'] = language;
      final resp = await _dio.post(
        '/journal/entries/$entryId/quiz/generate',
        queryParameters: params,
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
  }) async {
    try {
      final body = <String, dynamic>{};
      if (selectedVocabId != null) body['selected_vocab_id'] = selectedVocabId;
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
  }) async {
    try {
      final resp = await _dio.get('/quiz/queue/items', queryParameters: {
        'queue_kind': queueKind,
        if (quizType != null) 'quiz_type': quizType,
        'limit': limit,
        'offset': offset,
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
    String? language,
  }) async {
    try {
      final resp = await _dio.post('/quiz/session', data: {
        'quiz_type': quizType,
        'size': size,
        if (entryId != null) 'entry_id': entryId,
        if (quizIds != null && quizIds.isNotEmpty) 'quiz_ids': quizIds,
        if (language != null) 'language': language,
      });
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '퀴즈 세션');
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

  Future<Map<String, dynamic>> applyEntryGraph(
    String entryId, {
    required List<Map<String, dynamic>> claims,
    required String contextType,
  }) async {
    try {
      final resp = await _dio.post(
        '/journal/entries/$entryId/graph/apply',
        data: {
          'claims': claims,
          'context_type': contextType,
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '지식그래프 확정');
    }
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

  Future<Map<String, dynamic>> clearGraph() async {
    try {
      final resp = await _dio.delete('/graph');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '지식 그래프 삭제');
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
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '화자 확정');
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

  Future<Map<String, dynamic>> updateNode(
    String nodeId, {
    required String name,
    required String type,
    String? description,
  }) async {
    final resp = await _dio.patch('/graph/nodes/$nodeId', data: {
      'name': name,
      'type': type,
      if (description != null) 'description': description,
    });
    return resp.data as Map<String, dynamic>;
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

  /// Update active target language (legacy single-value field on profile).
  Future<void> updateActiveTargetLanguage(String language) async {
    try {
      await _dio.patch('/quiz/profile/settings', data: {
        'target_language': language,
      });
    } on DioException catch (e) {
      throw _friendlyError(e, '학습 언어 저장');
    }
  }

  /// Generate composition quizzes in batch.
  Future<Map<String, dynamic>> generateCompositionQuizzes({
    required String language,
    int count = 3,
    String difficulty = 'normal',
    String sourceMode = 'journal',
  }) async {
    try {
      final resp = await _dio.post(
        '/quiz/generate',
        queryParameters: {
          'quiz_type': 'composition',
          'language': language,
        },
        data: {
          'count': count,
          'difficulty': difficulty,
          'source_mode': sourceMode,
        },
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '문장 문제 생성');
    }
  }

  /// List pending composition quizzes in the new queue.
  Future<List<Map<String, dynamic>>> getCompositionQuizQueue() async {
    try {
      final resp = await _dio.get(
        '/quiz/queue/items',
        queryParameters: {
          'queue_kind': 'new',
          'quiz_type': 'composition',
        },
      );
      final data = resp.data as Map<String, dynamic>;
      final items = data['items'];
      if (items is! List) return [];
      return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on DioException catch (e) {
      throw _friendlyError(e, '문장 문제 대기열');
    }
  }

  /// Update target languages list (multi-select).
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
  Future<void> deleteStatementExpression({
    required String nodeId,
    required String language,
    required String expression,
  }) async {
    try {
      await _dio.delete(
        '/vocabularies/statement-bank/expressions',
        queryParameters: {
          'node_id': nodeId,
          'language': language,
          'expression': expression,
        },
      );
    } on DioException catch (e) {
      throw _friendlyError(e, '표현 삭제');
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

  // ─── Graph chat sessions ───────────────────────────────────────────────────

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
      throw _friendlyError(e, '튜터 표현 저장');
    }
  }

  Future<int> saveTutorExpressionsBatch(
      List<Map<String, dynamic>> items) async {
    try {
      final resp = await _dio.post('/tutor/vocab/batch', data: {'items': items});
      final data = resp.data;
      if (data is Map && data['saved'] is num) {
        return (data['saved'] as num).toInt();
      }
      return items.length;
    } on DioException catch (e) {
      throw _friendlyError(e, '튜터 표현 일괄 저장');
    }
  }

  /// List expressions saved in the tutor vocabulary. Returns {items, total}.
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
      throw _friendlyError(e, '튜터 표현 삭제');
    }
  }

  Future<String> tutorChat({
    required List<Map<String, String>> messages,
    required String language,
    String? drillPrompt,
  }) async {
    try {
      final resp = await _dio.post('/tutor/chat', data: {
        'messages': messages,
        'language': language,
        if (drillPrompt != null && drillPrompt.isNotEmpty)
          'drill_prompt': drillPrompt,
      });
      final data = resp.data;
      if (data is Map && data['answer'] != null) {
        return data['answer'].toString();
      }
      return '';
    } on DioException catch (e) {
      throw _friendlyError(e, '튜터 대화');
    }
  }

  Future<void> remapSpeakers(
    String entryId, {
    Map<String, String>? groupMap,
  }) async {
    try {
      await _dio.post('/journal/entries/$entryId/speakers/remap', data: {
        if (groupMap != null) 'group_map': groupMap,
      });
    } on DioException catch (e) {
      throw _friendlyError(e, '화자 합치기');
    }
  }

  Future<List<dynamic>> listChatSessions() async {
    try {
      final resp = await _dio.get('/graph/chat/sessions');
      final data = resp.data as Map<String, dynamic>;
      return (data['sessions'] as List?) ?? [];
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅방 목록');
    }
  }

  Future<Map<String, dynamic>> createChatSession({String? title}) async {
    try {
      final resp = await _dio.post(
        '/graph/chat/sessions',
        data: title != null ? {'title': title} : {},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅방 생성');
    }
  }

  Future<Map<String, dynamic>> renameChatSession(String id, String title) async {
    try {
      final resp = await _dio.patch(
        '/graph/chat/sessions/$id',
        data: {'title': title},
      );
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

  Future<Map<String, dynamic>> getChatMessages(String sessionId) async {
    try {
      final resp = await _dio.get('/graph/chat/sessions/$sessionId/messages');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅 기록');
    }
  }

  Future<Map<String, dynamic>> sendChatMessage(
    String sessionId,
    String message,
  ) async {
    try {
      final resp = await _dio.post(
        '/graph/chat/sessions/$sessionId/messages',
        data: {'message': message},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅 전송');
    }
  }

  Future<void> appendChatEvent(
    String sessionId, {
    required String role,
    required String kind,
    required String content,
    Map<String, dynamic>? meta,
  }) async {
    try {
      await _dio.post(
        '/graph/chat/sessions/$sessionId/events',
        data: {
          'role': role,
          'kind': kind,
          'content': content,
          if (meta != null) 'meta': meta,
        },
      );
    } on DioException catch (e) {
      throw _friendlyError(e, '채팅 이벤트 저장');
    }
  }

  Future<Map<String, dynamic>> distillDraft(String sessionId) async {
    try {
      final resp = await _dio.post('/graph/chat/sessions/$sessionId/distill/draft');
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '대화 정리');
    }
  }

  Future<Map<String, dynamic>> distillRefine(
    String sessionId,
    String instruction,
  ) async {
    try {
      final resp = await _dio.post(
        '/graph/chat/sessions/$sessionId/distill/refine',
        data: {'instruction': instruction},
      );
      return resp.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _friendlyError(e, '대화 정리 수정');
    }
  }

  Future<void> updateDistillState(
    String sessionId,
    List<bool> included,
  ) async {
    try {
      await _dio.patch(
        '/graph/chat/sessions/$sessionId/distill',
        data: {'included': included},
      );
    } on DioException catch (e) {
      throw _friendlyError(e, '대화 정리 상태');
    }
  }
}

final apiClient = ApiClient();
