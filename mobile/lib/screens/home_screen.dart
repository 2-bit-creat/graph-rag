import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/quiz_profile_card.dart';
import 'journal_compose_screen.dart';
import 'journal_hub_screen.dart';
import 'kg_build_screen.dart';
import 'knowledge_graph_screen.dart';
import 'quiz_pipeline_hub_screen.dart';
import 'quiz_session_screen.dart';
import 'settings_screen.dart';
import 'vocabulary_hub_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _summary;
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      Map<String, dynamic>? summary;
      Map<String, dynamic>? profile;
      try {
        summary = await apiClient.graphSummary();
      } catch (_) {}
      try {
        profile = await apiClient.getQuizProfile();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _summary = summary;
          _profile = profile;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.toString();
        });
      }
    }
  }

  Future<void> _openCompose() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const JournalComposeScreen(),
      ),
    );
    _load(silent: true);
  }

  Future<void> _openJournalHub() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const JournalHubScreen()),
    );
    _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, AppColors.accent],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            const Text('MyLife English'),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Dev',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '설정',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              _load(silent: true);
            },
          ),
        ],
      ),
      body: _loading
          ? const AppLoadingScreen(message: '학습 데이터 불러오는 중…')
          : RefreshIndicator(
              onRefresh: () => _load(silent: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageH,
                  AppSpacing.md,
                  AppSpacing.pageH,
                  AppSpacing.xxl,
                ),
                children: [
                  if (_loadError != null) ...[
                    Card(
                      color: colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Text('$_loadError'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  const AppHeroHeader(
                    title: '오늘의 일상을 영어로',
                    subtitle: '일기를 쓰고, 지식을 쌓고 퀴즈로 복습하세요',
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  QuizProfileCard(
                    compact: true,
                    initialProfile: _profile,
                    onUpdated: (p) => setState(() => _profile = p),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  const AppSectionHeader(
                    title: '일기',
                    subtitle: '음성 또는 텍스트 — 같은 일기, 입력 방식만 다름',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppPrimaryBanner(
                    icon: Icons.edit_note_rounded,
                    title: '일기 쓰기',
                    subtitle: '음성 녹음·파일 업로드, 또는 텍스트 입력',
                    actionLabel: '시작',
                    actionIcon: Icons.arrow_forward_rounded,
                    onTap: _openCompose,
                    color: AppColors.primary,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppHubTile(
                    icon: Icons.auto_stories_outlined,
                    title: '내 일기',
                    subtitle: '번역 · 화자 확인 · 파이프라인 trace',
                    color: AppColors.accent,
                    onTap: _openJournalHub,
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  const AppSectionHeader(
                    title: '나의 지식',
                    subtitle: '내가 모아 둔 단어 · 사람과 관계',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppHubTile(
                    icon: Icons.menu_book_rounded,
                    title: '단어장',
                    subtitle: '커스텀 단어장 관리 · 일기에서 추가',
                    color: AppColors.accentWarm,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const VocabularyHubScreen()),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppHubTile(
                    icon: Icons.add_chart_outlined,
                    title: '지식 소스 등록',
                    subtitle: '한국어 텍스트 → 화자 지정 → 그래프 적재',
                    color: AppColors.hubGraph,
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const KgBuildScreen()),
                      );
                      _load(silent: true);
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppHubTile(
                    icon: Icons.hub_outlined,
                    title: '지식 그래프',
                    subtitle: _graphSubtitle(),
                    color: AppColors.hubGraph,
                    badge: _graphBadge(),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const KnowledgeGraphScreen(),
                        ),
                      );
                      _load(silent: true);
                    },
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  const AppSectionHeader(
                    title: '학습',
                    subtitle: '큐에 쌓인 문제로 연습',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const _PracticeQuizRow(),
                  const SizedBox(height: AppSpacing.xxl),
                  const AppSectionHeader(
                    title: '개발자 도구',
                    subtitle: '내부 디버깅 전용 — 일반 사용자 흐름과 분리',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppHubTile(
                    icon: Icons.quiz_outlined,
                    title: '문제 생성',
                    subtitle: '지식 그래프 · Quiz Path trace',
                    color: AppColors.hubQuiz,
                    badge: 'Dev',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const QuizPipelineHubScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  String _graphSubtitle() {
    final nodes = _summary?['node_count'] ?? 0;
    final edges = _summary?['edge_count'] ?? 0;
    if (nodes == 0) return '노드·관계 탐색';
    return '노드 $nodes · 관계 $edges';
  }

  String? _graphBadge() {
    final nodes = _summary?['node_count'];
    if (nodes is num && nodes > 0) return '$nodes';
    return null;
  }
}

class _PracticeQuizRow extends StatelessWidget {
  const _PracticeQuizRow();

  static const _types = [
    (type: 'cloze', icon: Icons.spellcheck_rounded, label: '단어 완성', color: AppColors.hubQuiz),
    (type: 'scramble', icon: Icons.reorder_rounded, label: '문장 배열', color: AppColors.hubVoice),
    (type: 'mcq_nuance', icon: Icons.psychology_alt_rounded, label: '뉘앙스 선택', color: AppColors.accentWarm),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final t in _types) ...[
          AppHubTile(
            icon: t.icon,
            title: t.label,
            subtitle: '큐에서 문제 풀기',
            color: t.color,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => QuizSessionScreen(quizType: t.type),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}
