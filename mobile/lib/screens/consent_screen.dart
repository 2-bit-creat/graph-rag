import 'package:flutter/material.dart';

import '../api/client.dart';
import '../auth/account_controller.dart';
import '../l10n/app_strings.dart';
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
        _loadError = tr('consent.loadError');
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
            tr('consent.title'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: shell.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr('consent.intro'),
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
                  Icon(Icons.info_outline_rounded,
                      size: 18, color: shell.mutedText),
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
            title: tr('consent.requiredTitle'),
            subtitle: tr('consent.requiredSubtitle'),
          ),
          _ConsentTile(
            value: _agreeSpeaker,
            onChanged: (v) => setState(() => _agreeSpeaker = v),
            title: tr('consent.speakerOptionalTitle'),
            subtitle: tr('consent.speakerOptionalSubtitle'),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
            ),
            icon: const Icon(Icons.description_outlined, size: 18),
            label: Text(tr('consent.viewFullPolicy')),
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
                : Text(tr('consent.agreeAndStart')),
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
        FilledButton.tonal(onPressed: onRetry, child: Text(tr('kg.retry'))),
      ],
    );
  }
}
