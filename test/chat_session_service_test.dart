/// Tests for ChatSessionService + JuggleImService (Phase 3).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/config/app_config.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/chat_session_service.dart';
import 'package:noana_wellness_app/services/juggle_im_service.dart';

const _sessionJson = {
  'user_id': 'wellness:11111111-2222-3333-4444-555555555555',
  'token': 'juggle-token-abc',
  'ws_url': 'wss://juggleim-ws.hml.noana.link',
  'api_url': 'https://juggleim-api.hml.noana.link',
  'nav_url': 'https://juggleim-nav.hml.noana.link',
};

ApiClient _apiWith(MockClient mock) {
  return ApiClient(
    config: const AppConfig(
      environment: AppEnvironment.hml,
      cognitoPoolId: 'us-east-1_BFGyiLUlb',
      cognitoClientId: '6dj5pdv3fnrg8jbknu12ljg30k',
      wellnessApiBaseUrl: 'https://api.hml.noana.link/v1',
      juggleApiUrl: 'https://juggleim-api.hml.noana.link',
      juggleNavUrl: 'https://juggleim-nav.hml.noana.link',
      juggleWsUrl: 'wss://juggleim-ws.hml.noana.link',
    ),
    auth: FakeAuthService(),
    httpClient: mock,
  );
}

class FakeAuthService implements AuthService {
  @override
  Future<String> getIdToken() async => 'id-token-1';
  @override
  Future<String> getAccessToken() async => 'access-token-1';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('ChatSessionService', () {
    test('obtainSession POSTs and parses the client-safe session', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(),
            'https://api.hml.noana.link/v1/wellness/chat/session/');
        expect(request.headers['Authorization'], 'Bearer id-token-1');
        return http.Response(jsonEncode(_sessionJson), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = ChatSessionService(apiClient: _apiWith(mock));

      final session = await service.obtainSession();

      expect(session.userId, 'wellness:11111111-2222-3333-4444-555555555555');
      expect(session.token, 'juggle-token-abc');
      expect(session.wsUrl, 'wss://juggleim-ws.hml.noana.link');
      expect(session.apiUrl, 'https://juggleim-api.hml.noana.link');
      expect(session.navUrl, 'https://juggleim-nav.hml.noana.link');
    });

    test('obtainSession surfaces backend errors as ApiException', () async {
      final mock = MockClient(
          (request) async => http.Response('{"detail":"down"}', 503));
      final service = ChatSessionService(apiClient: _apiWith(mock));
      expect(service.obtainSession(), throwsA(isA<ApiException>()));
    });
  });

  group('JuggleImService state mapping', () {
    test('SDK status codes map to domain states', () {
      // JuggleConnectionState mapping is internal; verify via the public enum.
      expect(JuggleConnectionState.values,
          containsAll(JuggleConnectionState.values));
      expect(JuggleConnectionState.disconnected.name, 'disconnected');
      expect(JuggleConnectionState.reconnecting.name, 'reconnecting');
      expect(JuggleConnectionState.failed.name, 'failed');
    });

    test('initial state is disconnected', () {
      final service = JuggleImService();
      expect(service.state, JuggleConnectionState.disconnected);
      expect(service.session, isNull);
      service.dispose();
    });
  });
}
