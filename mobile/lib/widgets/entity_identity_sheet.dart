import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Result of resolving a mentioned entity during graph draft review.
class EntityIdentityResult {
  const EntityIdentityResult({
    required this.action,
    this.nodeId,
    this.linkedName,
    this.isSelf = false,
  });

  /// ``new_person`` | ``concept`` | ``link``
  final String action;
  final String? nodeId;
  final String? linkedName;
  final bool isSelf;
}

class EntityPersonCandidate {
  const EntityPersonCandidate({
    required this.id,
    required this.name,
    this.isSelf = false,
  });

  final String id;
  final String name;
  final bool isSelf;

  factory EntityPersonCandidate.fromRaw(dynamic raw) {
    final m = raw is Map ? raw : const {};
    return EntityPersonCandidate(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      isSelf: m['is_self'] == true,
    );
  }
}

/// PiP-style identity picker for graph-review entity mentions.
Future<EntityIdentityResult?> showEntityIdentitySheet({
  required BuildContext context,
  required String entityName,
  required List<EntityPersonCandidate> candidates,
  String? suggestedNodeId,
  String? suggestedName,
  String? currentAction,
  String? currentNodeId,
}) {
  return showGeneralDialog<EntityIdentityResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '정체성 선택 닫기',
    barrierColor: Colors.black.withValues(alpha: 0.38),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, _, __) {
      return SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xl,
            ),
            child: _EntityIdentityPiPCard(
              entityName: entityName,
              candidates: candidates,
              suggestedNodeId: suggestedNodeId,
              suggestedName: suggestedName,
              currentAction: currentAction,
              currentNodeId: currentNodeId,
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.04, 0.06),
            end: Offset.zero,
          ).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            alignment: Alignment.bottomRight,
            child: child,
          ),
        ),
      );
    },
  );
}

class _EntityIdentityPiPCard extends StatelessWidget {
  const _EntityIdentityPiPCard({
    required this.entityName,
    required this.candidates,
    this.suggestedNodeId,
    this.suggestedName,
    this.currentAction,
    this.currentNodeId,
  });

  final String entityName;
  final List<EntityPersonCandidate> candidates;
  final String? suggestedNodeId;
  final String? suggestedName;
  final String? currentAction;
  final String? currentNodeId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxW = MediaQuery.sizeOf(context).width;
    final maxH = MediaQuery.sizeOf(context).height;
    final cardWidth = (maxW * 0.92).clamp(300.0, 400.0);
    final cardMaxHeight = (maxH * 0.62).clamp(320.0, 520.0);

    return Material(
      elevation: 20,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: cardWidth,
          maxHeight: cardMaxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _EntityPiPHeader(
              entityName: entityName,
              onClose: () => Navigator.of(context).pop(),
            ),
            Flexible(
              child: _EntityIdentityPanel(
                entityName: entityName,
                candidates: candidates,
                suggestedNodeId: suggestedNodeId,
                suggestedName: suggestedName,
                currentAction: currentAction,
                currentNodeId: currentNodeId,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntityPiPHeader extends StatelessWidget {
  const _EntityPiPHeader({
    required this.entityName,
    required this.onClose,
  });

  final String entityName;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, 4, AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.accent.withValues(alpha: 0.14),
            scheme.primary.withValues(alpha: 0.06),
          ],
        ),
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.hub_outlined,
              color: AppColors.accent,
              size: 22,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '정체성 확인',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.mutedText,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  entityName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '닫기',
            onPressed: onClose,
            icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

enum _EntityMode { main, pickExisting }

class _EntityIdentityPanel extends StatefulWidget {
  const _EntityIdentityPanel({
    required this.entityName,
    required this.candidates,
    this.suggestedNodeId,
    this.suggestedName,
    this.currentAction,
    this.currentNodeId,
  });

  final String entityName;
  final List<EntityPersonCandidate> candidates;
  final String? suggestedNodeId;
  final String? suggestedName;
  final String? currentAction;
  final String? currentNodeId;

  @override
  State<_EntityIdentityPanel> createState() => _EntityIdentityPanelState();
}

class _EntityIdentityPanelState extends State<_EntityIdentityPanel> {
  _EntityMode _mode = _EntityMode.main;
  String _search = '';

  List<EntityPersonCandidate> get _filtered {
    var list = widget.candidates.where((c) => c.id.isNotEmpty).toList();
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list.where((c) => c.name.toLowerCase().contains(q)).toList();
    }
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  void _pop(EntityIdentityResult result) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(
          key: ValueKey(_mode),
          child: _mode == _EntityMode.main ? _buildMain(context) : _buildPick(context),
        ),
      ),
    );
  }

  Widget _buildMain(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasSuggestion =
        widget.suggestedNodeId != null && (widget.suggestedName ?? '').isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '「${widget.entityName}」은(는) 어떻게 저장할까요?',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.mutedText,
                height: 1.35,
              ),
        ),
        if (hasSuggestion) ...[
          const SizedBox(height: AppSpacing.lg),
          _SuggestionHero(
            name: widget.suggestedName!,
            onConfirm: () => _pop(EntityIdentityResult(
              action: 'link',
              nodeId: widget.suggestedNodeId,
              linkedName: widget.suggestedName,
            )),
          ),
          const SizedBox(height: AppSpacing.md),
          const _OrDivider(),
          const SizedBox(height: AppSpacing.md),
        ],
        _ActionTile(
          icon: Icons.person_add_alt_1_rounded,
          iconColor: scheme.primary,
          label: '새 정체성으로 추가',
          filled: !hasSuggestion,
          onTap: () => _pop(const EntityIdentityResult(action: 'new_person')),
        ),
        const SizedBox(height: AppSpacing.sm),
        _ActionTile(
          icon: Icons.lightbulb_outline_rounded,
          label: '개체가 아니라 개념으로',
          onTap: () => _pop(const EntityIdentityResult(action: 'concept')),
        ),
        if (widget.candidates.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          const _OrDivider(),
          const SizedBox(height: AppSpacing.md),
          Text(
            '기존 정체성',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            decoration: const InputDecoration(
              labelText: '이름 검색',
              hintText: '예: 나, 장덕환',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.search,
            onChanged: (v) => setState(() => _search = v.trim()),
          ),
          if (_filtered.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                shrinkWrap: true,
                children: _filtered.take(8).map((p) {
                  final selected =
                      widget.currentAction == 'link' && widget.currentNodeId == p.id;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    ),
                    leading: Icon(
                      p.isSelf ? Icons.account_circle : Icons.person_outline,
                      size: 20,
                    ),
                    title: Text(p.isSelf ? '${p.name} (본인)' : p.name),
                    subtitle: const Text('지식 그래프에 있는 정체성'),
                    trailing: selected
                        ? const Icon(Icons.check, color: AppColors.accent, size: 18)
                        : null,
                    onTap: () => _pop(EntityIdentityResult(
                      action: 'link',
                      nodeId: p.id,
                      linkedName: p.name,
                      isSelf: p.isSelf,
                    )),
                  );
                }).toList(),
              ),
            ),
          ],
          if (widget.candidates.length > 8)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: OutlinedButton(
                onPressed: () => setState(() => _mode = _EntityMode.pickExisting),
                child: const Text('전체 목록에서 검색'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildPick(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '기존 정체성을 고르세요.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.mutedText,
              ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '이름 검색',
            hintText: '예: 나, 장덕환',
            prefixIcon: Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _search = v.trim()),
        ),
        if (_filtered.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView(
              shrinkWrap: true,
              children: _filtered.map((p) {
                return ListTile(
                  dense: true,
                  leading: Icon(
                    p.isSelf ? Icons.account_circle : Icons.person_outline,
                    size: 20,
                  ),
                  title: Text(p.isSelf ? '${p.name} (본인)' : p.name),
                  onTap: () => _pop(EntityIdentityResult(
                    action: 'link',
                    nodeId: p.id,
                    linkedName: p.name,
                    isSelf: p.isSelf,
                  )),
                );
              }).toList(),
            ),
          ),
        ] else ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            '검색 결과가 없습니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        _BackRow(onBack: () => setState(() => _mode = _EntityMode.main)),
      ],
    );
  }
}

class _SuggestionHero extends StatelessWidget {
  const _SuggestionHero({
    required this.name,
    required this.onConfirm,
  });

  final String name;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.accent.withValues(alpha: 0.12),
            scheme.primary.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: AppColors.accent, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '추천 정체성',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '「$name」와(과) 같은 대상 같아요.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: onConfirm,
            icon: const Icon(Icons.check_rounded, size: 20),
            label: Text('$name 맞아요'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    this.iconColor,
    this.filled = false,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color? iconColor;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = filled
        ? scheme.primaryContainer.withValues(alpha: 0.55)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.45);
    final fg = filled ? scheme.onPrimaryContainer : scheme.onSurface;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 13),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor ?? fg.withValues(alpha: 0.85)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: fg,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: fg.withValues(alpha: 0.4)),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).dividerColor;
    return Row(
      children: [
        Expanded(child: Divider(color: divider)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Text('또는', style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: Divider(color: divider)),
      ],
    );
  }
}

class _BackRow extends StatelessWidget {
  const _BackRow({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onBack,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.arrow_back_rounded,
                size: 20, color: context.mutedText),
            const SizedBox(width: 4),
            Text('뒤로',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: context.mutedText,
                    )),
          ],
        ),
      ),
    );
  }
}
