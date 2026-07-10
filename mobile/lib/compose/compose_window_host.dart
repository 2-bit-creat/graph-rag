import 'package:flutter/material.dart';

import '../api/client.dart';
import '../app_navigator.dart';
import '../screens/graph_review_screen.dart';
import '../screens/journal_hub_screen.dart' show JournalEntryDetailScreen;
import '../theme/app_theme.dart';
import '../widgets/journal_audio_compose_panel.dart';
import '../widgets/journal_user_detail_panel.dart';
import '../widgets/precision_text_labeling_panel.dart';
import 'compose_session_controller.dart';

/// 작성 창 내부의 중첩 내비게이터 — 상세 패널이 밀어 올리는 화면(그래프 검토 등)과
/// 다이얼로그가 창 안에서 열리게 한다. 오버레이는 앱 Navigator의 형제라서
/// 이 키가 없으면 Navigator.of()가 실패한다.
final _windowNavKey = GlobalKey<NavigatorState>();

/// 일기 작성 창 오버레이 호스트 — MaterialApp.builder에서 Navigator 위에 얹는다.
///
/// 확대(윈도우 창) ↔ 최소화(우하단 미니 카드) 두 상태를 가지며, 최소화 중에도
/// 창 내용을 트리에 유지해(Offstage 대신 opacity/scale) 녹음기·작성 중 텍스트가
/// 살아 있다. AI 대기가 시작되면 컨트롤러가 자동 최소화한다.
class ComposeWindowHost extends StatefulWidget {
  const ComposeWindowHost({super.key});

  @override
  State<ComposeWindowHost> createState() => _ComposeWindowHostState();
}

class _ComposeWindowHostState extends State<ComposeWindowHost> {
  ComposeWindowState _lastWindow = ComposeWindowState.hidden;

  @override
  void initState() {
    super.initState();
    composeSession.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    composeSession.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    final now = composeSession.window;
    if (now == ComposeWindowState.minimized &&
        _lastWindow == ComposeWindowState.expanded) {
      // 창이 접힐 때 창 안 입력의 포커스가 남아 키보드가 떠 있지 않도록.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => FocusManager.instance.primaryFocus?.unfocus(),
      );
    }
    _lastWindow = now;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: composeSession,
      builder: (context, _) {
        final s = composeSession;
        if (!s.isActive) return const SizedBox.shrink();
        final expanded = s.window == ComposeWindowState.expanded;

        return Stack(
          children: [
            // ── 확대 창 ──────────────────────────────────────────────────
            // 최소화 시 Offstage로 상태(입력 텍스트·녹음·타이머)를 유지하되 페인트는
            // 하지 않는다. 확대 시엔 Transform/Opacity 같은 합성 레이어를 두지 않아,
            // Flutter 웹 텍스트 필드가 네이티브 속도로 동작하고 캐럿이 정상 렌더된다.
            // (합성 레이어 아래 텍스트 입력은 웹에서 랙·캐럿 글리치를 유발.)
            Positioned.fill(
              child: Offstage(
                offstage: !expanded,
                child: TickerMode(
                  enabled: expanded,
                  child: const _ExpandedWindow(),
                ),
              ),
            ),

            // ── 우하단 미니 카드 ─────────────────────────────────────────
            if (!expanded)
              Positioned(
                right: AppSpacing.md,
                bottom: MediaQuery.of(context).padding.bottom + 92,
                child: const _MiniWindowCard(),
              ),
          ],
        );
      },
    );
  }
}

// ─── 확대 창 ──────────────────────────────────────────────────────────────────

class _ExpandedWindow extends StatelessWidget {
  const _ExpandedWindow();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        // 스크림 — 탭하면 최소화(닫기 아님: 내용 보존).
        Positioned.fill(
          child: GestureDetector(
            onTap: composeSession.minimize,
            child: Container(color: Colors.black.withValues(alpha: 0.45)),
          ),
        ),
        // Positioned.fill → 창이 화면 폭을 꽉 채우는 tight 제약을 받는다. 없으면
        // Stack의 비배치 자식이 loose(무한폭) 제약을 받아 타이틀바 Row의 Expanded가
        // 터진다(RenderFlex overflow).
        Positioned.fill(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Material(
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                color: scheme.surface,
                elevation: 12,
                child: Column(
                  children: [
                    const _WindowTitleBar(),
                    Expanded(
                      // 중첩 Navigator는 본문에 Overlay(텍스트 선택·다이얼로그)를
                      // 제공한다. HeroControllerScope.none으로 루트와의 컨트롤러
                      // 공유(assertion)를 끊는다 — 창 내부 hero 전환은 불필요.
                      child: HeroControllerScope.none(
                        child: Navigator(
                          key: _windowNavKey,
                          onGenerateRoute: (settings) => MaterialPageRoute(
                            settings: settings,
                            builder: (_) => const _WindowRootPage(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WindowTitleBar extends StatelessWidget {
  const _WindowTitleBar();

  Future<void> _handleClose() async {
    // 엔트리가 이미 만들어졌으면 잃을 입력이 없다 — 미저장 초안만 확인.
    if (composeSession.dirty && composeSession.entryId == null) {
      final ctx = _windowNavKey.currentContext;
      if (ctx != null) {
        final leave = await showDialog<bool>(
          context: ctx,
          builder: (dialogCtx) => AlertDialog(
            title: const Text('작성 중인 기록이 있어요'),
            content: const Text('지금 닫으면 저장되지 않은 내용이 사라집니다.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('계속 작성'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: const Text('닫기'),
              ),
            ],
          ),
        );
        if (leave != true) return;
      }
    }
    composeSession.close();
  }

  void _openFullScreen() {
    final id = composeSession.entryId;
    if (id == null) return;
    // 오버레이는 루트 Navigator 위에 그려지므로 먼저 접고 나서 push한다.
    composeSession.minimize();
    appNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => JournalEntryDetailScreen(entryId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: composeSession,
      builder: (context, _) {
        final hasEntry = composeSession.entryId != null;
        return Container(
          height: 48,
          padding:
              const EdgeInsets.only(left: AppSpacing.lg, right: AppSpacing.xs),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          child: Row(
            children: [
              Icon(
                hasEntry
                    ? Icons.auto_stories_outlined
                    : Icons.edit_note_rounded,
                size: 20,
                color: scheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  hasEntry ? '내 일기' : '일기 쓰기',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 타이틀바는 창 본문 Navigator 밖이라 Overlay 조상이 없다 → tooltip
              // (Overlay 필요)을 쓰지 않는다. 아이콘 자체로 의미가 명확.
              if (hasEntry)
                IconButton(
                  icon: const Icon(Icons.open_in_full_rounded, size: 18),
                  onPressed: _openFullScreen,
                ),
              IconButton(
                icon: const Icon(Icons.remove_rounded, size: 20),
                onPressed: composeSession.minimize,
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: _handleClose,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── 창 루트 페이지: 작성 UI ↔ 엔트리 상세 ───────────────────────────────────

class _WindowRootPage extends StatelessWidget {
  const _WindowRootPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: composeSession,
        builder: (context, _) {
          final entry = composeSession.entry;
          final entryId = composeSession.entryId;
          final working = composeSession.phase == ComposePhase.working;
          final status = entry?['status']?.toString() ?? '';
          final showProcessing = working &&
              (entry == null ||
                  status == 'processing' ||
                  status == 'graph_processing');
          final Widget child;
          if (showProcessing) {
            // 버퍼링 중 확대 → 편집 폼(이전 텍스트 오인)이나 stale 엔트리가 아니라
            // 명확한 처리 중 화면을 보여준다. 중복 제출도 방지.
            child = _ComposeProcessingView(key: const ValueKey('processing'));
          } else if (entry != null && entryId != null) {
            child = JournalUserDetailPanel(
              key: ValueKey('detail-$entryId'),
              entryId: entryId,
              entry: entry,
              onRefresh: ({bool silent = false}) =>
                  composeSession.refreshEntry(silent: silent),
            );
          } else {
            child = const _ComposeBody(key: ValueKey('compose'));
          }
          return AnimatedSwitcher(
              duration: const Duration(milliseconds: 220), child: child);
        },
      ),
    );
  }
}

/// 버퍼링(정제 등 AI 대기) 중 창을 확대했을 때 보여주는 처리 중 화면.
class _ComposeProcessingView extends StatelessWidget {
  const _ComposeProcessingView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: AppSpacing.lg),
            AnimatedBuilder(
              animation: composeSession,
              builder: (context, _) => Text(
                composeSession.stageLabel.isEmpty
                    ? '처리 중'
                    : composeSession.stageLabel,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '잠시만요 — 끝나면 정제된 일기를 보여드릴게요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 작성 입력 UI — 기존 JournalComposeScreen 본문을 창 안으로 옮긴 것.
class _ComposeBody extends StatefulWidget {
  const _ComposeBody({super.key});

  @override
  State<_ComposeBody> createState() => _ComposeBodyState();
}

class _ComposeBodyState extends State<_ComposeBody> {
  JournalInputMode _inputMode = JournalInputMode.voice;
  bool _creatingText = false;
  bool _voiceDirty = false;
  bool _textDirty = false;

  void _syncDirty() => composeSession.setDirty(_voiceDirty || _textDirty);

  Future<void> _submitText(
    String paragraphText, {
    String? attributionKind,
    String? attributionName,
  }) async {
    if (_creatingText) return;
    setState(() => _creatingText = true);
    try {
      await composeSession.submitText(
        paragraphText,
        attributionKind: attributionKind,
        attributionName: attributionName,
      );
      _textDirty = false;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _creatingText = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageH,
            AppSpacing.md,
            AppSpacing.pageH,
            AppSpacing.sm,
          ),
          child: SegmentedButton<JournalInputMode>(
            segments: const [
              ButtonSegment(
                value: JournalInputMode.voice,
                icon: Icon(Icons.mic_rounded, size: 18),
                label: Text('음성'),
              ),
              ButtonSegment(
                value: JournalInputMode.text,
                icon: Icon(Icons.edit_note_rounded, size: 18),
                label: Text('텍스트'),
              ),
            ],
            selected: {_inputMode},
            onSelectionChanged: (value) {
              if (value.isEmpty) return;
              setState(() => _inputMode = value.first);
            },
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: switch (_inputMode) {
              JournalInputMode.voice => JournalAudioComposePanel(
                  key: const ValueKey('voice'),
                  // 창 전환은 컨트롤러가 주도 — 콜백은 레거시 호환용.
                  onEntryCreated: (_) {},
                  onDirtyChanged: (d) {
                    _voiceDirty = d;
                    _syncDirty();
                  },
                ),
              JournalInputMode.text => SingleChildScrollView(
                  key: const ValueKey('text'),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageH,
                    0,
                    AppSpacing.pageH,
                    AppSpacing.xxl,
                  ),
                  child: PrecisionTextLabelingPanel(
                    onSubmit: _submitText,
                    busy: _creatingText,
                    onDirtyChanged: (d) {
                      _textDirty = d;
                      _syncDirty();
                    },
                  ),
                ),
            },
          ),
        ),
      ],
    );
  }
}

// ─── 우하단 미니 카드 ─────────────────────────────────────────────────────────

class _MiniWindowCard extends StatelessWidget {
  const _MiniWindowCard();

  /// 그래프 초안이 준비된 상태에서 미니 카드를 탭했을 때 — 확정 버튼이 있는
  /// 중간 패널을 거치지 않고 창을 펼치며 곧바로 검토 화면(GraphReviewScreen)을
  /// 창 내부 Navigator에 얹는다. 초안(graph_staging)을 먼저 받아온 뒤 펼치므로
  /// 패널이 잠깐 번쩍이지 않는다.
  Future<void> _openGraphReview() async {
    final id = composeSession.entryId;
    if (id == null) {
      composeSession.expand();
      return;
    }
    Map<String, dynamic> fresh;
    try {
      fresh = await apiClient.getEntry(id);
    } catch (_) {
      // 초안 조회 실패 — 그냥 창을 펼쳐 현재 상태(재시도 등)를 보여준다.
      composeSession.expand();
      return;
    }
    final staging = fresh['graph_staging'];
    if (staging is! Map) {
      // 드래프트가 사라졌으면(이미 확정 등) 검토할 게 없다 — 패널로 펼친다.
      composeSession.expand();
      return;
    }
    composeSession.expand();
    final nav = _windowNavKey.currentState;
    if (nav == null) return;
    final committed = await nav.push<bool>(
      MaterialPageRoute(
        builder: (_) => GraphReviewScreen(
          entryId: id,
          staging: Map<String, dynamic>.from(staging),
        ),
      ),
    );
    // 확정을 눌러 세션이 커밋을 인수했다면(applyGraph → phase=working) 아직 백엔드는
    // graph_staging_ready 상태라, 여기서 새로고침하면 방금 세운 버퍼링(working)을
    // '검토 필요'(needsInput)로 되돌려 미니 카드가 잘못 표시된다. 그 경우는 건너뛴다.
    if (composeSession.phase != ComposePhase.working) {
      await composeSession.refreshEntry(silent: true);
    }
    if (committed == true) {
      final ctx = _windowNavKey.currentContext;
      if (ctx != null && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('지식그래프 확정 완료')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 자체 AnimatedBuilder 필수 — 이 위젯은 부모(ComposeWindowHost)에서 const로
    // 삽입되므로, 부모 AnimatedBuilder가 notifyListeners로 리빌드해도 Flutter가
    // 동일한 const 인스턴스라 보고 build를 다시 호출하지 않는다. 그러면 최초
    // working(스피너) 상태에서 멈춰 정제가 끝나도 계속 버퍼링만 돈다. 형제인
    // _WindowTitleBar·_WindowRootPage처럼 여기서 직접 세션을 구독해야 phase
    // 변화가 반영된다.
    return AnimatedBuilder(
      animation: composeSession,
      builder: (context, _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = composeSession;

    final (Widget leading, String label, String hint) = switch (s.phase) {
      ComposePhase.composing => s.recording
          ? (
              const _PulsingDot(color: AppColors.hubRecord),
              '녹음 중',
              '탭하여 돌아가기',
            )
          : (
              Icon(Icons.edit_note_rounded, size: 20, color: scheme.primary),
              '일기 작성 중',
              '탭하여 돌아가기',
            ),
      ComposePhase.working => (
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
          s.stageLabel,
          'AI 처리 중 · 기다리는 동안 자유롭게 쓰세요',
        ),
      ComposePhase.needsInput => (
          const Icon(Icons.touch_app_rounded,
              size: 20, color: AppColors.accentWarm),
          s.stageLabel,
          '탭하여 계속하기',
        ),
      ComposePhase.done => (
          Icon(Icons.check_circle_rounded, size: 20, color: Colors.green[600]),
          s.stageLabel,
          '탭하여 확인하기',
        ),
      ComposePhase.error => (
          Icon(Icons.error_rounded, size: 20, color: Colors.red[600]),
          s.stageLabel,
          '탭하여 다시 시도',
        ),
    };

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      color: scheme.surface,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      child: InkWell(
        onTap: (s.phase == ComposePhase.needsInput && s.isGraphReviewPending)
            ? _openGraphReview
            : composeSession.expand,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          width: 240,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border:
                Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: AppSpacing.sm + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                    ),
                  ],
                ),
              ),
              if (s.phase == ComposePhase.done)
                InkWell(
                  onTap: composeSession.close,
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded,
                        size: 16, color: AppColors.textMuted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 녹음 중 표시용 깜빡이는 점.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_ctrl),
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
