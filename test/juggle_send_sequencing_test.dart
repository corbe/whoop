/// Service-level regression: send × connect sequencing (fix 2026-08-17).
///
/// Bug (Android emulator): o app permitia enviar mensagem enquanto a conexão
/// WS do Juggle ainda estava sendo estabelecida (composer habilitado durante
/// `connecting`). O SDK enfileira a mensagem (sem erro, sem ack) e o timeout
/// de ack do app (15s) estourava antes do connect lento terminar (emulador:
/// ~25s na 1ª conexão) → `SendResult(ok:false, errorCode:-1)` FALSO. O -1 é
/// o marcador de timeout do APP (juggle_im_service), não um erro nativo.
///
/// Fix: `waitUntilConnected()` (gate bounded) antes de disparar o send.
/// Estes testes usam o serviço REAL com um SDK fake injetável — provam que o
/// SDK de envio NÃO é chamado durante a conexão e que o envio acontece só
/// depois de `connected`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:juggle_im/juggle_im.dart';
import 'package:juggle_im/juggle_const.dart';
import 'package:juggle_im/model/connection_listener.dart';
import 'package:juggle_im/model/conversation.dart';
import 'package:juggle_im/model/init_config.dart';
import 'package:juggle_im/model/message.dart';
import 'package:juggle_im/model/message_content.dart';
import 'package:juggle_im/model/message_reaction.dart';
import 'package:juggle_im/model/send_message_option.dart';

import 'package:noana_wellness_app/services/chat_session_service.dart';
import 'package:noana_wellness_app/services/juggle_im_service.dart';

/// SDK fake: captura o listener de conexão (permite emitir estados) e o
/// sendMessage (permite inspecionar quando o envio é disparado e completar o
/// callback do SDK com sucesso ou erro). Os membros de ciclo de vida são
/// no-ops; o serviço registra o listener via initializeAndConnect.
class _FakeSdk implements JuggleIm {
  ConnectionListener? listener;
  bool sendMessageCalled = false;
  DataCallback<Message>? lastCallback;

  /// Estado nativo reportado por getConnectionStatus (default: desconhecido
  /// → o teste força o caminho de eventos). -1 = lança (SDK indisponível).
  int nativeStatus = -1;

  void emitStatus(int status) {
    listener?.onConnectionStatusChange(status, 0, '');
  }

  void completeSend({int errorCode = 0}) {
    final cb = lastCallback;
    if (cb == null) return;
    final msg = Message(Conversation(2, 'grp'))..messageId = 'mid-1';
    cb(msg, errorCode);
  }

  @override
  Future<int> getConnectionStatus() async {
    if (nativeStatus < 0) throw StateError('no native status');
    return nativeStatus;
  }

  @override
  void addConnectionListener(String key, ConnectionListener listener) {
    this.listener = listener;
  }

  @override
  Future<Message> sendMessage(MessageContent content, Conversation conversation,
      DataCallback<Message> callback, [SendMessageOption? option]) async {
    sendMessageCalled = true;
    lastCallback = callback;
    return Message(conversation);
  }

  @override
  Future<void> setServers(List<String> servers) async {}

  @override
  Future<void> init(String appKey, [InitConfig? config]) async {}

  @override
  Future<void> connect(String token) async {}

  @override
  Future<void> disconnect(bool receivePush) async {}

  @override
  Function(int count)? onTotalUnreadMessageCountUpdate;

  @override
  Function(Message message)? onMessageReceive;

  @override
  Function(Conversation conversation, MessageReaction reaction)?
      onMessageReactionAdd;

  @override
  Function(Conversation conversation, MessageReaction reaction)?
      onMessageReactionRemove;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _session = ChatSession(
  userId: 'wellness:me',
  token: 't',
  wsUrl: 'wss://x',
  apiUrl: 'https://x',
  navUrl: 'https://x',
);

void main() {
  late _FakeSdk sdk;
  late JuggleImService svc;

  setUp(() async {
    sdk = _FakeSdk();
    svc = JuggleImService(sdk: sdk);
    // Registra o listener de conexão (só o initializeAndConnect faz isso no
    // serviço real) e deixa o estado em `connecting` — como um chat recém
    // aberto com o WS ainda subindo.
    await svc.initializeAndConnect(_session);
  });

  group('waitUntilConnected', () {
    test('já conectado → true imediato (sem espera)', () async {
      sdk.emitStatus(ConnectionStatus.connected);
      expect(await svc.waitUntilConnected(), isTrue);
    });

    test('connecting → aguarda o evento connected → true', () async {
      sdk.emitStatus(ConnectionStatus.connecting);
      final future = svc.waitUntilConnected();
      sdk.emitStatus(ConnectionStatus.connected);
      expect(await future, isTrue);
    });

    test('conexão falhou → false imediato', () async {
      sdk.emitStatus(ConnectionStatus.connecting);
      final future = svc.waitUntilConnected();
      sdk.emitStatus(ConnectionStatus.failure);
      expect(await future, isFalse);
    });

    test('bound estourado sem evento → false', () async {
      sdk.emitStatus(ConnectionStatus.connecting);
      expect(
        await svc.waitUntilConnected(timeout: const Duration(milliseconds: 50)),
        isFalse,
      );
    });
  });

  group('sendText com gate de sequenciamento', () {
    test('NÃO chama o SDK durante connecting; envia após connected', () async {
      sdk.emitStatus(ConnectionStatus.connecting);
      final future = svc.sendText('g1', 2, 'oi');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sdk.sendMessageCalled, isFalse,
          reason: 'envio NUNCA pode disparar com a conexão ainda subindo');

      sdk.emitStatus(ConnectionStatus.connected);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sdk.sendMessageCalled, isTrue,
          reason: 'após connected o envio deve ser disparado');

      sdk.completeSend();
      final result = await future;
      expect(result.ok, isTrue);
      expect(result.messageId, 'mid-1');
      expect(result.errorCode, 0);
    });

    test('já conectado → envia imediatamente', () async {
      sdk.emitStatus(ConnectionStatus.connected);
      final future = svc.sendText('g1', 2, 'oi');
      // sendText suspende no 1º await (waitUntilConnected já resolveu) —
      // deixa a microtask correr antes de inspecionar o SDK.
      await Future<void>.delayed(Duration.zero);
      expect(sdk.sendMessageCalled, isTrue);
      sdk.completeSend();
      expect((await future).ok, isTrue);
    });

    test('conexão falhou durante a espera → -1 SEM chamar o SDK', () async {
      sdk.emitStatus(ConnectionStatus.connecting);
      final future = svc.sendText('g1', 2, 'oi');
      sdk.emitStatus(ConnectionStatus.failure);

      final result = await future;
      expect(result.ok, isFalse);
      expect(result.errorCode, -1);
      expect(sdk.sendMessageCalled, isFalse,
          reason: 'sem conexão o SDK não pode ser chamado');
    });

    test('callback do SDK com erro → SendResult.ok=false com o código nativo',
        () async {
      sdk.emitStatus(ConnectionStatus.connected);
      final future = svc.sendText('g1', 2, 'oi');
      await Future<void>.delayed(Duration.zero); // deixa o send chegar ao SDK
      sdk.completeSend(errorCode: 13002); // ex.: GROUP_NOTGROUPMEMBER
      final result = await future;
      expect(result.ok, isFalse);
      expect(result.errorCode, 13002);
      expect(result.messageId, 'mid-1');
    });

    test(
        'dart preso em connecting mas nativo connected → gate passa via '
        'consulta nativa (sync de estado)', () async {
      // Evento de status PERDIDO (nativo conectou, Dart segue 'connecting').
      sdk.nativeStatus = ConnectionStatus.connected;
      final future = svc.sendText('g1', 2, 'oi');
      await Future<void>.delayed(Duration.zero);
      expect(sdk.sendMessageCalled, isTrue,
          reason: 'estado nativo autoritativo deve liberar o envio');
      sdk.completeSend();
      final result = await future;
      expect(result.ok, isTrue);
      expect(result.errorCode, 0);
    });

    test('dart connecting e nativo ainda conectando → espera o evento',
        () async {
      sdk.nativeStatus = ConnectionStatus.connecting;
      final future = svc.sendText('g1', 2, 'oi');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sdk.sendMessageCalled, isFalse,
          reason: 'nativo ainda não conectado → NÃO envia');
      sdk.emitStatus(ConnectionStatus.connected);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sdk.sendMessageCalled, isTrue);
      sdk.completeSend();
      expect((await future).ok, isTrue);
    });
  });
}
