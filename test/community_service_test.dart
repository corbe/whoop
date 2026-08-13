/// Tests for Community models + CommunityService (Phase 4).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/community_service.dart';
import 'package:noana_wellness_app/shared/models/community.dart';

const _communityJson = {
  'uuid': '7bdcb64c-a612-4c80-ae81-28a1093ef981',
  'name': 'Running Floripa',
  'description': 'Corrida e wellness em Florianópolis',
  'avatar_url': '',
  'visibility': 'public_code',
  'join_code': 'FLORIPA',
  'owner_person_uuid': '11111111-2222-3333-4444-555555555555',
  'juggle_group_id': 'community:7bdcb64c-a612-4c80-ae81-28a1093ef981',
  'chat_sync_status': 'synced',
  'chat_sync_error': '',
  'chat_synced_at': '2026-08-13T12:00:00Z',
  'member_count': 37,
  'current_user_role': 'owner',
  'current_user_status': 'active',
  'chat_synced': true,
  'created_at': '2026-08-13T12:00:00Z',
  'updated_at': '2026-08-13T12:00:00Z',
};

const _memberJson = {
  'person_uuid': '11111111-2222-3333-4444-555555555555',
  'display_name': 'Daniel',
  'avatar_url': '',
  'role': 'owner',
  'status': 'active',
  'joined_at': '2026-08-13T12:00:00Z',
};

ApiClient _apiWith(MockClient mock) {
  return ApiClient(
    config: const AppConfig(
      environment: AppEnvironment.hml,
      wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
      juggleApiUrl: 'https://juggleim-api.hml.noana.link',
      juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
      juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
    ),
    auth: _FakeAuthService(),
    httpClient: mock,
  );
}

class _FakeAuthService implements AuthService {
  @override
  Future<String> getIdToken() async => 'id-token-1';
  @override
  Future<String> getAccessToken() async => 'access-token-1';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('Community model', () {
    test('fromJson parses the backend response shape', () {
      final community = Community.fromJson(_communityJson);

      expect(community.uuid, '7bdcb64c-a612-4c80-ae81-28a1093ef981');
      expect(community.name, 'Running Floripa');
      expect(community.visibility, 'public_code');
      expect(community.joinCode, 'FLORIPA');
      expect(community.memberCount, 37);
      expect(community.currentUserRole, 'owner');
      expect(community.currentUserStatus, 'active');
      expect(community.chatSynced, isTrue);
      expect(community.juggleGroupId,
          'community:7bdcb64c-a612-4c80-ae81-28a1093ef981');
    });

    test('deterministicGroupId is community:<uuid> (spec §5)', () {
      final community = Community.fromJson(_communityJson);
      expect(community.deterministicGroupId,
          'community:7bdcb64c-a612-4c80-ae81-28a1093ef981');
    });

    test('role/status helpers', () {
      final community = Community.fromJson(_communityJson);
      expect(community.isOwner, isTrue);
      expect(community.isActiveMember, isTrue);
      expect(community.isPublicCode, isTrue);

      final member = CommunityMember.fromJson(_memberJson);
      expect(member.isOwner, isTrue);
      expect(member.isActive, isTrue);
      expect(member.personUuid, '11111111-2222-3333-4444-555555555555');
    });
  });

  group('CommunityService', () {
    test('getMyCommunities GETs scope=my with IdToken', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(),
            'https://api.hml.noana.link/v1/wellness/communities/?scope=my');
        expect(request.headers['Authorization'], 'Bearer id-token-1');
        return http.Response(jsonEncode([_communityJson]), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = CommunityService(apiClient: _apiWith(mock));

      final communities = await service.getMyCommunities();

      expect(communities, hasLength(1));
      expect(communities.first.name, 'Running Floripa');
      expect(communities.first.memberCount, 37);
    });

    test('createCommunity POSTs and never sends owner fields', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/wellness/communities/');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['name'], 'Running Floripa');
        expect(body['visibility'], 'invite_only');
        expect(body.containsKey('owner_person_uuid'), isFalse);
        expect(body.containsKey('owner'), isFalse);
        return http.Response(jsonEncode(_communityJson), 201,
            headers: {'content-type': 'application/json'});
      });
      final service = CommunityService(apiClient: _apiWith(mock));

      final community = await service.createCommunity(
        const CommunityCreateRequest(
          name: 'Running Floripa',
          visibility: 'invite_only',
        ),
      );

      expect(community.uuid, '7bdcb64c-a612-4c80-ae81-28a1093ef981');
    });

    test('joinCommunity sends join_code', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/wellness/communities/uuid1/join/');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['join_code'], 'FLORIPA');
        return http.Response(jsonEncode(_communityJson), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = CommunityService(apiClient: _apiWith(mock));

      final community =
          await service.joinCommunity('uuid1', joinCode: 'FLORIPA');

      expect(community.isActiveMember, isTrue);
    });

    test('getMembers parses safe social fields', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/wellness/communities/uuid1/members/');
        return http.Response(jsonEncode([_memberJson]), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = CommunityService(apiClient: _apiWith(mock));

      final members = await service.getMembers('uuid1');

      expect(members, hasLength(1));
      expect(members.first.displayName, 'Daniel');
      // Safe fields only — no cognito/clinical data in the model.
      expect(members.first.personUuid, '11111111-2222-3333-4444-555555555555');
    });

    test('leaveCommunity POSTs leave endpoint', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/wellness/communities/uuid1/leave/');
        return http.Response(jsonEncode(_communityJson), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = CommunityService(apiClient: _apiWith(mock));

      final community = await service.leaveCommunity('uuid1');

      expect(community.name, 'Running Floripa');
    });

    test('surfaces backend errors as ApiException', () async {
      final mock = MockClient(
          (request) async => http.Response('{"detail":"nope"}', 403));
      final service = CommunityService(apiClient: _apiWith(mock));

      expect(
        service.joinCommunity('uuid1'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
