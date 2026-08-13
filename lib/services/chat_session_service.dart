/// Chat session service (Phase 3, spec §12).
///
/// Calls `POST /v1/wellness/chat/session/` on the Wellness backend, which
/// derives identity from the Cognito JWT, provisions the JuggleIM projection
/// and returns the client-safe session. The Flutter app NEVER talks to
/// JuggleIM admin APIs and never holds the app secret (spec §13).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../core/providers.dart';

/// Client-safe chat session returned by the backend.
class ChatSession {
  const ChatSession({
    required this.userId,
    required this.token,
    required this.wsUrl,
    required this.apiUrl,
    required this.navUrl,
  });

  final String userId;
  final String token;
  final String wsUrl;
  final String apiUrl;
  final String navUrl;

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      userId: json['user_id'] as String,
      token: json['token'] as String,
      wsUrl: json['ws_url'] as String,
      apiUrl: json['api_url'] as String,
      navUrl: json['nav_url'] as String,
    );
  }
}

class ChatSessionService {
  ChatSessionService({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  /// POST /wellness/chat/session/ — idempotent; never trusts client identity.
  Future<ChatSession> obtainSession() async {
    final res = await _api.post('/wellness/chat/session/', body: {});
    return ChatSession.fromJson(res.data as Map<String, dynamic>);
  }
}

final chatSessionServiceProvider = Provider<ChatSessionService>((ref) {
  return ChatSessionService(apiClient: ref.watch(apiClientProvider));
});
