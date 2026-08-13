/// Score service (Phase 5, spec §39) — DailyScore + privacy + ranking.
///
/// All requests use the existing Cognito IdToken authentication through
/// [ApiClient]. Formula calculation (when an authoritative formula exists)
/// MUST live in a dedicated domain layer, never in widgets/providers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../core/providers.dart';
import '../shared/models/score.dart';

class ScoreService {
  ScoreService({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  static const String _scoresBase = '/wellness/scores/daily';

  /// GET /wellness/scores/daily/latest/ — 404 if no score yet.
  Future<DailyScore?> getLatest() async {
    try {
      final res = await _api.get('$_scoresBase/latest/');
      return DailyScore.fromJson(res.data as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// GET /wellness/scores/daily/?from=&to=
  Future<List<DailyScore>> getHistory({String? from, String? to}) async {
    final query = <String, String>{
      'from': ?from,
      'to': ?to,
    };
    final res = await _api.get('$_scoresBase/', query: query);
    return ((res.data as List<dynamic>?) ?? [])
        .map((e) => DailyScore.fromJson(e as Map<String, dynamic>))
        .toList();
  }
  /// PUT /wellness/scores/daily/{date}/ — idempotent upsert (spec §8–§9).
  Future<DailyScore> uploadDailyScore(
    String scoreDate,
    DailyScoreUpload upload,
  ) async {
    final res = await _api.put('$_scoresBase/$scoreDate/', body: upload.toJson());
    return DailyScore.fromJson(res.data as Map<String, dynamic>);
  }

  /// PATCH /wellness/communities/{uuid}/privacy/ — own share scope (spec §15).
  Future<CommunityShareScope> updateShareScope(
    String communityUuid,
    CommunityShareScope scope,
  ) async {
    final res = await _api.patch(
      '/wellness/communities/$communityUuid/privacy/',
      body: scope.toJson(),
    );
    final data = res.data as Map<String, dynamic>;
    return CommunityShareScope.fromJson(
      (data['share_scope_json'] as Map<String, dynamic>?) ?? const {},
    );
  }

  /// GET /wellness/communities/{uuid}/ranking/ (spec §30).
  Future<CommunityRanking> getRanking(
    String communityUuid, {
    String metric = 'readiness',
    String period = 'week',
    String? date,
    int page = 1,
    int pageSize = 50,
  }) async {
    final query = <String, String>{
      'metric': metric,
      'period': period,
      'page': '$page',
      'page_size': '$pageSize',
      'date': ?date,
    };
    final res = await _api.get(
      '/wellness/communities/$communityUuid/ranking/',
      query: query,
    );
    return CommunityRanking.fromJson(res.data as Map<String, dynamic>);
  }
}

/// Riverpod provider for [ScoreService].
final scoreServiceProvider = Provider<ScoreService>((ref) {
  return ScoreService(apiClient: ref.watch(apiClientProvider));
});
