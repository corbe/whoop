/// Diagnostic chat test screen (Phase 3, minimal UI).
///
/// Obtém o ChatSession do backend, conecta o JuggleIM SDK e permite enviar
/// mensagens privadas — tudo via serviços/Riverpod, nunca SDK direto no widget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/chat_session_service.dart';
import '../../services/juggle_im_service.dart';

class ChatDiagnosticScreen extends ConsumerStatefulWidget {
  const ChatDiagnosticScreen({super.key});

  @override
  ConsumerState<ChatDiagnosticScreen> createState() => _ChatDiagnosticScreenState();
}

class _ChatDiagnosticScreenState extends ConsumerState<ChatDiagnosticScreen> {
  final _targetController = TextEditingController();
  final _messageController = TextEditingController();
  String? _sessionInfo;
  String? _lastSend;
  bool _busy = false;

  @override
  void dispose() {
    _targetController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _obtainAndConnect() async {
    setState(() => _busy = true);
    try {
      final chatSession = ref.read(chatSessionServiceProvider);
      final session = await chatSession.obtainSession();
      final juggle = ref.read(juggleImServiceProvider);
      await juggle.initializeAndConnect(session);
      if (!mounted) return;
      setState(() {
        _sessionInfo = 'user_id: ${session.userId}\nws: ${session.wsUrl}';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sessionInfo = 'Falha: $e';
        _busy = false;
      });
    }
  }

  Future<void> _send() async {
    final target = _targetController.text.trim();
    final text = _messageController.text.trim();
    if (target.isEmpty || text.isEmpty) return;
    final juggle = ref.read(juggleImServiceProvider);
    final result = await juggle.sendText(target, 1, text);
    if (!mounted) return;
    setState(() {
      _lastSend = result.ok
          ? 'OK msg=${result.messageId}'
          : 'FALHOU code=${result.errorCode}';
    });
  }

  Future<void> _reconnect() async {
    await ref.read(juggleImServiceProvider).reconnect();
  }

  @override
  Widget build(BuildContext context) {
    final connAsync = ref.watch(juggleConnectionStateProvider);
    final connState = connAsync.valueOrNull ?? JuggleConnectionState.disconnected;

    return Scaffold(
      appBar: AppBar(title: const Text('Chat Diagnóstico')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Conexão: ', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 8),
                      _ConnectionBadge(state: connState),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _sessionInfo ?? 'Nenhuma sessão ainda.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : _obtainAndConnect,
                        child: const Text('Obter session + conectar'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _reconnect,
                        child: const Text('Reconectar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _targetController,
            decoration: const InputDecoration(
              labelText: 'Destinatário (juggle user_id)',
              hintText: 'wellness:<uuid>',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _messageController,
            decoration: const InputDecoration(
              labelText: 'Mensagem',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _send,
            child: const Text('Enviar privada'),
          ),
          if (_lastSend != null) ...[
            const SizedBox(height: 8),
            Text(_lastSend!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 24),
          // Mensagens recebidas em tempo real (domínio, spec §5).
          Consumer(
            builder: (context, ref, _) {
              final message = ref.watch(juggleMessagesProvider).valueOrNull;
              if (message == null) {
                return const Text('Nenhuma mensagem recebida ainda.');
              }
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '• ${message.senderName.isEmpty ? message.senderId : message.senderName}: ${message.text}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.state});

  final JuggleConnectionState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      JuggleConnectionState.connected => ('connected', Colors.green),
      JuggleConnectionState.connecting => ('connecting', Colors.orange),
      JuggleConnectionState.reconnecting => ('reconnecting', Colors.orange),
      JuggleConnectionState.failed => ('failed', Colors.red),
      JuggleConnectionState.disconnected => ('disconnected', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }
}
