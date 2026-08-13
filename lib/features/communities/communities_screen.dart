/// Communities main section (Phase 4, spec §28).
///
/// Tabs: My Communities / Discover, plus a Create action. Widgets only
/// consume Riverpod providers — never HTTP.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/community_providers.dart';
import '../../shared/models/community.dart';
import 'community_card.dart';

class CommunitiesScreen extends ConsumerStatefulWidget {
  const CommunitiesScreen({super.key});

  @override
  ConsumerState<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

class _CommunitiesScreenState extends ConsumerState<CommunitiesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Comunidades'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Minhas'),
            Tab(text: 'Descobrir'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/communities/create'),
        icon: const Icon(Icons.group_add),
        label: const Text('Criar'),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _CommunityList(
            provider: myCommunitiesProvider,
            empty: 'Você ainda não participa de comunidades.',
          ),
          _CommunityList(
            provider: discoverCommunitiesProvider,
            empty: 'Nenhuma comunidade pública no momento.',
          ),
        ],
      ),
    );
  }
}

class _CommunityList extends ConsumerWidget {
  const _CommunityList({required this.provider, required this.empty});

  final FutureProvider<List<Community>> provider;
  final String empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Falha ao carregar: $e',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
      data: (communities) {
        if (communities.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(empty, textAlign: TextAlign.center),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(provider),
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: communities.length,
            itemBuilder: (context, i) {
              final community = communities[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: CommunityCard(
                  community: community,
                  onTap: () =>
                      context.push('/communities/${community.uuid}'),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
