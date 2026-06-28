import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

/// 학습 레벨 표시·수정 (홈·설정 공용).
class QuizProfileCard extends StatefulWidget {
  const QuizProfileCard({
    super.key,
    this.initialProfile,
    this.compact = false,
    this.onUpdated,
  });

  final Map<String, dynamic>? initialProfile;
  final bool compact;
  final ValueChanged<Map<String, dynamic>>? onUpdated;

  @override
  State<QuizProfileCard> createState() => _QuizProfileCardState();
}

class _QuizProfileCardState extends State<QuizProfileCard> {
  double _level = 10;
  String _cefr = '';
  List<int> _window = [7, 13];
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _applyProfile(widget.initialProfile);
    if (widget.initialProfile == null) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant QuizProfileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialProfile != oldWidget.initialProfile &&
        widget.initialProfile != null &&
        !_dirty) {
      _applyProfile(widget.initialProfile);
    }
  }

  void _applyProfile(Map<String, dynamic>? profile) {
    if (profile == null) return;
    _level = (profile['current_level'] as num?)?.toDouble() ?? 10;
    _cefr = profile['cefr_label']?.toString() ?? '';
    final w = profile['level_window'];
    if (w is List && w.length >= 2) {
      _window = [(w[0] as num).toInt(), (w[1] as num).toInt()];
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final profile = await apiClient.getQuizProfile();
      if (mounted) {
        setState(() {
          _applyProfile(profile);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final profile = await apiClient.updateQuizLevel(_level.round());
      if (mounted) {
        setState(() {
          _applyProfile(profile);
          _dirty = false;
        });
        widget.onUpdated?.call(profile);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('레벨이 저장되었습니다')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const SizedBox(
        height: 100,
        child: AppLoadingScreen(),
      );
    }

    return AppSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      colorScheme.primary.withValues(alpha: 0.2),
                      colorScheme.secondary.withValues(alpha: 0.15),
                    ],
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.school_outlined, color: colorScheme.primary, size: 22),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('학습 프로필', style: Theme.of(context).textTheme.titleSmall),
                    Text(
                      'Lv.${_level.round()} · $_cefr · 윈도우 Lv.${_window[0]}~${_window[1]}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Slider(
            value: _level,
            min: 1,
            max: 100,
            divisions: 99,
            label: 'Lv.${_level.round()}',
            onChanged: _saving
                ? null
                : (v) => setState(() {
                      _level = v;
                      _dirty = true;
                    }),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: (_saving || !_dirty) ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('레벨 저장'),
            ),
          ),
        ],
      ),
    );
  }
}
