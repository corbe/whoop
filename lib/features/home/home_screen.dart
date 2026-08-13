/// Home placeholder (Phase 1+2). Shows the resolved WellnessPerson identity.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../services/wellness_identity_providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authServiceProvider);
    final identity = auth.currentIdentity;
    final personAsync = ref.watch(currentWellnessPersonProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Noana Wellness'),
        actions: [
          IconButton(
            icon: const Icon(Icons.groups_outlined),
            tooltip: 'Comunidades',
            onPressed: () => context.go('/communities'),
          ),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Chat diagnóstico',
            onPressed: () => context.go('/chat/diagnostic'),
          ),
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
            const SizedBox(height: 16),
            personAsync.when(
              loading: () => const CircularProgressIndicator(strokeWidth: 2),
              error: (e, _) => Text(
                'WellnessPerson indisponível: $e',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              data: (person) => person == null
                  ? const Text('Bootstrap pendente…')
                  : Column(
                      children: [
                        Text(
                          person.displayName.isEmpty
                              ? 'WellnessPerson ${person.uuid.substring(0, 8)}'
                              : person.displayName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'cognito_sub: ${person.cognitoSub}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
