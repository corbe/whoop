/// Community Riverpod state (Phase 4, spec §27).
///
/// Widgets never call HTTP directly — they watch these providers. Actions go
/// through [communityActionControllerProvider], which performs the call and
/// invalidates the affected lists/detail so the UI stays in sync.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/models/community.dart';
import 'community_service.dart';

/// My Communities (communities where the current user has membership).
final myCommunitiesProvider = FutureProvider<List<Community>>((ref) async {
  return ref.watch(communityServiceProvider).getMyCommunities();
});

/// Discoverable Communities (public_code).
final discoverCommunitiesProvider = FutureProvider<List<Community>>((ref) async {
  return ref.watch(communityServiceProvider).discoverCommunities();
});

/// Community detail (family by uuid).
final communityDetailProvider =
    FutureProvider.family<Community, String>((ref, uuid) async {
  return ref.watch(communityServiceProvider).getCommunity(uuid);
});

/// Members list (family by uuid) — safe social fields only.
final communityMembersProvider =
    FutureProvider.family<List<CommunityMember>, String>((ref, uuid) async {
  return ref.watch(communityServiceProvider).getMembers(uuid);
});

/// Result of a community action (join/leave/ban/unban/role/create).
class CommunityActionResult {
  const CommunityActionResult({required this.message, this.community});

  final String message;
  final Community? community;
}

/// Controller for community mutations — performs the HTTP call, then
/// invalidates the relevant providers so lists/detail refresh.
final communityActionControllerProvider =
    Provider<CommunityActionController>((ref) {
  return CommunityActionController(
    service: ref.watch(communityServiceProvider),
    ref: ref,
  );
});

class CommunityActionController {
  CommunityActionController({required CommunityService service, required Ref ref})
      : _service = service,
        _ref = ref;

  final CommunityService _service;
  final Ref _ref;

  void _refresh({String? uuid}) {
    _ref.invalidate(myCommunitiesProvider);
    _ref.invalidate(discoverCommunitiesProvider);
    if (uuid != null) {
      _ref.invalidate(communityDetailProvider(uuid));
      _ref.invalidate(communityMembersProvider(uuid));
    }
  }

  Future<CommunityActionResult> create(CommunityCreateRequest request) async {
    final community = await _service.createCommunity(request);
    _refresh(uuid: community.uuid);
    return CommunityActionResult(
      message: 'Comunidade "${community.name}" criada.',
      community: community,
    );
  }

  Future<CommunityActionResult> join(String uuid, {String? joinCode}) async {
    final community = await _service.joinCommunity(uuid, joinCode: joinCode);
    _refresh(uuid: uuid);
    return CommunityActionResult(
      message: 'Você entrou em "${community.name}".',
      community: community,
    );
  }

  Future<CommunityActionResult> leave(String uuid) async {
    final community = await _service.leaveCommunity(uuid);
    _refresh(uuid: uuid);
    return CommunityActionResult(
      message: 'Você saiu de "${community.name}".',
      community: community,
    );
  }

  Future<CommunityActionResult> ban(String uuid, String personUuid) async {
    await _service.banMember(uuid, personUuid);
    _refresh(uuid: uuid);
    return const CommunityActionResult(message: 'Membro banido.');
  }

  Future<CommunityActionResult> unban(String uuid, String personUuid) async {
    await _service.unbanMember(uuid, personUuid);
    _refresh(uuid: uuid);
    return const CommunityActionResult(message: 'Membro desbanido.');
  }

  Future<CommunityActionResult> updateRole(
    String uuid,
    String personUuid,
    String role,
  ) async {
    await _service.updateRole(uuid, personUuid, role);
    _refresh(uuid: uuid);
    return CommunityActionResult(message: 'Papel atualizado para $role.');
  }
}
