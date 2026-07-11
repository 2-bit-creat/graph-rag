import 'package:flutter/material.dart';

import 'app_navigator.dart';
import 'app_route_observer.dart';
import 'chat/chat_session_controller.dart';
import 'chat/chat_sidebar.dart';
import 'compose/compose_window_host.dart';
import 'l10n/app_strings.dart';
import 'screens/knowledge_graph_screen.dart';
import 'theme/app_theme.dart';
import 'theme/app_theme_controller.dart';
import 'widgets/app_theme_toggle_button.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appThemeController.load();
  await appLocaleController.load();
  runApp(const GraphRagApp());
}

class GraphRagApp extends StatelessWidget {
  const GraphRagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appThemeController, appLocaleController]),
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
          home: const ChatHomeShell(),
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

  bool _chatOpen = true;
  bool _sidebarOpen = true;

  @override
  void initState() {
    super.initState();
    chatSession.init();
  }

  void _toggleSidebar() => setState(() => _sidebarOpen = !_sidebarOpen);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final shell = context.shell;

    final graph = Scaffold(
      backgroundColor: shell.graphBackground,
      appBar: AppBar(
        backgroundColor: shell.appBarBackground,
        foregroundColor: shell.appBarForeground,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: !wide,
        leading: wide
            ? null
            : Builder(
                builder: (ctx) => IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  tooltip: tr('shell.roomsMenu'),
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
        title: ListenableBuilder(
          listenable: chatSession,
          builder: (context, _) {
            final title =
                (chatSession.activeSession?['title'] as String?)?.trim();
            return Text(title?.isNotEmpty == true ? title! : tr('shell.graphChat'));
          },
        ),
        actions: [
          const AppThemeToggleButton(),
          IconButton(
            tooltip: _chatOpen ? tr('shell.collapseChat') : tr('shell.expandChat'),
            icon: Icon(
              _chatOpen
                  ? Icons.chat_bubble_rounded
                  : Icons.chat_bubble_outline_rounded,
              color: _chatOpen ? AppColors.hubGraph : null,
            ),
            onPressed: () => setState(() => _chatOpen = !_chatOpen),
          ),
        ],
      ),
      drawer: wide
          ? null
          : Drawer(
              child: SafeArea(
                child: ChatSidebar(onNavigate: () => Navigator.pop(context)),
              ),
            ),
      body: KnowledgeGraphView(
        chatOpen: _chatOpen,
        onChatOpenChanged: (open) => setState(() => _chatOpen = open),
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
