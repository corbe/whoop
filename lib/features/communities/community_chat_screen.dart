/// Community chat (Phase 4, spec §32–§34).
///
/// Reuses the existing Phase 3 ChatSessionService + JuggleImService — NO
/// second WebSocket implementation. Opens the JuggleIM group conversation
/// (`community.juggle_group_id`), loads history, sends text and receives
/// realtime text. The backend enforces access (only active members get the
/// group id / membership).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juggle_im/model/conversation.dart';
import 'package:juggle_im/model/message.dart';

import '../../services/chat_session_service.dart';
import '../../services/juggle_im_service.dart';

class CommunityChatScreen extends ConsumerStatefulWidget {
  const CommunityChatScreen({
    super.key,
    required this.communityName,
    required this.groupId,
  });

  final String communityName;
  final String groupId;

  @override
  ConsumerState<CommunityChatScreen> createState() => _CommunityChatScreenState();
}

class _CommunityChatScreenState extends ConsumerState<CommunityChatScreen> {
  final _messageController = TextEditingController();
  final List<Message> _messages = [];
  bool _connecting = true;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final juggle = ref.read(juggleImServiceProvider);
      if (juggle.session == null || juggle.state != JuggleConnectionState.connected) {
        final session =
            await ref.read(chatSessionServiceProvider).obtainSession();
        await juggle.initializeAndConnect(session);
      }
      // Histórico do grupo (spec §33 — load history).
      final history = await juggle.loadGroupHistory(widget.groupId);
      if (mounted) {
        setState(() {
          _messages
            ..clear()
            ..addAll(history.reversed);
          _connecting = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = 'Falha ao abrir o chat: $e';
      });
    }
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final juggle = ref.read(juggleImServiceProvider);
    final result = await juggle.sendGroupText(widget.groupId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (result.ok) {
      _messageController.clear();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha no envio (code=${result.errorCode})')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.communityName)),
      body: Column(
        children: [
          Expanded(child: _buildMessages()),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessages() {
    if (_connecting) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _open, child: const Text('Tentar novamente')),
            ],
          ),
        ),
      );
    }
    // Realtime incoming messages (spec §33 — receive realtime text).
    final incoming = ref.watch(juggleMessagesProvider).valueOrNull;
    final all = [..._messages];
    if (incoming is List) {
      all.addAll(incoming.whereType<Message>());
    } else if (incoming is Message) {
      all.add(incoming);
    }
    final visible =
        all.where((m) => m.conversation.conversationType == ConversationType.group).toList();
    if (visible.isEmpty) {
      return const Center(child: Text('Nenhuma mensagem ainda. Envie a primeira!'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final m = visible[i];
        final text = JuggleImService.textOf(m);
        final isMine = m.direction == MessageDirection.send;
        return Align(
          alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: const BoxConstraints(maxWidth: 280),
            decoration: BoxDecoration(
              color: isMine
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isMine && m.senderDisplayName.isNotEmpty)
                  Text(
                    m.senderDisplayName,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                Text(text),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                decoration: const InputDecoration(
                  hintText: 'Mensagem…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
