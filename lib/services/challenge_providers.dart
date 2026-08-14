/// Challenge Riverpod state (Phase 7, spec §47).
///
/// Widgets never call HTTP directly. Mutations go through the controller,
/// which invalidates list/detail/ranking so they refresh.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../shared/models/challenge.dart';
import 'challenge_service.dart';

final challengeServiceProvider = Provider<ChallengeService>((ref) {
  return ChallengeService(apiClient: ref.watch(apiClientProvider));
});

/// Challenges of a community (spec §47) — filtered client-side by section.
final communityChallengesProvider =
    FutureProvider.family<List<Challenge>, String>((ref, communityUuid) {
  return ref.watch(challengeServiceProvider).listChallenges(communityUuid);
});

/// Challenge detail (spec §35) — includes current user progress + status.
final challengeDetailProvider =
    FutureProvider.family<Challenge, ({String communityUuid, String challengeUuid})>(
        (ref, params) {
  return ref.watch(challengeServiceProvider).getChallenge(
        params.communityUuid,
        params.challengeUuid,
      );
});

/// Challenge ranking (spec §33).
final challengeRankingProvider =
    FutureProvider.family<ChallengeRanking, ({String communityUuid, String challengeUuid})>(
        (ref, params) {
  return ref.watch(challengeServiceProvider).getRanking(
        params.communityUuid,
        params.challengeUuid,
      );
});

/// Controller for challenge mutations — performs the HTTP call, then
/// invalidates the affected providers so lists/detail/ranking refresh.
class ChallengeActionController {
  ChallengeActionController(this._ref);

  final Ref _ref;

  ChallengeService get _service => _ref.read(challengeServiceProvider);

  void _invalidate(String communityUuid, String? challengeUuid) {
    _ref.invalidate(communityChallengesProvider(communityUuid));
    if (challengeUuid != null) {
      final params = (communityUuid: communityUuid, challengeUuid: challengeUuid);
      _ref.invalidate(challengeDetailProvider(params));
      _ref.invalidate(challengeRankingProvider(params));
    }
  }

  Future<void> createChallenge(
    String communityUuid,
    ChallengeCreateRequest request,
  ) async {
    final challenge =
        await _service.createChallenge(communityUuid, request);
    _invalidate(communityUuid, challenge.uuid);
  }

  Future<void> joinChallenge(String communityUuid, String challengeUuid) async {
    await _service.joinChallenge(communityUuid, challengeUuid);
    _invalidate(communityUuid, challengeUuid);
  }

  Future<void> leaveChallenge(String communityUuid, String challengeUuid) async {
    await _service.leaveChallenge(communityUuid, challengeUuid);
    _invalidate(communityUuid, challengeUuid);
  }

  Future<void> cancelChallenge(String communityUuid, String challengeUuid) async {
    await _service.cancelChallenge(communityUuid, challengeUuid);
    _invalidate(communityUuid, challengeUuid);
  }

  Future<void> removeParticipant(
    String communityUuid,
    String challengeUuid,
    String personUuid,
  ) async {
    await _service.removeParticipant(communityUuid, challengeUuid, personUuid);
    _invalidate(communityUuid, challengeUuid);
  }
}

final challengeActionControllerProvider =
    Provider<ChallengeActionController>((ref) {
  return ChallengeActionController(ref);
});
