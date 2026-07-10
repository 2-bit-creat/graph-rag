import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_navigator.dart';
import 'app_route_observer.dart';
import 'auth/device_auth.dart';
import 'chat/chat_session_controller.dart';
import 'chat/chat_sidebar.dart';
import 'l10n/app_localizations.dart';
import 'locale/native_language_controller.dart';
import 'screens/knowledge_graph_screen.dart';
import 'theme/app_theme.dart';
import 'theme/app_theme_controller.dart';
import 'widgets/app_theme_toggle_button.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appThemeController.load();
  final localeController = NativeLanguageController();
  runApp(GraphRagApp(controller: localeController));
}

class GraphRagApp extends StatefulWidget {
  const GraphRagApp({super.key, required this.controller});

  final NativeLanguageController controller;

  @override
  State<GraphRagApp> createState() => _GraphRagAppState();
}

class _GraphRagAppState extends State<GraphRagApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.loadFromProfile();
    ensureDeviceAuth();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, appThemeController]),
      builder: (context, _) {
        return NativeLanguageScope(
          controller: widget.controller,
          child: MaterialApp(
            title: 'MyLife English',
            debugShowCheckedModeBanner: false,
            locale: widget.controller.locale,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: buildAppTheme(brightness: Brightness.light),
            darkTheme: buildAppTheme(brightness: Brightness.dark),
            themeMode: appThemeController.mode,
            navigatorKey: appNavigatorKey,
            navigatorObservers: [appRouteObserver],
            home: const ChatHomeShell(),
          ),
        );
      },
    );
  }
}

// ─── Chat-centric home: graph canvas + conversation panel + room sidebar ───────

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
        backgroundColor: shell.toolbarBackground,
        foregroundColor: shell.graphLabel,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: Colors.transparent,
        leading: wide
            ? IconButton(
                icon: Icon(
                  _sidebarOpen
                      ? Icons.menu_open_rounded
                      : Icons.menu_rounded,
                ),
                tooltip: _sidebarOpen ? '사이드바 접기' : '사이드바 펼치기',
                onPressed: _toggleSidebar,
              )
            : Builder(
                builder: (ctx) => IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  tooltip: '채팅방 · 메뉴',
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
        title: ListenableBuilder(
          listenable: chatSession,
          builder: (context, _) {
            final title =
                (chatSession.activeSession?['title'] as String?)?.trim();
            return Text(title?.isNotEmpty == true ? title! : '그래프 대화');
          },
        ),
        actions: [
          const AppThemeToggleButton(),
          IconButton(
            tooltip: _chatOpen ? '대화 패널 접기' : '대화 패널 펼치기',
            icon: Icon(
              _chatOpen
                  ? Icons.chat_bubble_rounded
                  : Icons.chat_bubble_outline_rounded,
              color: _chatOpen ? AppColors.hubGraph : shell.graphLabel,
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
              color: shell.barBackground,
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
