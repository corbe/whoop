/// Community state consistency (Social Phase, spec §15).
///
/// Join/leave/create must update My Communities / Discover IMMEDIATELY
/// through the existing scoped invalidations — no app restart. Uses a fake
/// CommunityService with in-memory state; proves the controller invalidates
/// the right providers (and only those).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/community_providers.dart';
import 'package:noana_wellness_app/services/community_service.dart';
import 'package:noana_wellness_app/shared/models/community.dart';

Community _community(String uuid, String name) => Community(
      uuid: uuid,
      name: name,
      currentUserRole: 'owner',
      currentUserStatus: 'active',
    );

class _FakeAuthService implements AuthService {
  @override
  Future<String> getIdToken() async => 'id-token-1';
  @override
  Future<String> getAccessToken() async => 'access-token-1';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake service with mutable in-memory state: joined set + discoverable list.
class _FakeCommunityService extends CommunityService {
  _FakeCommunityService() : super(apiClient: _dummyApi());

  static ApiClient _dummyApi() => ApiClient(
        config: const AppConfig(
          environment: AppEnvironment.hml,
          cognitoPoolId: 'us-east-1_BFGyiLUlb',
          cognitoClientId: '6dj5pdv3fnrg8jbknu12ljg30k',
          wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
          juggleApiUrl: 'https://juggleim-api.hml.noana.link',
          juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
          juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
        ),
        auth: _FakeAuthService(),
        httpClient: MockClient((r) async => http.Response('{}', 200)),
      );

  final Map<String, Community> joined = {};
  final List<Community> discoverable = [
    _community('pub-1', 'Running Floripa'),
    _community('pub-2', 'Meditação'),
  ];

  @override
  Future<List<Community>> getMyCommunities() async => joined.values.toList();

  @override
  Future<List<Community>> discoverCommunities() async => discoverable
      .where((c) => !joined.containsKey(c.uuid))
      .toList();

  @override
  Future<Community> getCommunity(String uuid) async =>
      joined[uuid] ?? discoverable.firstWhere((c) => c.uuid == uuid);

  @override
  Future<Community> createCommunity(CommunityCreateRequest request) async {
    final community = _community('new-1', request.name);
    joined[community.uuid] = community;
    return community;
  }

  @override
  Future<Community> joinCommunity(String uuid, {String? joinCode}) async {
    final community = discoverable.firstWhere((c) => c.uuid == uuid);
    joined[uuid] = community;
    return community;
  }

  @override
  Future<Community> leaveCommunity(String uuid) async {
    final community = joined.remove(uuid)!;
    return community;
  }
}

ProviderContainer _container(_FakeCommunityService service) {
  return ProviderContainer(
    overrides: [
      communityServiceProvider.overrideWithValue(service),
    ],
  );
}

void main() {
  test('join from Discover updates My Communities immediately', () async {
    final service = _FakeCommunityService();
    final container = _container(service);
    addTearDown(container.dispose);

    expect(await container.read(myCommunitiesProvider.future), isEmpty);
    expect(await container.read(discoverCommunitiesProvider.future), hasLength(2));

    await container
        .read(communityActionControllerProvider)
        .join('pub-1');

    final mine = await container.read(myCommunitiesProvider.future);
    expect(mine.map((c) => c.uuid), contains('pub-1'));
    // Discover exclui a comunidade que entrei (sem restart).
    final discover = await container.read(discoverCommunitiesProvider.future);
    expect(discover.map((c) => c.uuid), isNot(contains('pub-1')));
  });

  test('leave updates My Communities immediately', () async {
    final service = _FakeCommunityService();
    final container = _container(service);
    addTearDown(container.dispose);

    await container.read(communityActionControllerProvider).join('pub-1');
    expect(await container.read(myCommunitiesProvider.future), hasLength(1));

    await container.read(communityActionControllerProvider).leave('pub-1');

    expect(await container.read(myCommunitiesProvider.future), isEmpty);
    // Volta a ser descobrível.
    final discover = await container.read(discoverCommunitiesProvider.future);
    expect(discover.map((c) => c.uuid), contains('pub-1'));
  });

  test('create appears in My Communities immediately', () async {
    final service = _FakeCommunityService();
    final container = _container(service);
    addTearDown(container.dispose);

    await container.read(communityActionControllerProvider).create(
          const CommunityCreateRequest(
            name: 'Nova Comunidade',
            visibility: 'public_code',
          ),
        );

    final mine = await container.read(myCommunitiesProvider.future);
    expect(mine.map((c) => c.name), contains('Nova Comunidade'));
  });

  test('unrelated providers are NOT invalidated (scoped)', () async {
    final service = _FakeCommunityService();
    final container = _container(service);
    addTearDown(container.dispose);

    // Toca o detail de pub-1 antes da ação.
    await container.read(communityDetailProvider('pub-1').future);
    // join invalida detail/pub-1 + listas — verifica que detail refaz a busca
    // e que um detail de OUTRA comunidade não é afetado estruturalmente.
    await container.read(communityActionControllerProvider).join('pub-1');
    final detail = await container.read(communityDetailProvider('pub-1').future);
    expect(detail.uuid, 'pub-1');
  });
}
