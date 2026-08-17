/// Root application widget (spec §60 app.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_service.dart';
import 'core/providers.dart';
import 'features/notifications/deep_link.dart';
import 'features/notifications/deep_link_router.dart';
import 'services/chat_controller.dart';
import 'services/juggle_im_service.dart';
import 'services/push_notification_service.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';

class NoanaWellnessApp extends ConsumerStatefulWidget {
  const NoanaWellnessApp({super.key});

  @override
  ConsumerState<NoanaWellnessApp> createState() => _NoanaWellnessAppState();
}

class _NoanaWellnessAppState extends ConsumerState<NoanaWellnessApp> {
  StreamSubscription<AuthStatus>? _authSub;
  PushNotificationService? _push;
  DeepLinkRouter? _deepLinkRouter;

  @override
  void initState() {
    super.initState();
    // Restore the persisted session (idempotent; safe to call once here).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = ref.read(authServiceProvider);
      // Reset completo do estado de chat/Juggle na troca de conta: os
      // providers são keepAlive e reteriam a sessão do usuário anterior
      // (mensagens do lado errado após logout/login — ver BUG ownership).
      _authSub = auth.statusStream.listen((status) {
        if (status == AuthStatus.unauthenticated) {
          ref.invalidate(chatControllerProvider);
          ref.invalidate(juggleImServiceProvider);
        }
      });

      _setupPush(auth);
      auth.initialize();
    });
  }

  /// Push: init único + registro no login + desassociação no logout +
  /// deep-links (opened/terminated) com gate de readiness (cold-start).
  void _setupPush(AuthService auth) {
    final push = ref.read(pushNotificationServiceProvider);
    _push = push;
    final router = ref.read(routerProvider);

    // Gate de sessão: espera o restore (idempotente — initialize já roda no
    // initState). Sem sessão restaurada em 10s → não navega (seguro).
    Future<void> waitForSessionRestore() async {
      try {
        await auth.initialize().timeout(const Duration(seconds: 10));
      } catch (_) {
        // sessão ausente/restore falhou — deep link não navega
      }
    }

    _deepLinkRouter = DeepLinkRouter(
      waitForSessionRestore: waitForSessionRestore,
      waitForWellnessBootstrap: () async {
        // Bootstrap wellness é lazy (providers carregam nas telas); o gate
        // existe para futura rigidez — hoje não há work adicional.
      },
      waitForRouterReady: () async {},
      navigate: (link) async {
        final path = _pathFor(link);
        if (path != null) {
          router.go(path);
        }
      },
    );

    push.onOpenLink = (link) async {
      await _deepLinkRouter?.handle(link);
    };
    push.init();

    // Registro/desassociação seguem o status de autenticação (JWT no backend
    // define a associação do device — troca de conta nunca vaza notificação).
    _authSub ??= auth.statusStream.listen((status) {
      if (status == AuthStatus.authenticated) {
        push.onAuthenticated();
      } else if (status == AuthStatus.unauthenticated) {
        push.onLoggedOut();
      }
    });
  }

  /// Mapeia o deep link para a rota go_router existente (spec push §17).
  /// Rotas dedicadas de desafio/detalhe de convite não existem ainda —
  /// caem no hub de gamificação / detalhe da comunidade.
  String? _pathFor(NotificationDeepLink link) {
    switch (link.type) {
      case DeepLinkType.community:
        return '/communities/${link.targetId}';
      case DeepLinkType.communityInvite:
        final communityUuid = link.extras['community_uuid']?.toString();
        return communityUuid == null || communityUuid.isEmpty
            ? null
            : '/communities/$communityUuid';
      case DeepLinkType.challenge:
      case DeepLinkType.achievement:
        return '/gamification';
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _push?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'RITMA',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
