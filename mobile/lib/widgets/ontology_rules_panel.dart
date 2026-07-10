import 'package:flutter/material.dart';

import '../utils/graph_layout.dart';
import '../theme/app_theme.dart';

/// Collapsible ontology rules reference (entity + relation types).
class OntologyRulesPanel extends StatelessWidget {
  const OntologyRulesPanel({
    super.key,
    required this.ontologyName,
    required this.entityTypes,
    required this.relationTypes,
    required this.typeColors,
    this.expanded = false,
    this.onToggle,
    this.onEdit,
  });

  final String ontologyName;
  final List<Map<String, dynamic>> entityTypes;
  final List<String> relationTypes;
  final Map<String, Color> typeColors;
  final bool expanded;
  final VoidCallback? onToggle;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = context.isDarkTheme;
    final panelBg = isDark ? const Color(0xFF111827) : scheme.surfaceContainerLow;
    final titleColor = scheme.onSurface;
    final muted = context.mutedText;
    final chipBg = isDark ? const Color(0xFF1E293B) : scheme.surfaceContainerHighest;
    final chipBorder = scheme.outlineVariant.withValues(alpha: isDark ? 0.55 : 0.65);

    return Material(
      color: panelBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.menu_book_outlined, size: 18, color: muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '온톨로지 규칙 · $ontologyName',
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onEdit != null)
                    TextButton(
                      onPressed: onEdit,
                      style: TextButton.styleFrom(
                        foregroundColor: muted,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('설정', style: TextStyle(fontSize: 11)),
                    ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: muted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            SizedBox(
              height: 120,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                children: [
                  Text(
                    '엔티티 타입 (노드 색상)',
                    style: TextStyle(fontSize: 11, color: muted, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  ...entityTypes.map((et) {
                    final name = et['name']?.toString() ?? '';
                    final color = typeColors[name] ?? parseHexColor('#64748b');
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(top: 3),
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: RichText(
                              text: TextSpan(
                                style: TextStyle(fontSize: 11, color: titleColor, height: 1.3),
                                children: [
                                  TextSpan(
                                    text: '$name  ',
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  TextSpan(
                                    text: et['description']?.toString() ?? '',
                                    style: TextStyle(color: muted, fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  Text(
                    '관계 타입 (엣지 라벨)',
                    style: TextStyle(fontSize: 11, color: muted, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: relationTypes
                        .map(
                          (r) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: chipBg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: chipBorder),
                            ),
                            child: Text(r, style: TextStyle(fontSize: 10, color: muted)),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
