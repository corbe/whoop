/// Root application widget (spec §60 app.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_service.dart';
import 'core/providers.dart';
import 'services/chat_controller.dart';
import 'services/juggle_im_service.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';

class NoanaWellnessApp extends ConsumerStatefulWidget {
  const NoanaWellnessApp({super.key});

  @override
  ConsumerState<NoanaWellnessApp> createState() => _NoanaWellnessAppState();
}

class _NoanaWellnessAppState extends ConsumerState<NoanaWellnessApp> {
  StreamSubscription<AuthStatus>? _authSub;

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
      auth.initialize();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
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
