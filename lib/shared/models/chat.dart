/// Chat domain models (Phase 6, spec §5–§6).
///
/// Application-level models — JuggleIM SDK objects are mapped to these inside
/// JuggleImService; the UI never touches SDK internals.
library;

enum ChatMessageType { text, image, file, system }

enum ChatMessageStatus { sending, sent, delivered, read, failed }

/// A message in a community/private conversation.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.conversationType,
    required this.senderId,
    this.senderName = '',
    this.senderAvatar = '',
    required this.type,
    this.text = '',
    this.replyTo,
    this.attachments = const [],
    this.reactions = const [],
    this.createdAt,
    this.updatedAt,
    this.deliveryStatus = ChatMessageStatus.sent,
    this.readStatus = false,
    this.mentionMe = false,
    this.localPending = false,
  });

  final String id; // stable message id (dedupe key)
  final String conversationId;
  final int conversationType;
  final String senderId;
  final String senderName;
  final String senderAvatar;
  final ChatMessageType type;
  final String text;
  final ChatReplyRef? replyTo;
  final List<ChatAttachment> attachments;
  final List<ChatReaction> reactions;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final ChatMessageStatus deliveryStatus;
  final bool readStatus;
  final bool mentionMe;
  final bool localPending;

  ChatMessage copyWith({
    String? id,
    String? text,
    List<ChatAttachment>? attachments,
    List<ChatReaction>? reactions,
    ChatMessageStatus? deliveryStatus,
    bool? readStatus,
    bool? localPending,
    ChatReplyRef? replyTo,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId,
      conversationType: conversationType,
      senderId: senderId,
      senderName: senderName,
      senderAvatar: senderAvatar,
      type: type,
      text: text ?? this.text,
      replyTo: replyTo,
      attachments: attachments ?? this.attachments,
      reactions: reactions ?? this.reactions,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      readStatus: readStatus ?? this.readStatus,
      mentionMe: mentionMe,
      localPending: localPending ?? this.localPending,
    );
  }
}

/// Reply reference (spec §7) — stable info to render context even when the
/// original message is outside the loaded page.
class ChatReplyRef {
  const ChatReplyRef({
    required this.originalMessageId,
    required this.originalSenderId,
    required this.originalSenderName,
    required this.originalPreview,
  });

  final String originalMessageId;
  final String originalSenderId;
  final String originalSenderName;
  final String originalPreview;

  ChatReplyRef copyWith({String? originalSenderName}) => ChatReplyRef(
        originalMessageId: originalMessageId,
        originalSenderId: originalSenderId,
        originalSenderName: originalSenderName ?? this.originalSenderName,
        originalPreview: originalPreview,
      );

  Map<String, dynamic> toJson() => {
        'original_message_id': originalMessageId,
        'original_sender_id': originalSenderId,
        'original_sender_name': originalSenderName,
        'original_preview': originalPreview,
      };
}

/// Attachment (spec §17–§18).
class ChatAttachment {
  const ChatAttachment({
    required this.name,
    required this.mimeType,
    required this.size,
    this.url = '',
    this.localPath = '',
    this.width,
    this.height,
  });

  final String name;
  final String mimeType;
  final int size;
  final String url;
  final String localPath;
  final int? width;
  final int? height;

  bool get isImage => mimeType.startsWith('image/');
}

/// Reaction (spec §10–§11) — emoji + safe social identity of reactors.
class ChatReaction {
  const ChatReaction({required this.emoji, required this.count, this.mine = false});

  final String emoji;
  final int count;
  final bool mine;

  ChatReaction copyWith({int? count, bool? mine}) =>
      ChatReaction(emoji: emoji, count: count ?? this.count, mine: mine ?? this.mine);
}

/// Reação configurável do catálogo Wellness (Community UX hardening).
///
/// O catálogo final vem do backend (GET /v1/wellness/chat/reactions/),
/// controlado via Django Admin — NÃO é hardcoded no app. Campos públicos:
/// emoji, label, category, sort_order, is_quick.
class WellnessReaction {
  const WellnessReaction({
    required this.emoji,
    this.label = '',
    this.category = 'social',
    this.sortOrder = 0,
    this.isQuick = false,
  });

  final String emoji;
  final String label;
  final String category;
  final int sortOrder;
  final bool isQuick;

  factory WellnessReaction.fromJson(Map<String, dynamic> json) {
    return WellnessReaction(
      emoji: json['emoji'] as String,
      label: (json['label'] as String?) ?? '',
      category: (json['category'] as String?) ?? 'social',
      sortOrder: (json['sort_order'] as int?) ?? 0,
      isQuick: (json['is_quick'] as bool?) ?? false,
    );
  }
}

/// Catálogo de reações: quick reactions (barra rápida) + catálogo completo.
class ReactionCatalog {
  const ReactionCatalog({required this.reactions, required this.quick});

  final List<WellnessReaction> reactions;

  /// Emojis da barra rápida (is_quick, na ordem configurada).
  final List<String> quick;

  factory ReactionCatalog.fromList(List<dynamic> items) {
    final reactions = items
        .map((e) => WellnessReaction.fromJson(e as Map<String, dynamic>))
        .toList();
    final quick = reactions
        .where((r) => r.isQuick)
        .map((r) => r.emoji)
        .toList();
    return ReactionCatalog(reactions: reactions, quick: quick);
  }
}

/// Conversation summary for the chat list (spec §52).
class ChatConversationSummary {
  const ChatConversationSummary({
    required this.conversationId,
    required this.name,
    this.portrait = '',
    required this.lastPreview,
    required this.lastSenderName,
    required this.lastType,
    required this.lastTimestamp,
    required this.unreadCount,
  });

  final String conversationId;
  final String name;
  final String portrait;
  final String lastPreview;
  final String lastSenderName;
  final ChatMessageType lastType;
  final DateTime? lastTimestamp;
  final int unreadCount;
}
