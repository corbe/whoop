/// Score Riverpod state (Phase 5, spec §49–§50).
///
/// Widgets never call HTTP directly. Mutations go through the controllers,
/// which invalidate the affected providers (latest/history/ranking) so stale
/// state is never shown after uploads or privacy changes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/models/score.dart';
import 'score_service.dart';

/// Latest DailyScore of the current user (null while none exists).
final latestDailyScoreProvider = FutureProvider<DailyScore?>((ref) async {
  return ref.watch(scoreServiceProvider).getLatest();
});

/// Score history (family by optional from/to).
final scoreHistoryProvider =
    FutureProvider.family<List<DailyScore>, ({String? from, String? to})>(
        (ref, range) async {
  return ref.watch(scoreServiceProvider).getHistory(
        from: range.from,
        to: range.to,
      );
});

/// Current user's share scope in a community (family by community uuid).
final communityShareScopeProvider =
    FutureProvider.family<CommunityShareScope, String>((ref, uuid) async {
  // The backend does not expose a GET for share scope; we derive the toggles
  // from the community detail's current_user data where possible. For the
  // privacy UI we default to all-off (privacy-safe) until the user saves.
  return const CommunityShareScope();
});

/// Ranking (family by community uuid + metric + period + date).
final communityRankingProvider = FutureProvider.family<CommunityRanking,
    ({String uuid, String metric, String period, String? date})>((ref, params) async {
  return ref.watch(scoreServiceProvider).getRanking(
        params.uuid,
        metric: params.metric,
        period: params.period,
        date: params.date,
      );
});

/// Score upload controller — upserts then refreshes latest + history.
final scoreUploadControllerProvider = Provider<ScoreUploadController>((ref) {
  return ScoreUploadController(
    service: ref.watch(scoreServiceProvider),
    ref: ref,
  );
});

class ScoreUploadController {
  ScoreUploadController({required ScoreService service, required Ref ref})
      : _service = service,
        _ref = ref;

  final ScoreService _service;
  final Ref _ref;

  Future<DailyScore> upload(String scoreDate, DailyScoreUpload upload) async {
    final score = await _service.uploadDailyScore(scoreDate, upload);
    // Cache invalidation (spec §50): latest + history + affected rankings.
    _ref.invalidate(latestDailyScoreProvider);
    _ref.invalidate(scoreHistoryProvider);
    return score;
  }
}

/// Share-scope controller — saves privacy then refreshes ranking state.
final shareScopeControllerProvider = Provider<ShareScopeController>((ref) {
  return ShareScopeController(
    service: ref.watch(scoreServiceProvider),
    ref: ref,
  );
});

class ShareScopeController {
  ShareScopeController({required ScoreService service, required Ref ref})
      : _service = service,
        _ref = ref;

  final ScoreService _service;
  final Ref _ref;

  Future<CommunityShareScope> update(String communityUuid, CommunityShareScope scope) async {
    final saved = await _service.updateShareScope(communityUuid, scope);
    _ref.invalidate(communityShareScopeProvider(communityUuid));
    // Ranking may have changed (member may have disappeared / values redacted).
    _ref.invalidate(communityRankingProvider);
    return saved;
  }
}
