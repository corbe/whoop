/// Deep-link / notificação de navegação (fase 9 + fase push).
///
/// Payload SEGURO: apenas tipo + ids de destino neutros (community uuid,
/// invitation token, challenge uuid, achievement id). NUNCA: JWT, Cognito
/// sub, e-mail, dados fisiológicos ou medidas de saúde.
library;

enum DeepLinkType { community, communityInvite, challenge, achievement }

/// Modelo do payload de navegação recebido na notificação.
class NotificationDeepLink {
  const NotificationDeepLink({required this.type, required this.targetId})
      : extras = const {};

  final DeepLinkType type;

  /// community uuid / invitation token / challenge uuid / achievement id —
  /// identificador neutro.
  final String targetId;

  /// Campos adicionais opcionais (message_id no chat, final_rank, code).
  final Map<String, dynamic> extras;

  const NotificationDeepLink.withExtras({
    required this.type,
    required this.targetId,
    this.extras = const {},
  });

  /// Serialização do payload enviado pela notificação (backend envia só isto).
  Map<String, String> toPayload() => {
        'type': type.name,
        'target_id': targetId,
        ...extras.map((k, v) => MapEntry(k, v.toString())),
      };

  /// Parse seguro: ignora campos desconhecidos; exige type + destino válidos.
  /// Backend envia {type, community_uuid/message_id} (chat), {community_uuid,
  /// invitation_token} (invite), {challenge_uuid} (challenge),
  /// {achievement_uuid, code} (achievement) — target_id é fallback.
  static NotificationDeepLink? fromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final typeName = payload['type']?.toString();
    if (typeName == null) return null;
    final type = switch (typeName) {
      'chat' || 'community' => DeepLinkType.community,
      'community_invite' => DeepLinkType.communityInvite,
      'challenge' => DeepLinkType.challenge,
      'achievement' => DeepLinkType.achievement,
      _ => null,
    };
    if (type == null) return null;
    final targetId = (payload['target_id'] ??
            payload['community_uuid'] ??
            payload['challenge_uuid'] ??
            payload['achievement_uuid'])
        ?.toString();
    if (targetId == null || targetId.isEmpty) return null;
    final extras = <String, dynamic>{};
    for (final key in const [
      'community_uuid',
      'message_id',
      'invitation_token',
      'challenge_uuid',
      'final_rank',
      'achievement_uuid',
      'code',
    ]) {
      final value = payload[key];
      if (value != null) extras[key] = value;
    }
    return NotificationDeepLink.withExtras(type: type, targetId: targetId, extras: extras);
  }
}
