import 'package:flutter/material.dart';

import '../api/client.dart';

class RoleplayScreen extends StatefulWidget {
  const RoleplayScreen({super.key});

  @override
  State<RoleplayScreen> createState() => _RoleplayScreenState();
}

class _RoleplayScreenState extends State<RoleplayScreen> {
  Map<String, dynamic>? _scenario;
  bool _loading = true;
  final _topicController = TextEditingController(text: 'daily conversation');

  Future<void> _generate() async {
    setState(() => _loading = true);
    try {
      final data = await apiClient.roleplay(topic: _topicController.text);
      if (mounted) setState(() { _scenario = data; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 롤플레이')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _topicController,
                  decoration: const InputDecoration(labelText: 'Topic', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _generate, child: const Text('새 시나리오 생성')),
                if (_scenario != null) ...[
                  const SizedBox(height: 16),
                  _Block(title: 'Scenario', content: _scenario!['scenario'] ?? ''),
                  _Block(title: 'Your Role', content: _scenario!['your_role'] ?? ''),
                  _Block(title: 'Partner', content: _scenario!['partner_role'] ?? ''),
                  _Block(title: 'Opening Line', content: _scenario!['opening_line'] ?? '', highlight: true),
                  if (_scenario!['vocabulary'] is List) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final v in _scenario!['vocabulary'] as List)
                          Chip(label: Text(v.toString())),
                      ],
                    ),
                  ],
                ],
              ],
            ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.content, this.highlight = false});
  final String title;
  final String content;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: highlight
                  ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(content),
          ),
        ],
      ),
    );
  }
}
