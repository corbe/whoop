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
      final push = ref.read(pushNotificationServiceProvider);
      _push = push;

      // Um ÚNICO listener de auth cobre os dois efeitos colaterais:
      // (1) troca de conta → reset do estado de chat/Juggle (providers
      //     keepAlive reteriam a sessão do usuário anterior); e
      // (2) push → registro do device no login / desassociação no logout.
      // ATENÇÃO (bug 2026-08-17): antes, o listener de push era registrado
      // com `_authSub ??=` DEPOIS de `_authSub` já atribuído ao listener de
      // chat — nunca era anexado, e onAuthenticated()/onLoggedOut() nunca
      // rodavam (nenhum DeviceFront era criado no backend).
      _authSub = auth.statusStream.listen((status) {
        if (status == AuthStatus.authenticated) {
          push.onAuthenticated();
        } else if (status == AuthStatus.unauthenticated) {
          ref.invalidate(chatControllerProvider);
          ref.invalidate(juggleImServiceProvider);
          push.onLoggedOut();
        }
      });

      // statusStream é broadcast (NÃO re-emite o estado atual a quem dá
      // listen): se a autenticação já tiver ocorrido antes do listener (ex.:
      // restore concluído muito cedo ou reordenação futura do boot), garante
      // o registro mesmo assim. Idempotente no backend (upsert por token).
      if (auth.status == AuthStatus.authenticated) {
        push.onAuthenticated();
      }

      _setupPush(auth, push);
      auth.initialize();
    });
  }

  /// Push: init único + registro no login + desassociação no logout +
  /// deep-links (opened/terminated) com gate de readiness (cold-start).
  void _setupPush(AuthService auth, PushNotificationService push) {
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
