import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

Map<String, String> get _kLangDisplay => {
      'english': tr('kg.langEnglish'),
      'german': tr('kg.langGerman'),
      'korean': tr('kg.langKorean'),
      'japanese': tr('lang.japanese'),
      'chinese': tr('lang.chinese'),
      'spanish': tr('lang.spanish'),
      'french': tr('lang.french'),
      'portuguese': tr('lang.portuguese'),
      'italian': tr('lang.italian'),
      'arabic': tr('lang.arabic'),
      'russian': tr('lang.russian'),
    };

class StatementBankScreen extends StatefulWidget {
  const StatementBankScreen({super.key, required this.language});

  final String language;

  @override
  State<StatementBankScreen> createState() => _StatementBankScreenState();
}

class _StatementBankScreenState extends State<StatementBankScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _confirmReextract(String langLabel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('statementBank.reextractAllTitle')),
        content: Text(
          tr('statementBank.reextractAllBody', {'lang': langLabel}),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
            child: Text(tr('vocabHub.deleteAndReextract')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _loading = true);
    try {
      final result = await apiClient.deleteAndReextractLanguage(widget.language);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message']?.toString() ?? tr('vocabHub.reextractStartedSnackbar'))),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('statementBank.failed', {'error': e}))),
        );
      }
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final data = await apiClient.getStatementBank(widget.language);
      final exprs = List<Map<String, dynamic>>.from(
        (data['expressions'] as List? ?? []).whereType<Map>().map(
              (e) => Map<String, dynamic>.from(e),
            ),
      );
      if (mounted) setState(() { _items = exprs; _loading = false; _error = null; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final expression = item['expression']?.toString() ?? '';
    if (expression.isEmpty) return;
    // A merged card can span several origin nodes; deleting removes the word
    // from all of them (else it reappears from a surviving origin).
    final originCount = (item['origins'] as List?)?.length ?? 1;

    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('statementBank.deleteExprTitle')),
            content: Text(
              originCount > 1
                  ? tr('statementBank.deleteExprMultiBody', {
                      'expr': expression,
                      'count': originCount,
                    })
                  : tr('statementBank.deleteExprSingleBody', {'expr': expression}),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.delete'))),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    try {
      // No nodeId → delete from all origins.
      await apiClient.deleteStatementExpression(
        language: widget.language,
        expression: expression,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('statementBank.deletedSnackbar', {'expr': expression}))),
        );
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('statementBank.deleteFailed', {'error': e}))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final langLabel = _kLangDisplay[widget.language] ?? widget.language;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('statementBank.pageTitle', {'lang': langLabel})),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('statementBank.reextractTooltip'),
            onPressed: _loading ? null : () => _confirmReextract(langLabel),
          ),
        ],
      ),
      body: _loading
          ? AppLoadingScreen(message: tr('statementBank.loadingExpr'))
          : RefreshIndicator(
              onRefresh: () => _load(silent: true),
              child: _error != null
                  ? Center(child: Text(_error!))
                  : _items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.translate_outlined,
                          title: tr('statementBank.emptyTitle'),
                          subtitle: tr('statementBank.emptySubtitle'),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.pageH, AppSpacing.md,
                            AppSpacing.pageH, AppSpacing.xxl,
                          ),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (ctx, i) => _ExpressionCard(
                            item: _items[i],
                            onDelete: () => _delete(_items[i]),
                          ),
                        ),
            ),
    );
  }
}

class _ExpressionCard extends StatelessWidget {
  const _ExpressionCard({required this.item, required this.onDelete});

  final Map<String, dynamic> item;
  final VoidCallback onDelete;

  /// Origin nodes for this merged lemma. Falls back to the back-compat single
  /// source fields when the API didn't send an `origins` list.
  List<Map<String, dynamic>> get _origins {
    final raw = item['origins'];
    if (raw is List && raw.isNotEmpty) {
      return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [
      {
        'node_id': item['source_node_id'],
        'node_name': item['source_node_name'],
        'example': item['example'],
      },
    ];
  }

  String _originLabel(Map<String, dynamic> o) {
    final name = o['node_name']?.toString() ?? '';
    if (name.isNotEmpty) return name;
    final id = o['node_id']?.toString() ?? '';
    if (id.isEmpty) return tr('statementBank.unnamedNode');
    return tr('statementBank.nodeIdShort', {'id': id.length > 8 ? id.substring(0, 8) : id});
  }

  @override
  Widget build(BuildContext context) {
    final expr = item['expression']?.toString() ?? '';
    final meaning = item['meaning']?.toString() ?? '';
    final cefr = item['cefr']?.toString() ?? '';
    final origins = _origins;

    // Distinct example sentences across origins (deduped, non-empty).
    final examples = <String>{
      for (final o in origins)
        if ((o['example']?.toString() ?? '').trim().isNotEmpty)
          o['example'].toString().trim(),
    }.toList();
    if (examples.isEmpty) {
      final fallback = item['example']?.toString().trim() ?? '';
      if (fallback.isNotEmpty) examples.add(fallback);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          expr,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                      ),
                      if (origins.length > 1) ...[
                        const SizedBox(width: 6),
                        _SharedBadge(count: origins.length),
                      ],
                      if (cefr.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _CefrBadge(cefr: cefr),
                      ],
                    ],
                  ),
                  if (meaning.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      meaning,
                      style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                    ),
                  ],
                  for (final ex in examples) ...[
                    const SizedBox(height: 4),
                    Text(
                      ex,
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: Colors.blueGrey[600],
                      ),
                    ),
                  ],
                  if (origins.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final o in origins)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.account_tree_outlined, size: 11, color: Colors.grey[500]),
                              const SizedBox(width: 3),
                              Text(
                                _originLabel(o),
                                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, size: 20, color: Colors.grey[500]),
              onPressed: onDelete,
              tooltip: tr('common.delete'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "N곳에서 공유" badge for a lemma extracted from multiple statement nodes.
class _SharedBadge extends StatelessWidget {
  const _SharedBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final color = Colors.indigo.shade400;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        tr('statementBank.sharedBadge', {'count': count}),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _CefrBadge extends StatelessWidget {
  const _CefrBadge({required this.cefr});

  final String cefr;

  Color get _color {
    switch (cefr) {
      case 'A1': return Colors.grey.shade600;
      case 'A2': return Colors.green.shade600;
      case 'B1': return Colors.teal.shade600;
      case 'B2': return Colors.blue.shade600;
      case 'C1': return Colors.purple.shade600;
      case 'C2': return Colors.red.shade700;
      default:   return Colors.grey.shade400;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _color.withValues(alpha: 0.5)),
      ),
      child: Text(
        cefr,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _color),
      ),
    );
  }
}
