import 'package:flutter/material.dart';

import '../api/client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Renders the server-served privacy policy. Uses a lightweight line-based
/// renderer (headings / notes / table rows / body) so we need no markdown
/// dependency; the raw text stays selectable.
class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  bool _loading = true;
  String? _error;
  String _markdown = '';
  String _version = '';

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
      final policy = await apiClient.getPrivacyPolicy(
        language: appLocaleController.locale,
      );
      if (!mounted) return;
      setState(() {
        _markdown = policy['content_markdown']?.toString() ?? '';
        _version = policy['version']?.toString() ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = tr('privacyPolicy.loadFailed');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Scaffold(
      backgroundColor: shell.graphBackground,
      appBar: AppBar(
        title: Text(tr('privacyPolicy.pageTitle')),
        bottom: _version.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                      tr('privacyPolicy.versionLabel', {'version': _version}),
                      style: TextStyle(color: shell.mutedText, fontSize: 12)),
                ),
              ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(tr('common.retry')),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                  child: SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _renderLines(shell),
                    ),
                  ),
                ),
    );
  }

  List<Widget> _renderLines(AppShellTheme shell) {
    final widgets = <Widget>[];
    for (final raw in _markdown.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        widgets.add(const SizedBox(height: 8));
      } else if (line.startsWith('# ')) {
        widgets.add(_para(
            line.substring(2), shell.primaryText, 20, FontWeight.w800,
            top: 4));
      } else if (line.startsWith('## ')) {
        widgets.add(_para(
            line.substring(3), shell.primaryText, 16, FontWeight.w700,
            top: 14));
      } else if (line.startsWith('> ')) {
        widgets.add(_para(
            line.substring(2), shell.mutedText, 12.5, FontWeight.w400,
            italic: true));
      } else if (line.startsWith('|')) {
        widgets.add(
            _para(line, shell.mutedText, 11.5, FontWeight.w400, mono: true));
      } else {
        widgets.add(_para(line, shell.primaryText, 13.5, FontWeight.w400));
      }
    }
    return widgets;
  }

  Widget _para(
    String text,
    Color color,
    double size,
    FontWeight weight, {
    double top = 2,
    bool italic = false,
    bool mono = false,
  }) {
    final base = TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: 1.5,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      fontFamily: mono ? 'monospace' : null,
    );
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 2),
      // Table rows are already monospaced on purpose — leave their pipes and
      // backticks byte-for-byte rather than reflowing them as inline markup.
      child: mono
          ? Text(text, style: base)
          : Text.rich(TextSpan(children: _inlineSpans(text, base)),
              style: base),
    );
  }

  /// The line renderer above handles block syntax (`#`, `>`, tables) but used
  /// to emit every line as literal text, so the policy's inline `**bold**` and
  /// `` `code` `` markers were shown to the reader verbatim — the legal copy
  /// arrived looking like unrendered source. This walks the two inline forms
  /// the served document actually uses and turns them into real styling.
  static final _inlinePattern = RegExp(r'\*\*(.+?)\*\*|`(.+?)`', dotAll: true);

  static List<InlineSpan> _inlineSpans(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in _inlinePattern.allMatches(text)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      final bold = m.group(1);
      spans.add(
        bold != null
            ? TextSpan(
                text: bold,
                style: const TextStyle(fontWeight: FontWeight.w700),
              )
            : TextSpan(
                text: m.group(2),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: base.fontSize == null ? null : base.fontSize! - 0.5,
                ),
              ),
      );
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }
}
