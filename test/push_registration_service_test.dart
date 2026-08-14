import 'package:flutter_test/flutter_test.dart';
import 'package:noana_wellness_app/core/network/api_client.dart';
import 'package:noana_wellness_app/services/push_registration_service.dart';

/// Fake ApiClient: captura chamadas sem rede.
class _FakeApiClient implements ApiClient {
  final posts = <Map<String, dynamic>>[];
  final deletes = <String>[];
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
    return ApiResponse(data: {'uuid': 'device-abc-123'}, statusCode: 201);
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
  group('PushRegistrationService', () {
    test('register envia token+platform e devolve o device uuid', () async {
      final api = _FakeApiClient();
      final svc = PushRegistrationService(apiClient: api);

      final id = await svc.register(token: 'fcm-token-1', platform: 'android');

      expect(id, 'device-abc-123');
      expect(api.posts.single['path'], '/wellness/devices/push/');
      expect(api.posts.single['body'], {
        'token': 'fcm-token-1',
        'platform': 'android',
      });
    });

    test('disable chama DELETE com o device id', () async {
      final api = _FakeApiClient();
      final svc = PushRegistrationService(apiClient: api);

      await svc.disable('device-abc-123');

      expect(api.deletes.single, '/wellness/devices/push/device-abc-123/');
    });

    test('disable com id vazio nao chama a rede', () async {
      final api = _FakeApiClient();
      final svc = PushRegistrationService(apiClient: api);

      await svc.disable('');

      expect(api.deletes, isEmpty);
    });

    test('falha de rede no register propaga (sem esconder erro)', () async {
      final api = _FakeApiClient()..failPost = true;
      final svc = PushRegistrationService(apiClient: api);

      expect(
        () => svc.register(token: 't', platform: 'android'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
