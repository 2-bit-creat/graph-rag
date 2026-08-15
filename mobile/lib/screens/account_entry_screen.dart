import 'package:flutter/material.dart';

import '../auth/account_controller.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'privacy_policy_screen.dart';

/// First-run / switch screen: pick a saved ID or log into an already-
/// registered one. No password, and — deliberately — no account creation
/// here: a new ID can only be minted from the "main" account's developer
/// tab (AccountsOverviewScreen), so a stray tap on this screen can never
/// spin up a throwaway account. Typing an unregistered handle 404s.
///
/// Laid out as a real sign-in page rather than a debug form: a brand lockup,
/// one bounded card carrying the whole decision (saved IDs first, manual entry
/// under a divider), and a legal footer. The card is what makes it read as a
/// product — the previous version floated a bare TextField on the background,
/// which is the shape of an internal tool.
class AccountEntryScreen extends StatefulWidget {
  const AccountEntryScreen({super.key, this.onEntered});

  /// Called after a successful enter/switch (e.g. to pop back into the app).
  final VoidCallback? onEntered;

  @override
  State<AccountEntryScreen> createState() => _AccountEntryScreenState();
}

class _AccountEntryScreenState extends State<AccountEntryScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _busy = false;

  /// Which saved row is signing in, so its own tile shows the wait instead of
  /// the whole screen going ambiguous.
  String? _pending;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_clearErrorOnEdit);
  }

  @override
  void dispose() {
    _controller.removeListener(_clearErrorOnEdit);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _clearErrorOnEdit() {
    if (_error != null) setState(() => _error = null);
  }

  Future<void> _enter(String handle, {bool fromSaved = false}) async {
    final h = handle.trim().toLowerCase();
    if (h.isEmpty) {
      setState(() => _error = tr('account.emptyHandle'));
      _focusNode.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _pending = fromSaved ? h : null;
      _error = null;
    });
    try {
      // create: false — this screen only ever logs into an account that
      // already exists; an unregistered handle raises here instead of
      // silently creating one (see AccountController.enter's doc).
      await accountController.enter(h, create: false);
      if (mounted) widget.onEntered?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _pending = null;
        });
      }
    }
  }

  Future<void> _forget(String handle) async {
    await accountController.forget(handle);
    if (mounted) setState(() {});
  }

  void _openPrivacyPolicy() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    final saved = accountController.handles;

    return Scaffold(
      backgroundColor: shell.graphBackground,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xxl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _BrandLockup(),
                  const SizedBox(height: AppSpacing.xxl),
                  // Says why they are here, when they were sent back by an
                  // expired token rather than by tapping 계정 전환.
                  if (accountController.sessionExpired) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accentWarm.withValues(alpha: 0.12),
                        borderRadius:
                            BorderRadius.circular(AppSpacing.radiusSm),
                        border: Border.all(
                          color: AppColors.accentWarm.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.schedule_rounded,
                              size: 16, color: AppColors.accentWarm),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              tr('accountEntry.sessionExpired'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  _card(context, saved),
                  const SizedBox(height: AppSpacing.lg),
                  _footer(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, List<String> saved) {
    final shell = context.shell;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: shell.panelBackground,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: shell.panelBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark ? 0.3 : 0.06,
            ),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('account.signInTitle'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: shell.primaryText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            tr('account.signInSubtitle'),
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: shell.mutedText,
            ),
          ),
          if (saved.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            _FieldLabel(text: tr('account.saved')),
            const SizedBox(height: AppSpacing.sm),
            for (final h in saved) ...[
              _SavedAccountTile(
                handle: h,
                busy: _pending == h,
                enabled: !_busy,
                onTap: () => _enter(h, fromSaved: true),
                onForget: () => _forget(h),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: AppSpacing.xs),
            _OrDivider(label: tr('account.orDivider')),
          ],
          const SizedBox(height: AppSpacing.xl),
          _FieldLabel(text: tr('account.newId')),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.go,
            onSubmitted: _busy ? null : (v) => _enter(v),
            style: TextStyle(color: shell.primaryText),
            decoration: InputDecoration(
              hintText: tr('account.idPlaceholder'),
              hintStyle: TextStyle(color: shell.mutedText),
              prefixIcon:
                  Icon(Icons.person_outline_rounded, size: 20, color: shell.mutedText),
              filled: true,
              fillColor: shell.subtleSurface,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: 15,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                borderSide: BorderSide(color: shell.panelBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                borderSide: BorderSide(color: shell.panelBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                borderSide:
                    const BorderSide(color: AppColors.hubGraph, width: 1.6),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            tr('account.hint'),
            style: TextStyle(fontSize: 11.5, color: shell.mutedText),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            _ErrorBanner(message: _error!),
          ],
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            onPressed: _busy ? null : () => _enter(_controller.text),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              ),
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            child: _busy && _pending == null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(tr('account.signIn')),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final shell = context.shell;
    return Column(
      children: [
        TextButton(
          onPressed: _openPrivacyPolicy,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: shell.mutedText,
            textStyle: const TextStyle(
              fontSize: 12,
              decoration: TextDecoration.underline,
            ),
          ),
          child: Text(tr('account.privacyPolicy')),
        ),
        const SizedBox(height: 2),
        Text(
          tr('account.mainHint'),
          textAlign: TextAlign.center,
          style: TextStyle(color: shell.mutedText, fontSize: 11.5, height: 1.4),
        ),
      ],
    );
  }
}

/// Flat monogram + wordmark — the same brand mark the sidebar carries, so the
/// first screen and the app agree on what this product looks like.
class _BrandLockup extends StatelessWidget {
  const _BrandLockup();

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.hubGraph,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Text(
            'D',
            style: TextStyle(
              color: Colors.white,
              fontSize: 27,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          tr('app.title'),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: shell.primaryText,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          tr('account.brandTagline'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: shell.mutedText, height: 1.4),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
        color: context.shell.mutedText,
      ),
    );
  }
}

/// One saved handle as a full-width row: tap anywhere to sign in, and the
/// remove control is a separate, smaller target so it can't be hit by accident.
class _SavedAccountTile extends StatelessWidget {
  const _SavedAccountTile({
    required this.handle,
    required this.busy,
    required this.enabled,
    required this.onTap,
    required this.onForget,
  });

  final String handle;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Material(
      color: shell.subtleSurface,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: AppColors.hubGraph.withValues(alpha: 0.15),
                child: Text(
                  handle.isNotEmpty ? handle[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: AppColors.hubGraph,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      handle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: shell.primaryText,
                      ),
                    ),
                    Text(
                      tr('account.savedOnDevice'),
                      style: TextStyle(fontSize: 11.5, color: shell.mutedText),
                    ),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: tr('account.forget'),
                  visualDensity: VisualDensity.compact,
                  onPressed: enabled ? onForget : null,
                  icon: Icon(Icons.close_rounded, size: 18, color: shell.mutedText),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final shell = context.shell;
    return Row(
      children: [
        Expanded(child: Divider(height: 1, color: shell.panelBorder)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            label,
            style: TextStyle(fontSize: 11.5, color: shell.mutedText),
          ),
        ),
        Expanded(child: Divider(height: 1, color: shell.panelBorder)),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    const tone = Color(0xFFE05252);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, size: 17, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12.5, height: 1.4, color: tone),
            ),
          ),
        ],
      ),
    );
  }
}
