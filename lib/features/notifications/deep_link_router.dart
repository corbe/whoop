import 'deep_link.dart';

/// Roteamento de notificação com GATE de inicialização (fase 9).
///
/// Cold-start NUNCA navega antes de: restore de sessão Cognito → bootstrap
/// wellness → router pronto. O consumidor injeta a cadeia de readiness; este
/// serviço garante a ORDEM e só então entrega o destino.
typedef ReadinessGate = Future<void> Function();

class DeepLinkRouter {
  DeepLinkRouter({
    required ReadinessGate waitForSessionRestore,
    required ReadinessGate waitForWellnessBootstrap,
    required ReadinessGate waitForRouterReady,
    required Future<void> Function(NotificationDeepLink) navigate,
  })  : _waitForSessionRestore = waitForSessionRestore,
        _waitForWellnessBootstrap = waitForWellnessBootstrap,
        _waitForRouterReady = waitForRouterReady,
        _navigate = navigate;

  final ReadinessGate _waitForSessionRestore;
  final ReadinessGate _waitForWellnessBootstrap;
  final ReadinessGate _waitForRouterReady;
  final Future<void> Function(NotificationDeepLink) _navigate;

  /// Ordem estrita: sessão → bootstrap → router → navegação.
  Future<bool> handle(NotificationDeepLink link) async {
    await _waitForSessionRestore();
    await _waitForWellnessBootstrap();
    await _waitForRouterReady();
    await _navigate(link);
    return true;
  }
}
