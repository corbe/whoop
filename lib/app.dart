/// Root application widget (spec §60 app.dart).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';

class NoanaWellnessApp extends ConsumerStatefulWidget {
  const NoanaWellnessApp({super.key});

  @override
  ConsumerState<NoanaWellnessApp> createState() => _NoanaWellnessAppState();
}

class _NoanaWellnessAppState extends ConsumerState<NoanaWellnessApp> {
  @override
  void initState() {
    super.initState();
    // Restore the persisted session (idempotent; safe to call once here).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authServiceProvider).initialize();
    });
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
