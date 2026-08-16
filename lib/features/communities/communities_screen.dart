/// Communities main section (Phase 4, spec §28).
///
/// Tabs: My Communities / Discover, plus a Create action. Widgets only
/// consume Riverpod providers — never HTTP.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ui/noana_widgets.dart';
import '../../services/community_providers.dart';
import '../../shared/models/community.dart';

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
          _DiscoverList(),
        ],
      ),
    );
  }
}

/// Aba Descobrir: busca local case-insensitive em name/description.
///
/// O backend devolve a lista completa/bounded de public_code não-entradas —
/// filtro local é aceitável (sem N+1, sem backend search desnecessário).
/// Pull-to-refresh recarrega a fonte e REAPLICA a query (não limpa a busca).
class _DiscoverList extends ConsumerStatefulWidget {
  @override
  ConsumerState<_DiscoverList> createState() => _DiscoverListState();
}

class _DiscoverListState extends ConsumerState<_DiscoverList> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Community> _applyQuery(List<Community> communities) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return communities;
    return communities
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.description.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(discoverCommunitiesProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: 'Buscar comunidade...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
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
              final filtered = _applyQuery(communities);
              if (filtered.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _query.trim().isEmpty
                          ? 'Nenhuma comunidade pública no momento.'
                          : 'Nenhuma comunidade encontrada',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              // Refresh recarrega a fonte; a query é preservada e reaplicada.
              return RefreshIndicator(
                onRefresh: () async =>
                    ref.invalidate(discoverCommunitiesProvider),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final community = filtered[i];
                    return NoanaCommunityRow(
                      name: community.name,
                      memberCount: community.memberCount,
                      avatarUrl: community.avatarUrl,
                      subtitle: community.description.trim().isEmpty
                          ? null
                          : community.description.trim(),
                      trailing: FilledButton(
                        onPressed: () => context
                            .push('/communities/${community.uuid}'),
                        child: const Text('Entrar'),
                      ),
                      onTap: () =>
                          context.push('/communities/${community.uuid}'),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
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
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: communities.length,
            itemBuilder: (context, i) {
              final community = communities[i];
              return NoanaCommunityRow(
                name: community.name,
                memberCount: community.memberCount,
                avatarUrl: community.avatarUrl,
                onTap: () =>
                    context.push('/communities/${community.uuid}'),
              );
            },
          ),
        );
      },
    );
  }
}
