import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One existing Concept node the backend suggested this surface form might be.
class ConceptCandidate {
  const ConceptCandidate({
    required this.nodeId,
    required this.name,
    this.distance,
    this.description = '',
  });

  final String nodeId;
  final String name;
  final double? distance;
  final String description;

  factory ConceptCandidate.fromRaw(dynamic raw) {
    final m = raw is Map ? raw : const {};
    return ConceptCandidate(
      nodeId: (m['node_id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      distance: double.tryParse(m['distance']?.toString() ?? ''),
      description: (m['description'] ?? '').toString(),
    );
  }
}

/// Result of reviewing a concept auto-link suggestion.
class ConceptLinkResult {
  const ConceptLinkResult({
    required this.action,
    this.nodeId,
    this.linkedName,
  });

  /// ``link`` — merge into an existing concept · ``keep`` — keep as a new concept.
  final String action;
  final String? nodeId;
  final String? linkedName;
}

/// PiP-style picker to link a plain concept to an existing Concept node during
/// graph draft review. Mirrors [showEntityIdentitySheet] but for 개념↔개념 linking.
Future<ConceptLinkResult?> showConceptLinkSheet({
  required BuildContext context,
  required String conceptName,
  required List<ConceptCandidate> candidates,
  String? currentNodeId,
}) {
  return showGeneralDialog<ConceptLinkResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '개념 연결 닫기',
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
            child: _ConceptLinkCard(
              conceptName: conceptName,
              candidates: candidates,
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

class _ConceptLinkCard extends StatelessWidget {
  const _ConceptLinkCard({
    required this.conceptName,
    required this.candidates,
    this.currentNodeId,
  });

  final String conceptName;
  final List<ConceptCandidate> candidates;
  final String? currentNodeId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxW = MediaQuery.sizeOf(context).width;
    final maxH = MediaQuery.sizeOf(context).height;
    final cardWidth = (maxW * 0.92).clamp(300.0, 400.0);
    final cardMaxHeight = (maxH * 0.62).clamp(320.0, 520.0);

    final valid = candidates.where((c) => c.nodeId.isNotEmpty).toList();
    final best = valid.isNotEmpty ? valid.first : null;
    final rest = valid.length > 1 ? valid.sublist(1) : const <ConceptCandidate>[];

    void pop(ConceptLinkResult r) {
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.of(context).pop(r);
    }

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
            _Header(
              conceptName: conceptName,
              onClose: () => Navigator.of(context).pop(),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.xl + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '「$conceptName」와(과) 같은 개념이 이미 있어요. '
                      '연결하면 하나의 노드로 합쳐집니다.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textMuted,
                            height: 1.35,
                          ),
                    ),
                    if (best != null) ...[
                      const SizedBox(height: AppSpacing.lg),
                      _LinkHero(
                        candidate: best,
                        onConfirm: () => pop(ConceptLinkResult(
                          action: 'link',
                          nodeId: best.nodeId,
                          linkedName: best.name,
                        )),
                      ),
                    ],
                    if (rest.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        '다른 후보',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      ...rest.map((c) {
                        final selected = currentNodeId == c.nodeId;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppSpacing.radiusSm),
                          ),
                          leading: const Icon(Icons.lightbulb_outline_rounded,
                              size: 20),
                          title: Text(c.name),
                          subtitle: c.description.isNotEmpty
                              ? Text(
                                  c.description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : const Text('지식 그래프에 있는 개념'),
                          trailing: selected
                              ? const Icon(Icons.check,
                                  color: AppColors.accent, size: 18)
                              : null,
                          onTap: () => pop(ConceptLinkResult(
                            action: 'link',
                            nodeId: c.nodeId,
                            linkedName: c.name,
                          )),
                        );
                      }),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    _KeepTile(
                      onTap: () =>
                          pop(const ConceptLinkResult(action: 'keep')),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.conceptName, required this.onClose});

  final String conceptName;
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
          bottom:
              BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
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
            child: const Icon(Icons.link_rounded,
                color: AppColors.accent, size: 22),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '개념 연결',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  conceptName,
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

class _LinkHero extends StatelessWidget {
  const _LinkHero({required this.candidate, required this.onConfirm});

  final ConceptCandidate candidate;
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
              const Icon(Icons.auto_awesome_rounded,
                  color: AppColors.accent, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '추천 개념',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '기존 개념 「${candidate.name}」와(과) 같은 개념 같아요.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
          if (candidate.description.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              candidate.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: onConfirm,
            icon: const Icon(Icons.link_rounded, size: 20),
            label: Text('「${candidate.name}」에 연결'),
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

class _KeepTile extends StatelessWidget {
  const _KeepTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 13),
          child: Row(
            children: [
              Icon(Icons.fiber_new_rounded,
                  size: 20, color: scheme.onSurface.withValues(alpha: 0.85)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  '새 개념으로 유지',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: scheme.onSurface.withValues(alpha: 0.4)),
            ],
          ),
        ),
      ),
    );
  }
}
