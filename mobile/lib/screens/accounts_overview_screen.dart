import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/client.dart';
import '../auth/account_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

/// Dev-tools-only: every account on the server + a rough DB-usage proxy (row
/// counts, not disk bytes). Reached exclusively from [MenuScreen]'s
/// authenticated 개발자 도구 section — never surface this on an
/// unauthenticated screen (e.g. the account entry screen), since it
/// enumerates every handle on the server.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('계정 개요'),
        actions: [
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
                  itemBuilder: (context, i) => _AccountCard(
                    account: _accounts[i],
                    isCurrent: _accounts[i]['handle'] == accountController.current,
                  ),
                ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.isCurrent});

  final Map<String, dynamic> account;
  final bool isCurrent;

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
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('현재 계정',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary)),
                ),
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
        ],
      ),
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
