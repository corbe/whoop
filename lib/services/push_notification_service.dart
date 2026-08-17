import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';

import '../features/notifications/deep_link.dart';
import 'push_registration_service.dart';

/// Status da permissão de notificação (abstração testável).
enum PushPermissionStatus { authorized, denied, notDetermined }

/// Gateway MÍNIMO sobre o FirebaseMessaging — permite mock em testes sem
/// Firebase real (spec push §25).
abstract class MessagingGateway {
  Future<PushPermissionStatus> requestPermission();
  Future<String?> getToken();
  Future<String?> getApnsToken();
  Stream<String> get onTokenRefresh;
  Stream<Map<String, dynamic>> get onForegroundMessage;
  Stream<Map<String, dynamic>> get onMessageOpenedApp;
  Future<Map<String, dynamic>?> getInitialMessage();
}

/// Implementação real: FirebaseMessaging (lazy — acessa o singleton apenas
/// no primeiro uso; sem Firebase inicializado degrada sem crash).
class FirebaseMessagingGateway implements MessagingGateway {
  FirebaseMessaging? _messaging;

  FirebaseMessaging get _m => _messaging ??= FirebaseMessaging.instance;

  @override
  Future<PushPermissionStatus> requestPermission() async {
    final settings = await _m.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    return switch (settings.authorizationStatus) {
      AuthorizationStatus.authorized ||
      AuthorizationStatus.provisional =>
        PushPermissionStatus.authorized,
      AuthorizationStatus.denied => PushPermissionStatus.denied,
      _ => PushPermissionStatus.notDetermined,
    };
  }

  @override
  Future<String?> getToken() async {
    try {
      return await _m.getToken();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> getApnsToken() async {
    try {
      return await _m.getAPNSToken();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<String> get onTokenRefresh => _m.onTokenRefresh;

  @override
  Stream<Map<String, dynamic>> get onForegroundMessage =>
      FirebaseMessaging.onMessage.map((m) => m.data);

  @override
  Stream<Map<String, dynamic>> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => m.data);

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async {
    final message = await _m.getInitialMessage();
    return message?.data;
  }
}

/// Ciclo de vida de push (spec push §4–§19).
///
/// Responsabilidades:
/// - permissão + obtenção de tokens (APNs/FCM) — nunca loga tokens completos;
/// - registro do device no backend APÓS autenticação (identidade do JWT);
/// - refresh de token (onTokenRefresh) re-registra idempotentemente;
/// - logout DESASSOCIA o device do usuário atual (troca de conta segura);
/// - mensagens: foreground (sem banner duplicado), opened/terminated →
///   deep-link (via callback injetado — nunca navega direto daqui).
///
/// NUNCA loga: token FCM/APNs completo, JWT, credenciais.
class PushNotificationService {
  PushNotificationService({
    required MessagingGateway gateway,
    required PushRegistrationService registration,
    String? platformOverride, // testes: forçam 'ios'/'android'
  })  : _gateway = gateway,
        _registration = registration,
        _platform = platformOverride ??
            (Platform.isIOS ? 'ios' : 'android');

  final MessagingGateway _gateway;
  final PushRegistrationService _registration;
  final String _platform;

  StreamSubscription<String>? _tokenSub;
  StreamSubscription<Map<String, dynamic>>? _foregroundSub;
  StreamSubscription<Map<String, dynamic>>? _openedSub;

  PushPermissionStatus _permission = PushPermissionStatus.notDetermined;
  String? _fcmToken;
  String? _deviceId;

  /// Callback de navegação pós-ready (router/bootstrap prontos).
  /// Injetado pelo app — o service NUNCA navega diretamente.
  Future<void> Function(NotificationDeepLink link)? onOpenLink;

  /// Callback de falha de registro (log seguro; nunca quebra login).
  void Function(String message)? onRegisterFailure;

  PushPermissionStatus get permission => _permission;
  String? get deviceId => _deviceId;

  /// Inicializa: permissão + tokens + assinaturas. Chamado UMA vez no boot.
  /// Degrada sem crash quando o Firebase não está disponível (ex.: widget
  /// tests sem initializeApp) — push nunca bloqueia o app.
  Future<void> init() async {
    try {
      try {
        _permission = await _gateway.requestPermission();
        // APNs: pode ser null logo após o launch; não falha permanentemente —
        // o FCM token chega pelo refresh quando o APNs estiver disponível.
        final apns = await _gateway.getApnsToken();
        _fcmToken = await _gateway.getToken();
        // ignore: avoid_print — log operacional conciso (sem valores sensíveis)
        // ignore: avoid_print
        print(
          '[push] permission=$_permission apns=${apns == null ? "none" : "present"} '
          'fcm=${_fcmToken == null ? "none" : "present"}',
        );
      } catch (e) {
        // ignore: avoid_print
        print('[push] init degraded: ${e.runtimeType}');
      }

      _tokenSub = _gateway.onTokenRefresh.listen((token) {
        _fcmToken = token;
        // ignore: avoid_print
        print('[push] tokenRefresh');
        if (_deviceId != null) {
          // Re-registro idempotente: backend faz upsert por (person, token).
          _registerCurrent();
        }
      });

      _foregroundSub = _gateway.onForegroundMessage.listen(_handleForeground);
      _openedSub = _gateway.onMessageOpenedApp.listen(_handleOpened);

      // Cold-start: app encerrado + tap na notificação.
      try {
        final initial = await _gateway.getInitialMessage();
        if (initial != null) {
          _handleOpened(initial);
        }
      } catch (_) {
        // ignore: avoid_print
        print('[push] initialMessage unavailable');
      }
    } catch (e) {
      // Firebase ausente/indisponível (testes, plataforma sem config):
      // push degradado; login e navegação seguem normais.
      // ignore: avoid_print
      print('[push] unavailable: ${e.runtimeType}');
    }
  }

  /// Chamado quando a autenticação fica PRONTA (login/restore de sessão):
  /// obtém token atual e registra o device no backend.
  Future<void> onAuthenticated() async {
    final token = _fcmToken ?? await _gateway.getToken();
    if (token == null || token.isEmpty) {
      _notifyFailure('token_unavailable');
      return;
    }
    _fcmToken = token;
    await _registerCurrent();
  }

  /// Chamado no LOGOUT: desassocia o device do usuário atual no backend.
  /// O token FCM NÃO é apagado (mesmo device pode logar outra conta — o
  /// próximo registro associa ao novo usuário via JWT).
  Future<void> onLoggedOut() async {
    final device = _deviceId;
    _deviceId = null;
    if (device == null || device.isEmpty) return;
    try {
      await _registration.disable(device);
      // ignore: avoid_print
      print('[push] unregister=success');
    } catch (_) {
      _notifyFailure('unregister_failed');
    }
  }

  Future<void> _registerCurrent() async {
    final token = _fcmToken;
    if (token == null || token.isEmpty) {
      _notifyFailure('token_unavailable');
      return;
    }
    try {
      final id = await _registration.register(
        token: token,
        platform: _platform,
      );
      _deviceId = id.isEmpty ? _deviceId : id;
      // ignore: avoid_print
      print('[push] register=${id.isEmpty ? "accepted" : "success"}');
    } catch (_) {
      _notifyFailure('register_failed');
    }
  }

  void _notifyFailure(String message) {
    // ignore: avoid_print
    print('[push] $message');
    onRegisterFailure?.call(message);
  }

  // ── mensagens ────────────────────────────────────────────────────────

  void _handleForeground(Map<String, dynamic> data) {
    // Foreground: a mensagem de chat já chega via JuggleIM WS; um banner de
    // notificação duplicado seria ruído. Demais eventos (invite/challenge/
    // achievement) seguem o fluxo do app — sem flutter_local_notifications.
    // ignore: avoid_print
    print('[push] foreground type=${data['type'] ?? 'unknown'}');
  }

  void _handleOpened(Map<String, dynamic> data) {
    final link = NotificationDeepLink.fromPayload(data);
    if (link == null) {
      // ignore: avoid_print
      print('[push] opened type=malformed');
      return;
    }
    // ignore: avoid_print
    print('[push] opened type=${link.type.name}');
    // Deferred: navegação só após router/bootstrap prontos (cold-start).
    onOpenLink?.call(link);
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    await _foregroundSub?.cancel();
    await _openedSub?.cancel();
  }
}
