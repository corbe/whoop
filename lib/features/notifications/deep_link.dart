/// Deep-link / notificação de navegação (fase 9).
///
/// Payload SEGURO: apenas tipo + id de destino (community uuid / chat privado).
/// NUNCA: JWT, Cognito sub, e-mail, dados fisiológicos ou medidas de saúde.
library;

enum DeepLinkType { community, privateChat }

/// Modelo do payload de navegação recebido na notificação.
class NotificationDeepLink {
  const NotificationDeepLink({required this.type, required this.targetId});

  final DeepLinkType type;

  /// community uuid ou user id do chat privado — identificador neutro.
  final String targetId;

  /// Serialização do payload enviado pela notificação (backend envia só isto).
  Map<String, String> toPayload() => {'type': type.name, 'target_id': targetId};

  /// Parse seguro: ignora campos desconhecidos; exige type + target_id válidos.
  static NotificationDeepLink? fromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final typeName = payload['type']?.toString();
    final targetId = payload['target_id']?.toString();
    if (typeName == null || targetId == null || targetId.isEmpty) return null;
    final type = switch (typeName) {
      'community' => DeepLinkType.community,
      'privateChat' => DeepLinkType.privateChat,
      _ => null,
    };
    if (type == null) return null;
    return NotificationDeepLink(type: type, targetId: targetId);
  }
}
