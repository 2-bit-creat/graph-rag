import 'package:flutter/material.dart';

import '../auth/account_controller.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// First-run / switch screen: pick a saved ID or enter a new one. No password.
class AccountEntryScreen extends StatefulWidget {
  const AccountEntryScreen({super.key, this.onEntered});

  /// Called after a successful enter/switch (e.g. to pop back into the app).
  final VoidCallback? onEntered;

  @override
  State<AccountEntryScreen> createState() => _AccountEntryScreenState();
}

class _AccountEntryScreenState extends State<AccountEntryScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _enter(String handle) async {
    final h = handle.trim().toLowerCase();
    if (h.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await accountController.enter(h);
      if (mounted) widget.onEntered?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(String handle) async {
    await accountController.forget(handle);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final saved = accountController.handles;

    return Scaffold(
      backgroundColor: shell.graphBackground,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.hub_rounded, size: 44, color: AppColors.hubGraph),
                const SizedBox(height: 16),
                Text(
                  tr('account.title'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: shell.primaryText),
                ),
                const SizedBox(height: 8),
                Text(
                  tr('account.welcome'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: shell.mutedText, height: 1.4),
                ),
                const SizedBox(height: 24),
                if (saved.isNotEmpty) ...[
                  Text(tr('account.saved'),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: shell.mutedText)),
                  const SizedBox(height: 8),
                  for (final h in saved)
                    Card(
                      color: shell.panelBackground,
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.hubGraph.withValues(alpha: 0.15),
                          child: Text(h.isNotEmpty ? h[0].toUpperCase() : '?',
                              style: TextStyle(color: AppColors.hubGraph)),
                        ),
                        title: Text(h,
                            style: TextStyle(color: shell.primaryText)),
                        trailing: IconButton(
                          icon: Icon(Icons.close_rounded,
                              size: 18, color: shell.mutedText),
                          tooltip: tr('account.forget'),
                          onPressed: _busy ? null : () => _forget(h),
                        ),
                        onTap: _busy ? null : () => _enter(h),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _controller,
                  enabled: !_busy,
                  autocorrect: false,
                  textInputAction: TextInputAction.go,
                  onSubmitted: _busy ? null : _enter,
                  decoration: InputDecoration(
                    labelText: tr('account.newId'),
                    helperText: tr('account.hint'),
                    filled: true,
                    fillColor: shell.subtleSurface,
                    border: const OutlineInputBorder(),
                  ),
                  style: TextStyle(color: shell.primaryText),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(color: Colors.red.shade300, fontSize: 12.5)),
                ],
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : () => _enter(_controller.text),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(tr('account.enter')),
                ),
                const SizedBox(height: 16),
                Text(
                  tr('account.mainHint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: shell.mutedText, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
