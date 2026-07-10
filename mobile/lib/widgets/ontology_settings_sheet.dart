import 'package:flutter/material.dart';

import '../api/client.dart';
import '../utils/graph_layout.dart';
import ../theme/app_theme.dart

class OntologySettingsSheet extends StatefulWidget {
  const OntologySettingsSheet({super.key, this.onApplied});

  final VoidCallback? onApplied;

  static Future<void> show(
    BuildContext context, {
    VoidCallback? onApplied,
    // onFilterByType kept for call-site compatibility but unused
    void Function(String typeName)? onFilterByType,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => OntologySettingsSheet(onApplied: onApplied),
    );
  }

  @override
  State<OntologySettingsSheet> createState() => _OntologySettingsSheetState();
}

class _OntologySettingsSheetState extends State<OntologySettingsSheet> {
  Map<String, dynamic>? _ontology;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final ontology = await apiClient.getOntology();
      if (mounted) {
        setState(() {
          _ontology = ontology;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('온톨로지 로드 실패: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        if (_loading) {
          return const Center(child: CircularProgressIndicator());
        }

        final entityTypes = (_ontology?['entity_types'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final relations = (_ontology?['relation_types'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
        final typeColors = buildTypeColorMap(_ontology?['entity_types'] as List<dynamic>?);

        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('온톨로지 설정', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'GraphRAG 추출 시 사용하는 엔티티·관계 타입입니다.\n노드 색상은 아래 타입 정의를 따릅니다.',
              style: TextStyle(fontSize: 13, color: context.mutedText),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('현재 온톨로지'),
              subtitle: Text(_ontology?['name']?.toString() ?? '(기본)'),
            ),
            const SizedBox(height: 8),
            Text('엔티티 타입', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...entityTypes.map((et) {
              final name = et['name']?.toString() ?? '';
              final color = typeColors[name] ?? parseHexColor('#64748b');
              return Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(et['description']?.toString() ?? ''),
                ),
              );
            }),
            const SizedBox(height: 12),
            Text('관계 타입', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: relations
                  .map((r) => Chip(label: Text(r, style: const TextStyle(fontSize: 11))))
                  .toList(),
            ),
          ],
        );
      },
    );
  }
}
