/// Home placeholder (Phase 1). Real content lands with later phases.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authServiceProvider);
    final identity = auth.currentIdentity;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Noana Wellness'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sair',
            onPressed: () => auth.logout(),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.self_improvement, size: 64, color: Color(0xFF4CAF50)),
            const SizedBox(height: 12),
            Text('Bem-vindo!', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              identity != null ? identity.username : '—',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
