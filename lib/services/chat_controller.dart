/// Community chat controller (Phase 6, spec §48–§51).
///
/// Single place for message mutations: load history (paginated), listen
/// realtime, send text/reply/image/file, reactions, mark read, retry failed.
/// Widgets never mutate messages directly.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/models/chat.dart';
import 'chat_session_service.dart';
import 'juggle_im_service.dart';

/// One conversation's state: messages (deduped by id), pagination, send queue.
class ChatState {
  ChatState({
    List<ChatMessage> messages = const [],
    this.hasMore = true,
    this.loadingOlder = false,
    this.initialLoading = true,
    this.error,
    this.replyTarget,
    this.uploading = false,
  }) : messages = List.of(messages);

  final List<ChatMessage> messages;
  final bool hasMore;
  final bool loadingOlder;
  final bool initialLoading;
  final String? error;
  ChatReplyRef? replyTarget;
  final bool uploading;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? hasMore,
    bool? loadingOlder,
    bool? initialLoading,
    String? error,
    bool clearError = false,
    ChatReplyRef? replyTarget,
    bool clearReplyTarget = false,
    bool? uploading,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      hasMore: hasMore ?? this.hasMore,
      loadingOlder: loadingOlder ?? this.loadingOlder,
      initialLoading: initialLoading ?? this.initialLoading,
      error: clearError ? null : (error ?? this.error),
      replyTarget: clearReplyTarget ? null : (replyTarget ?? this.replyTarget),
      uploading: uploading ?? this.uploading,
    );
  }
}

class ChatController {
  ChatController({
    required JuggleImService juggle,
    required ChatSessionService chatSession,
    required this.conversationId,
    required this.conversationType,
  })  : _juggle = juggle,
        _chatSession = chatSession;

  /// Identidade autoritativa do usuário atual no JuggleIM (source of truth
  /// para ownership de mensagens — NUNCA derivar de display name).
  String? get sessionUserId => _juggle.session?.userId;

  final JuggleImService _juggle;
  final ChatSessionService _chatSession;
  final String conversationId;
  final int conversationType;

  final _stateController = StreamController<ChatState>.broadcast();
  ChatState _state = ChatState();
  StreamSubscription? _msgSub;
  StreamSubscription? _reactionSub;

  Stream<ChatState> get stateStream => _stateController.stream;
  ChatState get current => _state;

  /// Inicia: conecta (se preciso), carrega a 1ª página, assina realtime.
  ///
  /// Ownership: `message.senderId == sessionUserId` (Juggle ID autoritativo).
  /// A sessão é SEMPRE verificada contra o usuário autenticado: obtainSession
  /// devolve a sessão do token atual; se o userId da sessão em cache for de
  /// OUTRA conta (troca de usuário sem reinício), reseta e reconecta — nunca
  /// reutiliza a identidade do usuário anterior.
  Future<void> start() async {
    _subscribeRealtime();
    final fresh = await _chatSession.obtainSession();
    final cached = _juggle.session;
    if (cached == null ||
        cached.userId != fresh.userId ||
        _juggle.state != JuggleConnectionState.connected) {
      if (cached != null && cached.userId != fresh.userId) {
        await _juggle.resetSession(); // descarta identidade da conta anterior
      }
      await _juggle.initializeAndConnect(fresh);
    }
    await _juggle.markConversationRead(conversationId, conversationType);
    await loadOlder(reset: true);
    _subscribeMessages();
  }

  void _subscribeMessages() {
    _msgSub ??= _juggle.messageStream.listen((message) {
      if (message.conversationId != conversationId) return;
      _upsert(message, notify: true);
    });
  }

  void _subscribeRealtime() {
    _reactionSub ??= _juggle.reactionStream.listen((event) {
      if (event.added) {
        _applyReaction(event.messageId, event.emoji, add: true);
      } else {
        _applyReaction(event.messageId, event.emoji, add: false);
      }
    });
  }

  /// Carrega página mais antiga (spec §50) ou reseta com a mais recente.
  Future<void> loadOlder({bool reset = false}) async {
    if (!reset && (!_state.hasMore || _state.loadingOlder)) return;
    final before = reset
        ? null
        : (_state.messages.isEmpty
            ? null
            : _state.messages
                .map((m) => m.createdAt)
                .whereType<DateTime>()
                .reduce((a, b) => a.isBefore(b) ? a : b));
    _emit(_state.copyWith(loadingOlder: true, initialLoading: reset));
    try {
      final page = await _juggle.loadHistory(
        conversationId,
        conversationType,
        before: before,
      );
      final merged = _mergeDedup(reset ? page : [...page, ..._state.messages]);
      _emit(_state.copyWith(
        messages: merged,
        hasMore: page.length >= 30,
        loadingOlder: false,
        initialLoading: false,
        error: null,
      ));
      if (!reset) {
        await _juggle.markConversationRead(conversationId, conversationType);
      }
    } catch (e) {
      _emit(_state.copyWith(
        loadingOlder: false,
        initialLoading: false,
        error: 'Falha ao carregar histórico: $e',
      ));
    }
  }

  /// Dedupe por id estável (spec §51): história + realtime + ack = 1 cópia.
  List<ChatMessage> _mergeDedup(List<ChatMessage> incoming) {
    final byId = <String, ChatMessage>{};
    for (final m in incoming) {
      final existing = byId[m.id];
      if (existing == null || m.reactions.isNotEmpty) {
        byId[m.id] = m;
      }
    }
    final merged = byId.values.toList()
      ..sort((a, b) {
        final ta = a.createdAt ?? DateTime(0);
        final tb = b.createdAt ?? DateTime(0);
        return ta.compareTo(tb);
      });
    return merged;
  }

  void _upsert(ChatMessage message, {bool notify = true}) {
    final idx = _state.messages.indexWhere((m) => m.id == message.id);
    final messages = List<ChatMessage>.of(_state.messages);
    if (idx >= 0) {
      messages[idx] = message;
    } else {
      messages.add(message);
      messages.sort((a, b) {
        final ta = a.createdAt ?? DateTime(0);
        final tb = b.createdAt ?? DateTime(0);
        return ta.compareTo(tb);
      });
    }
    _emit(_state.copyWith(messages: messages), notify: notify);
  }

  void _applyReaction(String messageId, String emoji, {required bool add}) {
    final idx = _state.messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final messages = List<ChatMessage>.of(_state.messages);
    final msg = messages[idx];
    final reactions = List<ChatReaction>.of(msg.reactions);
    final rIdx = reactions.indexWhere((r) => r.emoji == emoji);
    if (add) {
      if (rIdx >= 0) {
        reactions[rIdx] = reactions[rIdx].copyWith(count: reactions[rIdx].count + 1);
      } else {
        reactions.add(ChatReaction(emoji: emoji, count: 1));
      }
    } else {
      if (rIdx >= 0) {
        final updated = reactions[rIdx].copyWith(count: reactions[rIdx].count - 1);
        if (updated.count <= 0) {
          reactions.removeAt(rIdx);
        } else {
          reactions[rIdx] = updated;
        }
      }
    }
    messages[idx] = msg.copyWith(reactions: reactions);
    _emit(_state.copyWith(messages: messages));
  }

  // ── envio (spec §49 — otimista) ────────────────────────────────────

  ChatMessage _pending(String id, String text, ChatReplyRef? replyTo,
      [List<ChatAttachment> attachments = const []]) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      conversationType: conversationType,
      senderId: _juggle.session?.userId ?? 'me',
      senderName: 'Você',
      type: attachments.isNotEmpty
          ? (attachments.first.isImage ? ChatMessageType.image : ChatMessageType.file)
          : ChatMessageType.text,
      text: text,
      replyTo: replyTo,
      attachments: attachments,
      createdAt: DateTime.now(),
      deliveryStatus: ChatMessageStatus.sending,
      localPending: true,
    );
  }

  Future<SendResult> sendText(String text) async {
    final replyTo = _state.replyTarget;
    final pendingId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    _upsert(_pending(pendingId, text, replyTo));
    _emit(_state.copyWith(clearReplyTarget: true)); // limpa reply (spec §8)
    final result = await _juggle.sendText(
      conversationId,
      conversationType,
      text,
      replyTo: replyTo,
    );
    _finalizeSend(pendingId, result);
    return result;
  }

  Future<SendResult> sendImage(String localPath,
      {void Function(int)? onProgress}) async {
    final pendingId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    _upsert(_pending(
      pendingId,
      '',
      _state.replyTarget,
      [ChatAttachment(name: 'image.jpg', mimeType: 'image/jpeg', size: 0, localPath: localPath)],
    ));
    final result = await _juggle.sendImage(
      conversationId,
      conversationType,
      localPath,
      onProgress: onProgress,
    );
    _finalizeSend(pendingId, result);
    return result;
  }

  Future<SendResult> sendFile(
    String localPath, {
    required String name,
    required String mimeType,
    required int size,
    void Function(int)? onProgress,
  }) async {
    final pendingId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    _upsert(_pending(
      pendingId,
      '',
      _state.replyTarget,
      [ChatAttachment(name: name, mimeType: mimeType, size: size, localPath: localPath)],
    ));
    final result = await _juggle.sendFile(
      conversationId,
      conversationType,
      localPath,
      name: name,
      mimeType: mimeType,
      size: size,
      onProgress: onProgress,
    );
    _finalizeSend(pendingId, result);
    return result;
  }

  void _finalizeSend(String pendingId, SendResult result) {
    if (result.ok && result.message != null) {
      // Remove o bubble local e insere a mensagem real (dedup por id — o
      // echo do servidor pode já ter chegado via stream, spec §51).
      final messages = List<ChatMessage>.of(_state.messages)
        ..removeWhere((m) => m.id == pendingId);
      _emit(_state.copyWith(messages: messages));
      _upsert(_juggle.mapMessage(result.message!));
      return;
    }
    final idx = _state.messages.indexWhere((m) => m.id == pendingId);
    if (idx < 0) return;
    final messages = List<ChatMessage>.of(_state.messages);
    messages[idx] = messages[idx].copyWith(
      deliveryStatus: ChatMessageStatus.failed,
      localPending: false,
    );
    _emit(_state.copyWith(messages: messages));
  }

  /// Retry de mensagem falha (spec §49/§64) — reenvia o texto.
  Future<void> retryFailed(ChatMessage message) async {
    if (message.type == ChatMessageType.text) {
      final result = await _juggle.sendText(
        conversationId,
        conversationType,
        message.text,
        replyTo: message.replyTo,
      );
      _finalizeSend(message.id, result);
    }
  }

  // ── reações / read ─────────────────────────────────────────────────

  Future<bool> addReaction(String messageId, String emoji) =>
      _juggle.addReaction(messageId, conversationId, emoji);

  Future<bool> removeReaction(String messageId, String emoji) =>
      _juggle.removeReaction(messageId, conversationId, emoji);

  Future<void> markRead() =>
      _juggle.markConversationRead(conversationId, conversationType);

  Future<Map<String, List<ChatReaction>>> fetchReactions(List<String> ids) =>
      _juggle.getReactions(ids, conversationId);

  void setReplyTarget(ChatReplyRef? reply) {
    _emit(_state.copyWith(replyTarget: reply));
  }

  void _emit(ChatState next, {bool notify = true}) {
    _state = next;
    if (notify && !_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  void dispose() {
    _msgSub?.cancel();
    _reactionSub?.cancel();
    _stateController.close();
  }
}

/// Provider factory: cria o controller de uma conversa (family por id).
final chatControllerProvider =
    Provider.family<ChatController, ({String conversationId, int conversationType})>(
        (ref, params) {
  final controller = ChatController(
    juggle: ref.watch(juggleImServiceProvider),
    chatSession: ref.watch(chatSessionServiceProvider),
    conversationId: params.conversationId,
    conversationType: params.conversationType,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
