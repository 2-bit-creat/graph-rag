import 'package:flutter/material.dart';

import '../api/client.dart';

class ExamplesScreen extends StatefulWidget {
  const ExamplesScreen({super.key, required this.entryId});
  final String entryId;

  @override
  State<ExamplesScreen> createState() => _ExamplesScreenState();
}

class _ExamplesScreenState extends State<ExamplesScreen> {
  List<dynamic> _examples = [];
  String _preview = '';
  bool _graphUsed = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await apiClient.generateExamples(widget.entryId);
      if (mounted) {
        setState(() {
          _examples = data['examples'] as List<dynamic>? ?? [];
          _preview = data['retrieval_preview']?.toString() ?? '';
          _graphUsed = data['graph_context_used'] == true;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 예문'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('오류: $_error'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: ListTile(
                        leading: Icon(
                          _graphUsed ? Icons.hub : Icons.info_outline,
                          color: _graphUsed ? Colors.green : Colors.grey,
                        ),
                        title: Text(_graphUsed ? 'GraphRAG 참조됨' : 'GraphRAG 없음'),
                        subtitle: Text(
                          _graphUsed
                              ? '지식 그래프 기반 개인화 예문'
                              : '그래프가 비어 있어 일기 내용만 사용했습니다. GraphRAG 생성 후 더 개인화됩니다.',
                        ),
                      ),
                    ),
                    if (_preview.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ExpansionTile(
                        title: const Text('GraphRAG 컨텍스트', style: TextStyle(fontSize: 14)),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(
                              _preview,
                              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text('예문 5개', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ..._examples.map((item) {
                      final ex = item is Map<String, dynamic>
                          ? item
                          : <String, dynamic>{'en': item.toString()};
                      final idx = _examples.indexOf(item);
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${idx + 1}.', style: TextStyle(color: Colors.grey[600])),
                              const SizedBox(height: 4),
                              Text(
                                ex['en']?.toString() ?? '',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if ((ex['ko']?.toString() ?? '').isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  ex['ko'].toString(),
                                  style: TextStyle(color: Colors.grey[700]),
                                ),
                              ],
                              if ((ex['note']?.toString() ?? '').isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  ex['note'].toString(),
                                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
    );
  }
}
