import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noana_wellness_app/app.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/core/providers.dart';
import 'package:noana_wellness_app/services/push_notification_service.dart';
import 'package:noana_wellness_app/services/push_registration_service.dart';

/// Regression de startup (spec §6/§13): push é NÃO-CRÍTICO — qualquer falha
/// de Firebase/permissão/token/registro NUNCA impede o app de renderizar.
class _ThrowingGateway implements MessagingGateway {
  @override
  Future<PushPermissionStatus> requestPermission() async =>
      throw Exception('firebase unavailable');

  @override
  Future<String?> getToken() async => throw Exception('no firebase');

  @override
  Future<String?> getApnsToken() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onForegroundMessage => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onMessageOpenedApp => const Stream.empty();

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async => null;
}

class _NullTokenGateway extends _ThrowingGateway {
  @override
  Future<PushPermissionStatus> requestPermission() async =>
      PushPermissionStatus.authorized;

  @override
  Future<String?> getToken() async => null; // APNs/FCM ainda não prontos

  @override
  Future<String?> getApnsToken() async => null;
}

/// Gateway com token válido (para testar falha do BACKEND de registro).
class _TokenGateway extends _NullTokenGateway {
  @override
  Future<String?> getToken() async => 'fcm-token-startup-000000001';
}

void main() {
  group('startup com Firebase indisponível', () {
    testWidgets('app renderiza a UI de login (push degradado, não fatal)',
        (tester) async {
      final failingApi = _RecordingApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pushNotificationServiceProvider.overrideWithValue(
              PushNotificationService(
                gateway: _ThrowingGateway(),
                registration: PushRegistrationService(apiClient: failingApi),
                platformOverride: 'ios',
              ),
            ),
          ],
          child: const NoanaWellnessApp(),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 300));

      // O app renderiza — não ficou em tela branca; algum widget da árvore
      // (login ou shell) está presente.
      expect(find.byType(NoanaWellnessApp), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Push NÃO registrou nada (Firebase indisponível) e não quebrou o boot.
      expect(failingApi.posts, isEmpty);
    });
  });

  group('token FCM nulo no boot (iOS: APNs ainda não pronto)', () {
    test('onAuthenticated degrada sem registrar e sem lançar', () async {
      final api = _RecordingApi();
      final service = PushNotificationService(
        gateway: _NullTokenGateway(),
        registration: PushRegistrationService(apiClient: api),
        platformOverride: 'ios',
      );
      await service.init();
      await service.onAuthenticated();
      expect(api.posts, isEmpty); // sem token → sem registro
      expect(service.deviceId, isNull);
    });
  });

  group('falha de registro no backend', () {
    test('onAuthenticated não lança — push degradado, login segue', () async {
      final api = _RecordingApi()..failPost = true;
      final service = PushNotificationService(
        gateway: _TokenGateway(),
        registration: PushRegistrationService(apiClient: api),
        platformOverride: 'ios',
      );
      await service.init();
      // backend fora do ar: registro falha, mas NÃO lança (login segue)
      await service.onAuthenticated();
      expect(service.deviceId, isNull);
    });
  });
}

/// ApiClient stub mínimo para os testes (mesmo shape do fake de registro).
class _RecordingApi implements ApiClient {
  final posts = <Map<String, dynamic>>[];
  bool failPost = false;

  @override
  Future<ApiResponse> get(String path,
          {bool authenticated = true, Map<String, String>? query}) async =>
      throw UnimplementedError();

  @override
  Future<ApiResponse> post(String path,
      {bool authenticated = true, Object? body}) async {
    if (failPost) throw Exception('network down');
    posts.add({'path': path, 'body': body});
    return ApiResponse(data: {'id': 'device-1'}, statusCode: 201);
  }

  @override
  Future<ApiResponse> patch(String path,
          {bool authenticated = true, Object? body}) async =>
      throw UnimplementedError();

  @override
  Future<ApiResponse> put(String path,
          {bool authenticated = true, Object? body}) async =>
      throw UnimplementedError();

  @override
  Future<ApiResponse> delete(String path,
      {bool authenticated = true}) async {
    return ApiResponse(data: null, statusCode: 204);
  }
}
