import 'package:flutter/material.dart';

import 'api/client.dart';
import 'app_navigator.dart';
import 'app_route_observer.dart';
import 'auth/account_controller.dart';
import 'chat/chat_session_controller.dart';
import 'chat/chat_sidebar.dart';
import 'compose/compose_window_host.dart';
import 'l10n/app_strings.dart';
import 'screens/account_entry_screen.dart';
import 'screens/consent_screen.dart';
import 'screens/knowledge_graph_screen.dart';
import 'theme/app_theme.dart';
import 'theme/app_theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appThemeController.load();
  await appLocaleController.load();
  await accountController.load();
  runApp(const GraphRagApp());
}

class GraphRagApp extends StatelessWidget {
  const GraphRagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [appThemeController, appLocaleController, accountController]),
      builder: (context, _) {
        return MaterialApp(
          title: 'MyLife English',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(brightness: Brightness.light),
          darkTheme: buildAppTheme(brightness: Brightness.dark),
          themeMode: appThemeController.mode,
          navigatorKey: appNavigatorKey,
          navigatorObservers: [appRouteObserver],
          builder: (context, child) => Stack(
            children: [
              if (child != null) child,
              const ComposeWindowHost(),
            ],
          ),
          // Gate: pick an account → accept consent → app. Keying the shell by the
          // current handle remounts (fresh chat/profile) when switching accounts.
          home: !accountController.hasAccount
              ? const AccountEntryScreen()
              : !accountController.consentKnown
                  ? const _ConsentLoadingScreen()
                  : accountController.needsConsent
                      ? const ConsentScreen()
                      : ChatHomeShell(key: ValueKey(accountController.current)),
        );
      },
    );
  }
}

// ─── Chat-centric home shell (Claude-style sidebar + graph conversation) ──────

/// The app's single home. The knowledge-graph conversation is the default view;
/// a left sidebar (rail on wide, drawer on narrow) lists chat rooms and links to
/// 기록/메뉴. Journal, quiz, and distillation all launch from inside the chat feed
/// (Phase 4), so there's no bottom navigation anymore.
class ChatHomeShell extends StatefulWidget {
  const ChatHomeShell({super.key});

  @override
  State<ChatHomeShell> createState() => _ChatHomeShellState();
}

class _ChatHomeShellState extends State<ChatHomeShell> {
  static const _wideBreakpoint = 1000.0;
  static const _sidebarExpandedWidth = 260.0;
  static const _sidebarCollapsedWidth = 56.0;

  bool _sidebarOpen = true;
  // No AppBar anymore (the graph is full-bleed with a floating search pill),
  // so the drawer is opened via this key from the pill's hamburger button.
  final _graphScaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    chatSession.init();
    _syncLocaleFromProfile();
  }

  Future<void> _syncLocaleFromProfile() async {
    try {
      final profile = await apiClient.getUserProfile();
      await appLocaleController
          .setFromNativeLanguage(profile['native_language']?.toString());
    } catch (_) {
      // Non-fatal — keep the persisted locale.
    }
  }

  void _toggleSidebar() => setState(() => _sidebarOpen = !_sidebarOpen);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final shell = context.shell;

    // Google-Maps grammar: no AppBar — the graph fills the screen edge to
    // edge and the floating search pill (inside KnowledgeGraphView) carries
    // the hamburger, theme toggle, and overflow actions. The chat-room title
    // now lives in the bottom sheet's header.
    final graph = Scaffold(
      key: _graphScaffoldKey,
      backgroundColor: shell.graphBackground,
      drawer: wide
          ? null
          : Drawer(
              child: SafeArea(
                child: ChatSidebar(onNavigate: () => Navigator.pop(context)),
              ),
            ),
      body: KnowledgeGraphView(
        onOpenMenu: wide
            ? null
            : () => _graphScaffoldKey.currentState?.openDrawer(),
      ),
    );

    if (!wide) return graph;

    final sidebarW =
        _sidebarOpen ? _sidebarExpandedWidth : _sidebarCollapsedWidth;

    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: sidebarW,
            child: Material(
              color: shell.sidebarBackground,
              child: SafeArea(
                child: _sidebarOpen
                    ? ChatSidebar(onCollapse: _toggleSidebar)
                    : ChatSidebarRail(onExpand: _toggleSidebar),
              ),
            ),
          ),
          VerticalDivider(
            width: 1,
            color: Theme.of(context).dividerColor.withValues(alpha: 0.35),
          ),
          Expanded(child: graph),
        ],
      ),
    );
  }
}

/// Brief spinner shown right after login while the account's consent state loads.
class _ConsentLoadingScreen extends StatelessWidget {
  const _ConsentLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
