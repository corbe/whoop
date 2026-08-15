/// JuggleIM SDK wrapper (Phase 3 + Phase 6).
///
/// Única camada que conhece o SDK `juggle_im`. Responsabilidades (spec §5):
/// - mapear objetos do SDK para modelos de domínio (ChatMessage, reações);
/// - enviar texto/reply/imagem/arquivo (API nativa do SDK — spec §4);
/// - reações, read receipts, unread, mentions (tudo nativo no v0.10.72);
/// - nunca expor objetos internos do SDK para a UI.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juggle_im/juggle_im.dart';
import 'package:juggle_im/juggle_const.dart';
import 'package:juggle_im/model/connection_listener.dart';
import 'package:juggle_im/model/conversation.dart';
import 'package:juggle_im/model/get_message_option.dart';
import 'package:juggle_im/model/message.dart';
import 'package:juggle_im/model/message/file_message.dart';
import 'package:juggle_im/model/message/image_message.dart';
import 'package:juggle_im/model/message/text_message.dart';
import 'package:juggle_im/model/message_reaction.dart';
import 'package:juggle_im/model/message_mention_info.dart';
import 'package:juggle_im/model/send_message_option.dart';

import '../shared/models/chat.dart';
import 'chat_session_service.dart';

/// Estados de conexão expostos à UI (spec §15).
enum JuggleConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// Resultado de uma tentativa de envio.
class SendResult {
  const SendResult({required this.ok, this.messageId, this.errorCode, this.message});

  final bool ok;
  final String? messageId;
  final int? errorCode;
  final Message? message;
}

class JuggleImService {
  JuggleImService();

  final JuggleIm _sdk = JuggleIm.instance;

  final _statusController =
      StreamController<JuggleConnectionState>.broadcast();
  final _messageController = StreamController<ChatMessage>.broadcast();
  final _reactionController =
      StreamController<({String messageId, String emoji, bool added})>.broadcast();
  final _conversationController =
      StreamController<({String conversationId, int unreadCount})>.broadcast();
  final _totalUnreadController = StreamController<int>.broadcast();

  JuggleConnectionState _state = JuggleConnectionState.disconnected;
  ChatSession? _session;

  JuggleConnectionState get state => _state;
  ChatSession? get session => _session;

  Stream<JuggleConnectionState> get statusStream => _statusController.stream;
  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<({String messageId, String emoji, bool added})> get reactionStream =>
      _reactionController.stream;
  Stream<({String conversationId, int unreadCount})> get conversationStream =>
      _conversationController.stream;
  Stream<int> get totalUnreadStream => _totalUnreadController.stream;

  void _setState(JuggleConnectionState next) {
    _state = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  /// Map JuggleIM SDK status codes → domain states.
  static JuggleConnectionState _mapSdkStatus(int status) {
    switch (status) {
      case ConnectionStatus.connected:
        return JuggleConnectionState.connected;
      case ConnectionStatus.connecting:
        return JuggleConnectionState.connecting;
      case ConnectionStatus.failure:
        return JuggleConnectionState.failed;
      case ConnectionStatus.disconnected:
        return JuggleConnectionState.disconnected;
      default:
        return JuggleConnectionState.disconnected;
    }
  }

  /// Obtém o ChatSession do backend e conecta o SDK.
  Future<void> initializeAndConnect(ChatSession session) async {
    _session = session;
    _configureListeners();
    await _sdk.setServers([session.wsUrl]);
    await _sdk.init(_appKeyFromSession(session));
    _setState(JuggleConnectionState.connecting);
    await _sdk.connect(session.token);
  }

  String _appKeyFromSession(ChatSession session) => 'noana-hml';

  void _configureListeners() {
    _sdk.addConnectionListener('wellness', _ConnectionListenerImpl(
      onStatus: (status, code, extra) {
        _setState(_mapSdkStatus(status));
      },
    ));
    _sdk.onMessageReceive = (message) {
      if (!_messageController.isClosed) {
        _messageController.add(mapMessage(message));
      }
    };
    _sdk.onMessageReactionAdd = (conversation, reaction) {
      _emitReaction(reaction, added: true);
    };
    _sdk.onMessageReactionRemove = (conversation, reaction) {
      _emitReaction(reaction, added: false);
    };
    _sdk.onTotalUnreadMessageCountUpdate = (count) {
      if (!_totalUnreadController.isClosed) {
        _totalUnreadController.add(count);
      }
    };
  }

  void _emitReaction(MessageReaction reaction, {required bool added}) {
    if (_reactionController.isClosed) return;
    for (final item in reaction.itemList) {
      _reactionController.add((
        messageId: reaction.messageId,
        emoji: item.reactionId,
        added: added,
      ));
    }
  }

  /// Reconecta usando o token vigente.
  Future<void> reconnect() async {
    final session = _session;
    if (session == null) {
      _setState(JuggleConnectionState.failed);
      return;
    }
    _setState(JuggleConnectionState.reconnecting);
    await _sdk.connect(session.token);
  }

  Future<void> disconnect() async {
    await _sdk.disconnect(false);
    _setState(JuggleConnectionState.disconnected);
  }

  // ── mapeamento SDK → domínio (spec §5) ─────────────────────────────

  /// Converte uma Message do SDK em ChatMessage de domínio.
  ChatMessage mapMessage(Message m) {
    ChatMessageType type = ChatMessageType.text;
    String text = '';
    List<ChatAttachment> attachments = [];
    if (m.content is TextMessage) {
      text = (m.content as TextMessage).content;
    } else if (m.content is ImageMessage) {
      type = ChatMessageType.image;
      final img = m.content as ImageMessage;
      attachments = [
        ChatAttachment(
          name: 'image.jpg',
          mimeType: 'image/jpeg',
          size: img.size,
          url: img.url,
          localPath: img.localPath,
          width: img.width,
          height: img.height,
        ),
      ];
    } else if (m.content is FileMessage) {
      type = ChatMessageType.file;
      final f = m.content as FileMessage;
      attachments = [
        ChatAttachment(
          name: f.name,
          mimeType: f.type,
          size: f.size,
          url: f.url,
          localPath: f.localPath,
        ),
      ];
    }

    ChatReplyRef? replyTo;
    if (m.referredMsg != null) {
      final ref = m.referredMsg!;
      replyTo = ChatReplyRef(
        originalMessageId: ref.messageId,
        originalSenderId: ref.senderUserId,
        originalSenderName: ref.senderDisplayName,
        originalPreview: _previewOf(ref),
      );
    }

    final mentionMe = _isMentioningMe(m);

    return ChatMessage(
      id: m.messageId,
      conversationId: m.conversation.conversationId,
      conversationType: m.conversation.conversationType,
      senderId: m.senderUserId,
      senderName: m.senderDisplayName,
      type: type,
      text: text,
      replyTo: replyTo,
      attachments: attachments,
      createdAt: m.timestamp > 0
          ? DateTime.fromMillisecondsSinceEpoch(m.timestamp)
          : null,
      deliveryStatus: m.direction == MessageDirection.send
          ? (m.messageState == MessageState.fail
              ? ChatMessageStatus.failed
              : ChatMessageStatus.sent)
          : ChatMessageStatus.sent,
      readStatus: m.hasRead,
      mentionMe: mentionMe,
    );
  }

  bool _isMentioningMe(Message m) {
    final info = m.mentionInfo;
    if (info == null) return false;
    final me = _session?.userId;
    if (me == null) return false;
    if (info.type == MentionType.all) return true;
    return info.targetUsers.any((u) => u.userId == me);
  }

  static String _previewOf(Message m) {
    if (m.content is TextMessage) return (m.content as TextMessage).content;
    if (m.content is ImageMessage) return '[Imagem]';
    if (m.content is FileMessage) return '[Arquivo]';
    return '';
  }

  // ── envio (spec §7, §13, §17) ──────────────────────────────────────

  /// Envia texto com suporte a reply (spec §7 — referredMsgId nativo).
  Future<SendResult> sendText(
    String conversationId,
    int conversationType,
    String text, {
    ChatReplyRef? replyTo,
  }) {
    final completer = Completer<SendResult>();
    final message = TextMessage.content(text);
    final conversation = Conversation(conversationType, conversationId);
    final option = replyTo == null
        ? null
        : (SendMessageOption()..referredMessageId = replyTo.originalMessageId);
    _sdk.sendMessage(message, conversation, (msg, errorCode) {
      if (completer.isCompleted) return;
      completer.complete(SendResult(
        ok: errorCode == 0,
        messageId: msg.messageId,
        errorCode: errorCode,
        message: msg,
      ));
    }, option);
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => const SendResult(ok: false, errorCode: -1),
    );
  }

  /// Envia imagem (jg:img nativo, SDK faz upload — spec §13–§14).
  Future<SendResult> sendImage(
    String conversationId,
    int conversationType,
    String localPath, {
    void Function(int progress)? onProgress,
  }) {
    final completer = Completer<SendResult>();
    final message = ImageMessage()
      ..localPath = localPath
      ..size = 0;
    final conversation = Conversation(conversationType, conversationId);
    _sdk.sendMediaMessage(
      message,
      conversation,
      (msg, errorCode) {
        if (completer.isCompleted) return;
        completer.complete(SendResult(
          ok: errorCode == 0,
          messageId: msg.messageId,
          errorCode: errorCode,
          message: msg,
        ));
      },
      (msg, progress) {
        onProgress?.call(progress);
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => const SendResult(ok: false, errorCode: -1),
    );
  }

  /// Envia arquivo (jg:file nativo — spec §17–§18).
  Future<SendResult> sendFile(
    String conversationId,
    int conversationType,
    String localPath, {
    required String name,
    required String mimeType,
    required int size,
    void Function(int progress)? onProgress,
  }) {
    final completer = Completer<SendResult>();
    final message = FileMessage()
      ..localPath = localPath
      ..name = name
      ..type = mimeType
      ..size = size;
    final conversation = Conversation(conversationType, conversationId);
    _sdk.sendMediaMessage(
      message,
      conversation,
      (msg, errorCode) {
        if (completer.isCompleted) return;
        completer.complete(SendResult(
          ok: errorCode == 0,
          messageId: msg.messageId,
          errorCode: errorCode,
          message: msg,
        ));
      },
      (msg, progress) {
        onProgress?.call(progress);
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => const SendResult(ok: false, errorCode: -1),
    );
  }

  // ── reações (spec §10–§12) ─────────────────────────────────────────
  //
  // O catálogo/quick reactions vêm do backend (GET /wellness/chat/reactions/,
  // controlado via Django Admin). O SDK aceita QUALQUER emoji como reactionId
  // — sem allowlist hardcoded aqui (ela quebraria emojis do catálogo/picker).

  Future<bool> addReaction(String messageId, String conversationId, String emoji) async {
    if (emoji.trim().isEmpty) return false;
    final code = await _sdk.addMessageReaction(
      messageId,
      Conversation(ConversationType.group, conversationId),
      emoji,
    );
    return code == 0;
  }

  Future<bool> removeReaction(String messageId, String conversationId, String emoji) async {
    final code = await _sdk.removeMessageReaction(
      messageId,
      Conversation(ConversationType.group, conversationId),
      emoji,
    );
    return code == 0;
  }

  /// Reações agregadas de uma lista de mensagens (spec §11).
  Future<Map<String, List<ChatReaction>>> getReactions(
    List<String> messageIds,
    String conversationId,
  ) async {
    final result = await _sdk.getMessagesReaction(
      messageIds,
      Conversation(ConversationType.group, conversationId),
    );
    final map = <String, List<ChatReaction>>{};
    final me = _session?.userId;
    for (final reaction in result.t ?? const <MessageReaction>[]) {
      final items = <ChatReaction>[];
      for (final item in reaction.itemList) {
        items.add(ChatReaction(
          emoji: item.reactionId,
          count: item.userInfoList.length,
          mine: item.userInfoList.any((u) => u.userId == me),
        ));
      }
      map[reaction.messageId] = items;
    }
    return map;
  }

  // ── read / unread (spec §21–§23) ───────────────────────────────────

  /// Marca a conversa como lida (spec §23 — só quando aberta/visível).
  Future<void> markConversationRead(String conversationId, int conversationType) async {
    await _sdk.clearUnreadCount(Conversation(conversationType, conversationId));
  }

  Future<int> getTotalUnreadCount() async {
    return _sdk.getTotalUnreadCount();
  }

  Future<int> getConversationUnread(String conversationId, int conversationType) async {
    final info = await _sdk.getConversationInfo(
      Conversation(conversationType, conversationId),
    );
    return info?.unreadCount ?? 0;
  }

  // ── histórico (spec §50) ───────────────────────────────────────────

  /// Carrega uma página de histórico (mais antiga) — spec §50.
  Future<List<ChatMessage>> loadHistory(
    String conversationId,
    int conversationType, {
    int count = 30,
    DateTime? before,
  }) async {
    final conversation = Conversation(conversationType, conversationId);
    final option = GetMessageOption()
      ..count = count
      ..startTime = before?.millisecondsSinceEpoch ?? 0;
    final result = await _sdk.getMessages(
      conversation,
      MessageDirection.receive,
      option,
    );
    final raw = result.t ?? const <Message>[];
    return raw.map(mapMessage).toList();
  }

  void dispose() {
    _sdk.removeConnectionListener('wellness');
    _statusController.close();
    _messageController.close();
    _reactionController.close();
    _conversationController.close();
    _totalUnreadController.close();
  }
}

class _ConnectionListenerImpl implements ConnectionListener {
  _ConnectionListenerImpl({required this.onStatus});

  final void Function(int status, int code, String extra) onStatus;

  @override
  void onConnectionStatusChange(int connectionStatus, int code, String extra) {
    onStatus(connectionStatus, code, extra);
  }

  @override
  void onDbOpen() {}

  @override
  void onDbClose() {}
}

/// Riverpod provider for [JuggleImService].
final juggleImServiceProvider = Provider<JuggleImService>((ref) {
  final service = JuggleImService();
  ref.onDispose(service.dispose);
  return service;
});

/// Estado de conexão atual.
final juggleConnectionStateProvider = StreamProvider<JuggleConnectionState>((ref) {
  return ref.watch(juggleImServiceProvider).statusStream;
});

/// Mensagens recebidas em tempo real (domínio, spec §5).
final juggleMessagesProvider = StreamProvider<ChatMessage>((ref) {
  return ref.watch(juggleImServiceProvider).messageStream;
});

/// Eventos de reação em tempo real (spec §12).
final juggleReactionsProvider =
    StreamProvider<({String messageId, String emoji, bool added})>((ref) {
  return ref.watch(juggleImServiceProvider).reactionStream;
});

/// Total unread em tempo real (spec §22).
final juggleTotalUnreadProvider = StreamProvider<int>((ref) {
  return ref.watch(juggleImServiceProvider).totalUnreadStream;
});
