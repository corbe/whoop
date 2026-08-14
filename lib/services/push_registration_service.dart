import '../core/network/api_client.dart';

/// Registro de device push (fase 9) — firewall-agnóstico: recebe o token FCM
/// do provider de push (firebase_messaging quando houver google-services.json)
/// e registra/desregistra contra a Wellness API.
///
/// A identidade é SEMPRE derivada do JWT no backend — este service nunca envia
/// person UUID nem credenciais.
class PushRegistrationService {
  PushRegistrationService({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  static const String _base = '/wellness/devices/push';

  /// POST /wellness/devices/push/ — idempotente (UNIQUE person+token).
  /// Retorna o device uuid para uso em logout/disable.
  Future<String> register({
    required String token,
    required String platform, // 'android' | 'ios'
  }) async {
    final res = await _api.post(
      '$_base/',
      body: {'token': token, 'platform': platform},
    );
    final data = res.data as Map<String, dynamic>;
    return (data['uuid'] ?? data['device'] ?? '').toString();
  }

  /// DELETE /wellness/devices/push/{id}/ — desassocia o token (logout/switch).
  Future<void> disable(String deviceId) async {
    if (deviceId.isEmpty) return;
    await _api.delete('$_base/$deviceId/');
  }
}
