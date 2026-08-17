import 'package:flutter/foundation.dart';

import '../core/network/api_client.dart';
import '../shared/models/chat.dart';

/// Reporta evento app-side de mensagem ENVIADA (push — spec §19).
///
/// O im-server do JuggleIM não tem webhook (§20) — o BACKEND só sabe de uma
/// mensagem se o app reportar via POST /v1/wellness/chat/messages/sent/.
/// Fire-and-forget: falha de report NUNCA afeta o envio/UX do chat (push é
/// não-crítico — loga e segue).
class ChatPushReporter {
  ChatPushReporter({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  static const String _base = '/wellness/chat/messages/sent/';

  /// POST /wellness/chat/messages/sent/ — {community_uuid, message_id,
  /// text, mentioned_juggle_ids?, reply_to_message_id?, reply_to_sender_id?}.
  Future<void> reportMessageSent({
    required String communityUuid,
    required String messageId,
    required String text,
    List<String> mentionedJuggleIds = const [],
    String? replyToMessageId,
    String? replyToSenderId,
  }) async {
    try {
      await _api.post(
        _base,
        body: {
          'community_uuid': communityUuid,
          'message_id': messageId,
          'text': text,
          if (mentionedJuggleIds.isNotEmpty)
            'mentioned_juggle_ids': mentionedJuggleIds,
          if (replyToMessageId != null && replyToMessageId.isNotEmpty)
            'reply_to_message_id': replyToMessageId,
          if (replyToSenderId != null && replyToSenderId.isNotEmpty)
            'reply_to_sender_id': replyToSenderId,
        },
      );
    } catch (e) {
      // Push é não-crítico: report falho não pode quebrar o chat.
      debugPrint('[push] chat event report failed: ${e.runtimeType}');
    }
  }
}

/// Extrai o payload do report a partir do envio concluído.
///
/// [communityConversationId] é o id JuggleIM da conversa
/// (ex.: "community:&lt;uuid&gt;") — apenas conversas de GRUPO reportam
/// (chat de comunidade); conversas 1:1 não têm comunidade no backend.
class ChatMessageSentReport {
  const ChatMessageSentReport({
    required this.communityUuid,
    required this.messageId,
    required this.text,
    this.mentionedJuggleIds = const [],
    this.replyToMessageId,
    this.replyToSenderId,
  });

  final String communityUuid;
  final String messageId;
  final String text;
  final List<String> mentionedJuggleIds;
  final String? replyToMessageId;
  final String? replyToSenderId;

  /// Monta o report a partir do envio real (finalId + replyTo do pending).
  factory ChatMessageSentReport.fromSend({
    required String communityConversationId,
    required String finalMessageId,
    required String text,
    ChatReplyRef? replyTo,
    List<String> mentionedJuggleIds = const [],
  }) {
    const prefix = 'community:';
    final communityUuid = communityConversationId.startsWith(prefix)
        ? communityConversationId.substring(prefix.length)
        : communityConversationId;
    return ChatMessageSentReport(
      communityUuid: communityUuid,
      messageId: finalMessageId,
      text: text,
      mentionedJuggleIds: mentionedJuggleIds,
      replyToMessageId: replyTo?.originalMessageId,
      replyToSenderId: replyTo?.originalSenderId,
    );
  }
}
