import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../auth/account_controller.dart';
import '../l10n/languages.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

/// Account administration for the reserved "main" space: every account on the
/// server + a rough DB-usage proxy (row counts, not disk bytes), plus create,
/// switch, and delete.
///
/// Reached only from [MenuScreen] while signed in as main (the server 403s
/// every other handle). Never surface this on an unauthenticated screen such
/// as the account entry screen — it enumerates every handle on the server.
///
/// This is the only place a handle is minted: the entry screen just takes an
/// id, which is why it no longer asks for a native language.
class AccountsOverviewScreen extends StatefulWidget {
  const AccountsOverviewScreen({super.key});

  @override
  State<AccountsOverviewScreen> createState() => _AccountsOverviewScreenState();
}

class _AccountsOverviewScreenState extends State<AccountsOverviewScreen> {
  List<Map<String, dynamic>> _accounts = [];
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
      final accounts = await apiClient.getAccountsOverview();
      if (mounted) setState(() { _accounts = accounts; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createAccount() async {
    final result = await showDialog<({String handle, String native})>(
      context: context,
      builder: (ctx) => const _CreateAccountDialog(),
    );
    if (result == null) return;
    try {
      // Provision only — main stays signed in as main. Switching here would
      // strand the admin in the space they just created; the new id is
      // entered from the login screen instead.
      await apiClient.createAccount(
        handle: result.handle,
        nativeLanguage: result.native,
      );
      _toast('계정 "${result.handle}"을(를) 만들었어요');
      await _load();
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Switch the app into [handle]. The account-keyed root shell has to remount
  /// under the new account, so pop back to it rather than leaving this screen
  /// stacked on top.
  Future<void> _switchTo(String handle) async {
    try {
      await accountController.enter(handle, create: false);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _deleteAccount(Map<String, dynamic> account) async {
    final handle = account['handle']?.toString() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('"$handle" 계정을 삭제할까요?'),
        content: Text(
          '일기 ${account['journal_count'] ?? 0}개 · 노드 ${account['node_count'] ?? 0}개 · '
          '채팅방 ${account['chat_session_count'] ?? 0}개가 모두 지워지고, 되돌릴 수 없어요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await apiClient.deleteAccountByHandle(handle);
      // Drop the saved token/handle too, so the entry screen stops offering a
      // space that no longer exists.
      await accountController.forget(handle);
      _toast('계정 "$handle"을(를) 삭제했어요');
      await _load();
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('계정 개요'),
        actions: [
          IconButton(
            tooltip: '새 계정 만들기',
            onPressed: _createAccount,
            icon: const Icon(Icons.person_add_alt_1_rounded),
          ),
          IconButton(
            tooltip: '새로고침',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const AppLoadingScreen()
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 36),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('다시 시도')),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageH, AppSpacing.md, AppSpacing.pageH, AppSpacing.xxl,
                  ),
                  itemCount: _accounts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, i) {
                    final account = _accounts[i];
                    final handle = account['handle']?.toString() ?? '';
                    final isCurrent = handle == accountController.current;
                    return _AccountCard(
                      account: account,
                      isCurrent: isCurrent,
                      // main administers the others and cannot delete itself;
                      // switching into the account you are already in is a no-op.
                      onSwitch: isCurrent ? null : () => _switchTo(handle),
                      onDelete: (account['is_main'] == true || isCurrent)
                          ? null
                          : () => _deleteAccount(account),
                    );
                  },
                ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.isCurrent,
    this.onSwitch,
    this.onDelete,
  });

  final Map<String, dynamic> account;
  final bool isCurrent;

  /// Null when the action does not apply — switching into the current account,
  /// or deleting main / the account in use.
  final VoidCallback? onSwitch;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final handle = account['handle']?.toString() ?? '?';
    final createdAt = DateTime.tryParse(account['created_at']?.toString() ?? '');
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: isCurrent
            ? Border.all(color: scheme.primary.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.hubGraph.withValues(alpha: 0.15),
                child: Text(handle.isNotEmpty ? handle[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: AppColors.hubGraph, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(handle,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (account['is_main'] == true) _Badge(label: 'main', color: AppColors.hubGraph),
              if (isCurrent) ...[
                const SizedBox(width: 6),
                _Badge(label: '현재 계정', color: scheme.primary),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _Stat(label: '일기', value: account['journal_count']),
              _Stat(label: '노드', value: account['node_count']),
              _Stat(label: '채팅방', value: account['chat_session_count']),
            ],
          ),
          if (createdAt != null) ...[
            const SizedBox(height: 8),
            Text('가입 ${DateFormat('yyyy.MM.dd').format(createdAt.toLocal())}',
                style: TextStyle(fontSize: 11, color: context.shell.mutedText)),
          ],
          if (onSwitch != null || onDelete != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (onSwitch != null)
                  TextButton.icon(
                    onPressed: onSwitch,
                    icon: const Icon(Icons.login_rounded, size: 16),
                    label: const Text('이 계정으로 전환'),
                  ),
                const Spacer(),
                if (onDelete != null)
                  TextButton.icon(
                    onPressed: onDelete,
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    label: const Text('삭제'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final dynamic value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 11.5, color: context.shell.mutedText)),
      ],
    );
  }
}

/// The only place a brand-new account ID can be minted — deliberately not
/// reachable from the plain (unauthenticated) entry screen. Pops
/// `(handle, native)` on confirm, `null` on cancel.
class _CreateAccountDialog extends StatefulWidget {
  const _CreateAccountDialog();

  @override
  State<_CreateAccountDialog> createState() => _CreateAccountDialogState();
}

class _CreateAccountDialogState extends State<_CreateAccountDialog> {
  final _controller = TextEditingController();
  String? _native;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final handle = _controller.text.trim().toLowerCase();
    if (handle.isEmpty) {
      setState(() => _error = '아이디를 입력하세요.');
      return;
    }
    if (_native == null) {
      setState(() => _error = '모국어를 선택하세요.');
      return;
    }
    Navigator.of(context).pop((handle: handle, native: _native!));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('새 계정 만들기'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '아이디',
              helperText: '3–20자 영문·숫자',
            ),
          ),
          const SizedBox(height: 16),
          const Text('모국어',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 4),
          const Text(
            '그래프·번역·설명의 기준 언어이며, 만든 뒤에는 변경할 수 없습니다.',
            style: TextStyle(fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: AppSpacing.sm,
            children: kNativeLanguages
                .map((lang) => ChoiceChip(
                      label: Text(lang.label),
                      selected: _native == lang.key,
                      onSelected: (_) => setState(() {
                        _native = lang.key;
                        _error = null;
                      }),
                    ))
                .toList(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: TextStyle(color: Colors.red.shade300, fontSize: 12.5)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('만들기'),
        ),
      ],
    );
  }
}
