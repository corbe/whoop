/// App routing (spec §60 core/routing).
///
/// go_router with an auth guard: unauthenticated users are redirected to
/// `/login`; authenticated users cannot reach `/login`.
///
/// Uses `refreshListenable` so auth changes re-evaluate the redirect on the
/// SAME router instance (creating a new GoRouter on status change would
/// detach the old one from the widget tree).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service.dart';
import '../providers.dart';

import '../../features/auth/login_screen.dart';
import '../../features/chat/chat_diagnostic_screen.dart';
import '../../features/communities/communities_screen.dart';
import '../../features/communities/community_detail_screen.dart';
import '../../features/communities/create_community_screen.dart';
import '../../features/gamification/gamification_screen.dart';
import '../../features/home/home_screen.dart';

/// Mutable auth status shared between the provider and the router redirect.
class RouterAuthStatus extends ChangeNotifier {
  RouterAuthStatus(this._status);

  AuthStatus _status;
  AuthStatus get status => _status;

  void update(AuthStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  // Seed with the restoring state; updates flow in from the stream below.
  final holder = RouterAuthStatus(AuthStatus.restoring);
  ref.onDispose(holder.dispose);

  // Re-evaluate redirects when the auth status changes (same router).
  final sub = ref.listen(authStatusProvider, (prev, next) {
    holder.update(next.valueOrNull ?? AuthStatus.restoring);
  });

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: holder,
    redirect: (context, state) {
      final status = holder.status;
      final loggingIn = state.matchedLocation == '/login';
      if (status == AuthStatus.authenticated) {
        return loggingIn ? '/' : null;
      }
      return loggingIn ? null : '/login';
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/chat/diagnostic',
        builder: (context, state) => const ChatDiagnosticScreen(),
      ),
      GoRoute(
        path: '/gamification',
        builder: (context, state) => const GamificationScreen(),
      ),
      GoRoute(
        path: '/communities',
        builder: (context, state) => const CommunitiesScreen(),
      ),
      GoRoute(
        path: '/communities/create',
        builder: (context, state) => const CreateCommunityScreen(),
      ),
      GoRoute(
        path: '/communities/:uuid',
        builder: (context, state) => CommunityDetailScreen(
          uuid: state.pathParameters['uuid']!,
        ),
      ),
    ],
  );

  ref.onDispose(sub.close);
  return router;
});
