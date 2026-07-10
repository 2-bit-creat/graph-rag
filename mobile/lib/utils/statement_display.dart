import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Parsed Statement node payload — never show raw JSON to the user.
class ParsedStatement {
  const ParsedStatement({this.contextType, required this.content});

  final String? contextType;
  final String content;

  bool get hasContextType =>
      contextType != null && contextType!.isNotEmpty && contextType != '미분류';
}

bool isStatementNode(Map<String, dynamic> node) =>
    (node['type'] as String? ?? '').toLowerCase() == 'statement';

/// Extract human-readable context type + body from a Statement node.
ParsedStatement parseStatementFromNode(Map<String, dynamic> node) {
  if (!isStatementNode(node)) {
    return ParsedStatement(content: node['description']?.toString().trim() ?? '');
  }

  final topContent = node['content']?.toString().trim();
  if (topContent != null && topContent.isNotEmpty) {
    return ParsedStatement(
      contextType: node['context_type']?.toString().trim(),
      content: topContent,
    );
  }

  final desc = node['description']?.toString().trim() ?? '';
  if (desc.startsWith('{')) {
    try {
      final map = (jsonDecode(desc) as Map).cast<String, dynamic>();
      return ParsedStatement(
        contextType: (map['context_type'] as String?)?.trim(),
        content: (map['content'] as String?)?.trim() ?? '',
      );
    } catch (_) {}
  }

  final parts = desc.split('\n');
  if (parts.length > 1) {
    final ctx = parts.first.trim();
    return ParsedStatement(
      contextType: ctx.isEmpty ? null : ctx,
      content: parts.sublist(1).join('\n').trim(),
    );
  }

  return ParsedStatement(content: desc);
}

String buildStatementDescription(String contextType, String content) =>
    jsonEncode({'context_type': contextType, 'content': content});

Color contextTypeColor(String? type, {Brightness brightness = Brightness.light}) {
  final fallback = brightness == Brightness.dark
      ? AppColors.textMutedDark
      : AppColors.textMuted;
  return switch (type) {
    '대화' => AppColors.hubGraph,
    '회의록' => const Color(0xFF6366F1),
    '독백' => AppColors.accentWarm,
    '자료' => AppColors.hubVoice,
    _ => fallback,
  };
}

/// Small pill for context_type (대화, 회의록, …).
class StatementContextBadge extends StatelessWidget {
  const StatementContextBadge({super.key, required this.label, this.compact = false});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = contextTypeColor(
      label,
      brightness: Theme.of(context).brightness,
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: compact ? 10 : 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
