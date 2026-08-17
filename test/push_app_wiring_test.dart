/// App-level regression: push registration MUST be wired to the auth
/// lifecycle at the APP level (app.dart), not only inside
/// PushNotificationService.
///
/// Bug (2026-08-17, HML): app.dart registrava o listener de push com
/// `_authSub ??=` DEPOIS de já ter atribuído `_authSub` ao listener de
/// invalidação de chat — o listener de push NUNCA era anexado, então
/// `push.onAuthenticated()` / `push.onLoggedOut()` nunca rodavam e NENHUM
/// DeviceFront era criado no backend após login/restore de sessão.
///
/// Estes testes pumpam o app COMPLETO (NoanaWellnessApp) e provam o fluxo
/// de ponta a ponta: auth event → POST /wellness/devices/push/ → DELETE no
/// logout. Sem Firebase real (gateway fake) e sem rede (ApiClient fake).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/app.dart';
import 'package:noana_wellness_app/core/auth/auth_service.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/core/providers.dart';
import 'package:noana_wellness_app/services/push_notification_service.dart';
import 'package:noana_wellness_app/services/push_registration_service.dart';

import 'helpers/fakes.dart';

/// Gateway fake: simula FirebaseMessaging sem Firebase real.
class _FakeGateway implements MessagingGateway {
  final tokenController = StreamController<String>.broadcast();
  final foregroundController = StreamController<Map<String, dynamic>>.broadcast();
  final openedController = StreamController<Map<String, dynamic>>.broadcast();

  PushPermissionStatus permissionResult = PushPermissionStatus.authorized;
  String? token = 'fcm-token-1';
  String? apnsToken = 'apns-token-1';

  @override
  Future<PushPermissionStatus> requestPermission() async => permissionResult;

  @override
  Future<String?> getToken() async => token;

  @override
  Future<String?> getApnsToken() async => apnsToken;

  @override
  Stream<String> get onTokenRefresh => tokenController.stream;

  @override
  Stream<Map<String, dynamic>> get onForegroundMessage => foregroundController.stream;

  @override
  Stream<Map<String, dynamic>> get onMessageOpenedApp => openedController.stream;

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async => null;

  void dispose() {
    tokenController.close();
    foregroundController.close();
    openedController.close();
  }
}

/// ApiClient fake: captura POST/DELETE do registro de push.
class _FakeApi implements ApiClient {
  final posts = <Map<String, dynamic>>[];
  final deletes = <String>[];

  @override
  Future<ApiResponse> get(String path,
          {bool authenticated = true, Map<String, String>? query}) async =>
      throw UnimplementedError();

  @override
  Future<ApiResponse> post(String path,
      {bool authenticated = true, Object? body}) async {
    posts.add({'path': path, 'body': body});
    return ApiResponse(data: {'id': 'device-abc-123'}, statusCode: 201);
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
    deletes.add(path);
    return ApiResponse(data: null, statusCode: 204);
  }
}

void main() {
  late _FakeGateway gateway;
  late _FakeApi api;
  late FakeCognitoGateway cognito;
  late FakeSecureStorage storage;

  setUp(() {
    gateway = _FakeGateway();
    api = _FakeApi();
    cognito = FakeCognitoGateway();
    storage = FakeSecureStorage();
  });

  tearDown(() => gateway.dispose());

  ProviderContainer makeContainer() {
    return ProviderContainer(overrides: [
      secureStorageProvider.overrideWithValue(storage),
      authServiceProvider.overrideWith((ref) {
        final service = AuthService(gateway: cognito, storage: storage);
        ref.onDispose(service.dispose);
        return service;
      }),
      pushNotificationServiceProvider.overrideWith((ref) {
        final service = PushNotificationService(
          gateway: gateway,
          registration: PushRegistrationService(apiClient: api),
          platformOverride: 'ios',
        );
        ref.onDispose(service.dispose);
        return service;
      }),
    ]);
  }

  Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NoanaWellnessApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<Map<String, dynamic>> pushPosts() =>
      api.posts.where((p) => p['path'] == '/wellness/devices/push/').toList();

  testWidgets(
      'cold start com sessão salva: restore dispara POST de registro de push',
      (tester) async {
    cognito = FakeCognitoGateway(initialSession: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    await pumpApp(tester, container);

    final posts = pushPosts();
    expect(posts, isNotEmpty,
        reason: 'restore de sessão (authenticated) deve disparar o registro');
    final body = posts.first['body'] as Map;
    expect(body['platform'], 'ios');
    expect(body['token'], 'fcm-token-1');
  });

  testWidgets('login novo: evento authenticated dispara POST de registro',
      (tester) async {
    final container = makeContainer();
    final auth = container.read(authServiceProvider);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    expect(pushPosts(), isEmpty,
        reason: 'antes do login não pode haver registro');

    await auth.login(username: 'user@noana.com', password: 'secret123');
    await tester.pumpAndSettle();

    expect(pushPosts(), isNotEmpty,
        reason: 'login deve disparar o registro de push (POST)');
  });

  testWidgets('logout: evento unauthenticated dispara DELETE de desassociação',
      (tester) async {
    cognito = FakeCognitoGateway(initialSession: true);
    final container = makeContainer();
    final auth = container.read(authServiceProvider);
    addTearDown(container.dispose);

    await pumpApp(tester, container);
    expect(pushPosts(), isNotEmpty, reason: 'pré-condição: registro no login');
    expect(api.deletes, isEmpty);

    await auth.logout();
    await tester.pumpAndSettle();

    expect(api.deletes, isNotEmpty,
        reason: 'logout deve desassociar o device (DELETE)');
    expect(api.deletes.first, startsWith('/wellness/devices/push/'));
  });
}
