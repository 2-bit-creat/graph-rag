import 'package:flutter/material.dart';

import '../api/client.dart';
import '../auth/account_controller.dart';
import '../theme/app_theme.dart';
import 'privacy_policy_screen.dart';

/// Onboarding consent gate. Shown once per account before entering the app:
/// the user accepts the privacy policy (incl. international transfer) and
/// optionally opts in to voice speaker-identification (biometric).
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _loading = true;
  String? _loadError;
  String _policyVersion = '';
  String _aiNotice = '';

  bool _agreeRequired = false;
  bool _agreeSpeaker = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final policy = await apiClient.getPrivacyPolicy();
      final notice = await apiClient.getAiDisclosure();
      if (!mounted) return;
      setState(() {
        _policyVersion = policy['version']?.toString() ?? '';
        _aiNotice = notice;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '약관을 불러오지 못했어요. 네트워크를 확인해 주세요.';
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    if (!_agreeRequired || _policyVersion.isEmpty) return;
    setState(() => _submitting = true);
    try {
      await apiClient.recordConsent(
        version: _policyVersion,
        speakerIdConsent: _agreeSpeaker,
      );
      accountController.markConsented(speakerIdConsent: _agreeSpeaker);
      // The app gate rebuilds to the home shell once markConsented notifies.
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Scaffold(
      backgroundColor: shell.graphBackground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: _loading
                ? const CircularProgressIndicator()
                : _loadError != null
                    ? _ErrorRetry(message: _loadError!, onRetry: _load)
                    : _content(shell),
          ),
        ),
      ),
    );
  }

  Widget _content(AppShellTheme shell) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.privacy_tip_outlined, size: 40, color: AppColors.hubGraph),
          const SizedBox(height: 16),
          Text(
            '개인정보 수집·이용 동의',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: shell.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '일기·대화 내용은 AI 처리를 위해 국외(OpenAI 등)로 전송·위탁됩니다. '
            '자세한 항목·국가·보유기간은 처리방침에서 확인할 수 있어요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: shell.mutedText, height: 1.5, fontSize: 13.5),
          ),
          const SizedBox(height: 20),
          if (_aiNotice.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: shell.subtleSurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.smart_toy_outlined, size: 18, color: shell.mutedText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _aiNotice,
                      style: TextStyle(
                          color: shell.mutedText, fontSize: 12.5, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          _ConsentTile(
            value: _agreeRequired,
            onChanged: (v) => setState(() => _agreeRequired = v),
            title: '[필수] 개인정보 수집·이용 및 국외 이전에 동의합니다.',
            subtitle: '일기·음성·대화 내용의 처리와 국외 위탁을 포함합니다.',
          ),
          _ConsentTile(
            value: _agreeSpeaker,
            onChanged: (v) => setState(() => _agreeSpeaker = v),
            title: '[선택] 음성 화자 식별(성문) 처리에 동의합니다.',
            subtitle: '대화 속 화자를 구분합니다. 생체정보로, 동의하지 않아도 이용에 제한이 없습니다.',
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
            ),
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('개인정보 처리방침 전체 보기'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: (_agreeRequired && !_submitting) ? _submit : null,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('동의하고 시작'),
          ),
        ],
      ),
    );
  }
}

class _ConsentTile extends StatelessWidget {
  const _ConsentTile({
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      title,
                      style: TextStyle(
                          color: shell.primaryText,
                          fontWeight: FontWeight.w600,
                          fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: shell.mutedText, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton.tonal(onPressed: onRetry, child: const Text('다시 시도')),
      ],
    );
  }
}
