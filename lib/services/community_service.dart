/// Community service (Phase 4, spec §26).
///
/// All requests use the existing Cognito IdToken API authentication through
/// [ApiClient]. Widgets never call HTTP directly — they consume Riverpod
/// providers built on this service.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../core/providers.dart';
import '../shared/models/community.dart';
import '../shared/models/social_profile.dart';

class CommunityService {
  CommunityService({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  static const String _base = '/wellness/communities';

  /// GET /wellness/communities/?scope=my
  Future<List<Community>> getMyCommunities() async {
    final res = await _api.get('$_base/', query: {'scope': 'my'});
    return _parseList(res.data);
  }

  /// GET /wellness/communities/?scope=discoverable
  Future<List<Community>> discoverCommunities() async {
    final res = await _api.get('$_base/', query: {'scope': 'discoverable'});
    return _parseList(res.data);
  }

  /// GET /wellness/communities/{uuid}/
  Future<Community> getCommunity(String uuid) async {
    final res = await _api.get('$_base/$uuid/');
    return Community.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /wellness/communities/ — the backend derives the owner from the JWT.
  Future<Community> createCommunity(CommunityCreateRequest request) async {
    final res = await _api.post('$_base/', body: request.toJson());
    return Community.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /wellness/communities/{uuid}/join/ — idempotent.
  Future<Community> joinCommunity(String uuid, {String? joinCode}) async {
    final res = await _api.post(
      '$_base/$uuid/join/',
      body: joinCode == null ? <String, dynamic>{} : {'join_code': joinCode},
    );
    return Community.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /wellness/communities/{uuid}/leave/ — idempotent.
  Future<Community> leaveCommunity(String uuid) async {
    final res = await _api.post('$_base/$uuid/leave/', body: const <String, dynamic>{});
    return Community.fromJson(res.data as Map<String, dynamic>);
  }

  /// GET /wellness/communities/{uuid}/members/
  Future<List<CommunityMember>> getMembers(String uuid) async {
    final res = await _api.get('$_base/$uuid/members/');
    final list = res.data as List<dynamic>;
    return list
        .map((e) => CommunityMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /wellness/communities/{uuid}/members/{personUuid}/ban/ — owner/admin.
  Future<CommunityMember> banMember(String uuid, String personUuid) async {
    final res = await _api.post(
      '$_base/$uuid/members/$personUuid/ban/',
      body: const <String, dynamic>{},
    );
    return CommunityMember.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /wellness/communities/{uuid}/members/{personUuid}/unban/ — owner/admin.
  Future<CommunityMember> unbanMember(String uuid, String personUuid) async {
    final res = await _api.post(
      '$_base/$uuid/members/$personUuid/unban/',
      body: const <String, dynamic>{},
    );
    return CommunityMember.fromJson(res.data as Map<String, dynamic>);
  }

  /// PATCH /wellness/communities/{uuid}/members/{personUuid}/ — role (owner only).
  Future<CommunityMember> updateRole(
    String uuid,
    String personUuid,
    String role,
  ) async {
    final res = await _api.patch(
      '$_base/$uuid/members/$personUuid/',
      body: {'role': role},
    );
    return CommunityMember.fromJson(res.data as Map<String, dynamic>);
  }

  /// GET /wellness/communities/{uuid}/notification-preferences/ (Phase 6).
  Future<String> getNotificationPreference(String uuid) async {
    final res = await _api.get('$_base/$uuid/notification-preferences/');
    return ((res.data as Map<String, dynamic>)['mode'] as String?) ?? 'all';
  }

  /// PATCH /wellness/communities/{uuid}/notification-preferences/ (Phase 6).
  Future<String> updateNotificationPreference(String uuid, String mode) async {
    final res = await _api.patch(
      '$_base/$uuid/notification-preferences/',
      body: {'mode': mode},
    );
    return ((res.data as Map<String, dynamic>)['mode'] as String?) ?? mode;
  }

  /// GET /wellness/communities/{uuid}/members/{personUuid}/social-profile/
  /// (Social Phase) — SOCIAL data only; never physiological.
  Future<MemberSocialProfile> getMemberSocialProfile(
      String uuid, String personUuid) async {
    final res = await _api.get('$_base/$uuid/members/$personUuid/social-profile/');
    return MemberSocialProfile.fromJson(res.data as Map<String, dynamic>);
  }

  List<Community> _parseList(dynamic data) {
    final list = data as List<dynamic>;
    return list
        .map((e) => Community.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// Riverpod provider for [CommunityService].
final communityServiceProvider = Provider<CommunityService>((ref) {
  return CommunityService(apiClient: ref.watch(apiClientProvider));
});
