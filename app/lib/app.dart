import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_state.dart';
import 'core/theme.dart';
import 'features/auth/claim_screen.dart';
import 'features/auth/forgot_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/register_screen.dart';
import 'features/child/child_screens.dart';
import 'features/family/device_link_screen.dart';
import 'features/family/home_screen.dart';
import 'features/family/link_card_screen.dart';
import 'features/family/members_screen.dart';
import 'features/family/player_screen.dart';
import 'features/family/rules_screen.dart';
import 'features/game/lobby_screen.dart';
import 'features/game/new_game_screen.dart';
import 'features/game/results_screen.dart';
import 'features/game/terminal_screen.dart';

const _public = {'/login', '/register', '/claim', '/forgot'};

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<AuthState>(ref.read(authProvider));
  ref.listen(authProvider, (_, next) => refresh.value = next);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: ref.read(servicesProvider).navigatorKey,
    refreshListenable: refresh,
    initialLocation: '/',
    redirect: (context, state) {
      final auth = refresh.value;
      final path = state.matchedLocation;
      return switch (auth) {
        AuthLoading() => path == '/splash' ? null : '/splash',
        LoggedOut() => _public.contains(path) ? null : '/login',
        ChildSession() => path.startsWith('/child') ? null : '/child',
        AdultSession() => (_public.contains(path) || path == '/splash' || path.startsWith('/child')) ? '/' : null,
      };
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const Scaffold(body: Center(child: CircularProgressIndicator()))),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
      GoRoute(path: '/forgot', builder: (_, _) => const ForgotScreen()),
      GoRoute(path: '/claim', builder: (_, _) => const ClaimScreen()),
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/rules', builder: (_, _) => const RulesScreen()),
      GoRoute(path: '/members', builder: (_, _) => const MembersScreen()),
      GoRoute(path: '/player/:id', builder: (_, s) => PlayerScreen(playerId: s.pathParameters['id']!)),
      GoRoute(path: '/player/:id/card', builder: (_, s) => LinkCardScreen(playerId: s.pathParameters['id']!)),
      GoRoute(path: '/player/:id/device', builder: (_, s) => DeviceLinkScreen(playerId: s.pathParameters['id']!)),
      GoRoute(path: '/game/new', builder: (_, _) => const NewGameScreen()),
      GoRoute(path: '/game/:id/lobby', builder: (_, s) => LobbyScreen(sessionId: s.pathParameters['id']!)),
      GoRoute(path: '/game/:id/terminal', builder: (_, s) => TerminalScreen(sessionId: s.pathParameters['id']!)),
      GoRoute(path: '/game/:id/results', builder: (_, s) => ResultsScreen(sessionId: s.pathParameters['id']!)),
      GoRoute(path: '/child', builder: (_, _) => const ChildHomeScreen()),
      GoRoute(path: '/child/transfer', builder: (_, _) => const ChildTransferScreen()),
      GoRoute(path: '/child/history', builder: (_, _) => const ChildHistoryScreen()),
    ],
  );
});

class FantikPayApp extends ConsumerWidget {
  const FantikPayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: 'ФантикПэй',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: ref.watch(routerProvider),
      );
}
