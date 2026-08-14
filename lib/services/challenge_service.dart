/// ChallengeService (Phase 7, spec §46) — community-scoped challenge APIs.
library;

import '../core/network/api_client.dart';
import '../shared/models/challenge.dart';

class ChallengeService {
  ChallengeService({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  String _base(String communityUuid) =>
      '/wellness/communities/$communityUuid/challenges';

  /// GET list (spec §34) — optional status filter: upcoming|active|completed.
  Future<List<Challenge>> listChallenges(
    String communityUuid, {
    String? status,
  }) async {
    final query = status == null ? null : {'status': status};
    final res = await _api.get('${_base(communityUuid)}/', query: query);
    return ((res.data as Map<String, dynamic>)['challenges'] as List? ?? [])
        .map((e) => Challenge.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET detail (spec §35).
  Future<Challenge> getChallenge(String communityUuid, String challengeUuid) async {
    final res = await _api.get('${_base(communityUuid)}/$challengeUuid/');
    return Challenge.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST create (spec §11) — owner/admin only; backend enforces.
  Future<Challenge> createChallenge(
    String communityUuid,
    ChallengeCreateRequest request,
  ) async {
    final res = await _api.post(
      '${_base(communityUuid)}/',
      body: request.toJson(),
    );
    return Challenge.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST join (spec §18) — idempotent.
  Future<void> joinChallenge(String communityUuid, String challengeUuid) async {
    await _api.post('${_base(communityUuid)}/$challengeUuid/join/');
  }

  /// POST leave (spec §19).
  Future<void> leaveChallenge(String communityUuid, String challengeUuid) async {
    await _api.post('${_base(communityUuid)}/$challengeUuid/leave/');
  }

  /// POST cancel (spec §14) — owner/admin only.
  Future<void> cancelChallenge(String communityUuid, String challengeUuid) async {
    await _api.post('${_base(communityUuid)}/$challengeUuid/');
  }

  /// POST remove participant (spec §20) — owner/admin only.
  Future<void> removeParticipant(
    String communityUuid,
    String challengeUuid,
    String personUuid,
  ) async {
    await _api.post(
      '${_base(communityUuid)}/$challengeUuid/participants/$personUuid/remove/',
    );
  }

  /// GET ranking (spec §33).
  Future<ChallengeRanking> getRanking(
    String communityUuid,
    String challengeUuid, {
    int page = 1,
    int pageSize = 50,
  }) async {
    final res = await _api.get(
      '${_base(communityUuid)}/$challengeUuid/ranking/',
      query: {'page': '$page', 'page_size': '$pageSize'},
    );
    return ChallengeRanking.fromJson(res.data as Map<String, dynamic>);
  }
}
