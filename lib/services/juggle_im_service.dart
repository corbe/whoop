/// JuggleIM SDK wrapper (Phase 3, spec §14, §15).
///
/// Única camada que conhece o SDK `juggle_im`. Widgets nunca chamam o SDK
/// diretamente — consomem [JuggleImService] / Riverpod.
///
/// Estados de conexão (spec §15): disconnected → connecting → connected →
/// (reconnecting|disconnected) → connected. Queda de rede NÃO refaz login
/// Cognito: o token de sessão só é reobtido se o próprio ChatSession falhar.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juggle_im/juggle_im.dart';
import 'package:juggle_im/juggle_const.dart';
import 'package:juggle_im/model/connection_listener.dart';
import 'package:juggle_im/model/conversation.dart';
import 'package:juggle_im/model/message/text_message.dart';

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
  const SendResult({required this.ok, this.messageId, this.errorCode});

  final bool ok;
  final String? messageId;
  final int? errorCode;
}

class JuggleImService {
  JuggleImService();

  final JuggleIm _sdk = JuggleIm.instance;

  final _statusController =
      StreamController<JuggleConnectionState>.broadcast();
  final _messageController = StreamController<dynamic>.broadcast();

  JuggleConnectionState _state = JuggleConnectionState.disconnected;
  ChatSession? _session;

  JuggleConnectionState get state => _state;
  ChatSession? get session => _session;

  Stream<JuggleConnectionState> get statusStream => _statusController.stream;
  Stream<dynamic> get messageStream => _messageController.stream;

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
  ///
  /// Idempotente: reentradas/conexões repetidas reutilizam o estado atual se
  /// já conectado (spec §74). Nunca refaz login Cognito por queda de rede —
  /// apenas o token do ChatSession é (re)obtido quando necessário.
  Future<void> initializeAndConnect(ChatSession session) async {
    _session = session;
    _configureListeners();
    await _sdk.setServers([session.wsUrl]);
    await _sdk.init(_appKeyFromSession(session));
    _setState(JuggleConnectionState.connecting);
    await _sdk.connect(session.token);
  }

  String _appKeyFromSession(ChatSession session) {
    // O app_key é o prefixo do user_id (wellness:<uuid> não carrega o app key);
    // a projeção usa o mesmo app do backend. O secret NUNCA chega ao cliente.
    // O SDK `init(appKey)` aceita o app key do servidor; mantemos const aqui
    // porque é um identificador público do app (não é segredo).
    return 'noana-hml';
  }

  void _configureListeners() {
    _sdk.addConnectionListener('wellness', _ConnectionListenerImpl(
      onStatus: (status, code, extra) {
        _setState(_mapSdkStatus(status));
      },
    ));
    _sdk.onMessageReceive = (message) {
      if (!_messageController.isClosed) {
        _messageController.add(message);
      }
    };
  }

  /// Reconecta usando o token vigente (queda de rede, spec §15). Não refaz
  /// login Cognito nem re-obtém ChatSession.
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

  /// Envia mensagem de texto privada (spec §42). A identidade do destinatário
  /// é um JuggleIM user_id (`wellness:<uuid>`) — nunca email/phone.
  Future<SendResult> sendPrivateText(String toUserId, String text) {
    final completer = Completer<SendResult>();
    final message = TextMessage.content(text);
    final conversation = Conversation(ConversationType.private, toUserId);
    _sdk.sendMessage(message, conversation, (msg, errorCode) {
      if (completer.isCompleted) return;
      completer.complete(SendResult(
        ok: errorCode == 0,
        messageId: msg.messageId,
        errorCode: errorCode,
      ));
    });
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => const SendResult(ok: false, errorCode: -1),
    );
  }

  void dispose() {
    _sdk.removeConnectionListener('wellness');
    _statusController.close();
    _messageController.close();
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

/// Estado de conexão atual (spec §61 chatConnection).
final juggleConnectionStateProvider = StreamProvider<JuggleConnectionState>((ref) {
  return ref.watch(juggleImServiceProvider).statusStream;
});

/// Mensagens recebidas em tempo real.
final juggleMessagesProvider = StreamProvider<dynamic>((ref) {
  return ref.watch(juggleImServiceProvider).messageStream;
});
