/// Community chat (Phase 6, spec §53–§54).
///
/// Bubbles with sender avatar/name, reply preview, reactions, image
/// thumbnails, file cards, timestamps, delivery state, action menu
/// (Reply/React/Copy), composer with reply context. All state via
/// ChatController — no direct SDK in widgets.
library;

import 'dart:async';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart'
    show BottomActionBarConfig, Category, CategoryViewConfig, Config, EmojiPicker, EmojiViewConfig;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juggle_im/model/conversation.dart';

import '../../services/chat_attachment_service.dart';
import '../../services/chat_controller.dart';
import '../../services/reaction_providers.dart';
import '../../services/social_identity_provider.dart';
import '../../shared/models/chat.dart';
import '../../shared/models/social_identity.dart';
import 'member_profile_screen.dart';

class CommunityChatScreen extends ConsumerStatefulWidget {
  const CommunityChatScreen({
    super.key,
    required this.communityName,
    required this.communityUuid,
    required this.groupId,
  });

  final String communityName;
  final String communityUuid;
  final String groupId;

  @override
  ConsumerState<CommunityChatScreen> createState() => _CommunityChatScreenState();
}

class _CommunityChatScreenState extends ConsumerState<CommunityChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _attachmentService = ChatAttachmentService();
  final Map<String, GlobalKey> _messageKeys = {};
  StreamSubscription? _stateSub;
  ChatState? _state;
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(chatControllerProvider((
      conversationId: widget.groupId,
      conversationType: ConversationType.group,
    )));
    _stateSub = controller.stateStream.listen((state) {
      if (!mounted) return;
      setState(() => _state = state);
      if (_atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    });
    _scrollController.addListener(() {
      if (_scrollController.position.pixels <= 40) {
        controller.loadOlder();
      }
    });
    controller.start();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  ChatController get _controller => ref.read(chatControllerProvider((
        conversationId: widget.groupId,
        conversationType: ConversationType.group,
      )));

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  /// Rola até a mensagem original de um reply — no-op seguro quando a
  /// mensagem ainda não está carregada no estado local (spec: não crashar).
  void _scrollToOriginal(String messageId) {
    final key = _messageKeys[messageId];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.3,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    await _controller.sendText(text);
    _messageController.clear();
  }

  Future<void> _sendImage() async {
    try {
      final attachment = await _attachmentService.pickImage();
      if (attachment == null) return;
      await _controller.sendImage(attachment.localPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  Future<void> _sendFile() async {
    try {
      final attachment = await _attachmentService.pickFile();
      if (attachment == null) return;
      await _controller.sendFile(
        attachment.localPath,
        name: attachment.name,
        mimeType: attachment.mimeType,
        size: attachment.size,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final identities = ref.watch(socialIdentityProvider(widget.communityUuid));
    final catalogAsync = ref.watch(reactionCatalogProvider);
    final quickReactions = catalogAsync.valueOrNull?.quick ??
        const ['❤️', '👍', '🔥', '😂', '👏', '💪'];
    return Scaffold(
      appBar: AppBar(title: Text(widget.communityName)),
      body: Column(
        children: [
          Expanded(child: _buildMessages(state, identities, quickReactions)),
          if (state?.replyTarget != null) _replyBar(state!.replyTarget!),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _replyBar(ChatReplyRef reply) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.reply),
        title: Text(
          'Respondendo a ${reply.originalSenderName}',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        subtitle: Text(
          reply.originalPreview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => _controller.setReplyTarget(null),
        ),
      ),
    );
  }

  Widget _buildMessages(ChatState? state, SocialIdentityResolver identities, List<String> quickReactions) {
    if (state == null || state.initialLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (state.error != null && state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(state.error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _controller.loadOlder(reset: true),
                child: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
      );
    }
    if (state.messages.isEmpty) {
      return const Center(child: Text('Nenhuma mensagem ainda. Envie a primeira!'));
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: state.messages.length,
      itemBuilder: (context, i) {
        final message = state.messages[i];
        // Ownership autoritativa é resolvida no _MessageBubble via
        // currentJuggleUserId (senderId == session userId do JuggleIM).
        // Identidade de exibição — nunca usada para ownership.
        final senderIdentity = identities.resolveJuggleId(message.senderId);
        // Sender do reply: o SDK pode mandar senderDisplayName vazio/bruto —
        // resolve pela MESMA identidade (fallback "Membro", nunca id).
        final replyRef = message.replyTo?.copyWith(
          originalSenderName:
              identities.resolveJuggleId(message.replyTo!.originalSenderId)
                  .safeDisplayName,
        );
        final messageKey = _messageKeys.putIfAbsent(message.id, GlobalKey.new);
        return KeyedSubtree(
          key: messageKey,
          child: _MessageBubble(
            message: message.copyWith(replyTo: replyRef),
            senderIdentity: senderIdentity,
            currentJuggleUserId: _controller.sessionUserId ?? '',
            quickReactions: quickReactions,
            onOpenProfile: () {
            final personUuid =
                identities.resolveJuggleId(message.senderId).personUuid;
            if (personUuid.isEmpty) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MemberProfileScreen(
                  communityUuid: widget.communityUuid,
                  personUuid: personUuid,
                ),
              ),
            );
          },
          onReply: () => _controller.setReplyTarget(ChatReplyRef(
            originalMessageId: message.id,
            originalSenderId: message.senderId,
            originalSenderName: senderIdentity.safeDisplayName,
            originalPreview: message.text.isEmpty
                ? (message.type == ChatMessageType.image
                    ? '[Imagem]'
                    : '[Arquivo]')
                : message.text,
          )),
          onReact: (emoji) async {
            await _controller.addReaction(message.id, emoji);
          },
          onToggleReaction: (emoji, mine) async {
            // Toggle conforme semântica do controller atual: se já é minha,
            // remove; senão adiciona. Nenhuma semântica paralela.
            if (mine) {
              await _controller.removeReaction(message.id, emoji);
            } else {
              await _controller.addReaction(message.id, emoji);
            }
          },
          onRetry: () => _controller.retryFailed(message),
          onScrollToBottom: () => _atBottom = true,
          onScrollAway: () => _atBottom = false,
          onTapReplyPreview: message.replyTo == null
              ? null
              : () => _scrollToOriginal(message.replyTo!.originalMessageId),
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
            IconButton(
              icon: const Icon(Icons.image_outlined),
              tooltip: 'Enviar imagem',
              onPressed: _sendImage,
            ),
            IconButton(
              icon: const Icon(Icons.attach_file),
              tooltip: 'Enviar arquivo',
              onPressed: _sendFile,
            ),
            IconButton(
              icon: const Text('😊', style: TextStyle(fontSize: 20)),
              tooltip: 'Emoji na mensagem',
              onPressed: _openEmojiComposer,
            ),
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
            IconButton(
              onPressed: _send,
              icon: const Icon(Icons.send),
              tooltip: 'Enviar',
            ),
          ],
        ),
      ),
    );
  }

  /// Insere emoji no texto da mensagem (composer) — NÃO é reação.
  void _insertEmoji(String emoji) {
    final text = _messageController.text;
    final selection = _messageController.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final updated = text.replaceRange(start, end, emoji);
    _messageController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  /// Picker de emoji para o composer (fica aberto para inserir vários).
  void _openEmojiComposer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.5,
          child: EmojiPicker(
            textEditingController: TextEditingController(),
            config: Config(
              height: MediaQuery.of(context).size.height * 0.5 - 40,
              checkPlatformCompatibility: true,
              emojiViewConfig: const EmojiViewConfig(
                emojiSizeMax: 28,
                columns: 8,
                recentsLimit: 12,
              ),
              categoryViewConfig: const CategoryViewConfig(
                initCategory: Category.RECENT,
              ),
              bottomActionBarConfig: const BottomActionBarConfig(
                showBackspaceButton: true,
                showSearchViewButton: true,
              ),
            ),
            onEmojiSelected: (category, emoji) {
              _insertEmoji(emoji.emoji);
            },
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.senderIdentity,
    required this.currentJuggleUserId,
    required this.quickReactions,
    required this.onOpenProfile,
    required this.onReply,
    required this.onReact,
    required this.onToggleReaction,
    required this.onRetry,
    required this.onScrollToBottom,
    required this.onScrollAway,
    this.onTapReplyPreview,
  });

  final ChatMessage message;
  final SocialIdentity senderIdentity;
  final String currentJuggleUserId;
  final List<String> quickReactions;
  final VoidCallback onOpenProfile;
  final VoidCallback onReply;
  final void Function(String emoji) onReact;
  final void Function(String emoji, bool mine) onToggleReaction;
  final VoidCallback onRetry;
  final VoidCallback onScrollToBottom;
  final VoidCallback onScrollAway;
  final VoidCallback? onTapReplyPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Ownership vem do ID autoritativo do usuário JuggleIM (nunca do nome).
    final isMine = message.senderId == currentJuggleUserId;
    return Listener(
      onPointerDown: (_) => onScrollToBottom(),
      onPointerUp: (_) => onScrollAway(),
      child: GestureDetector(
        onLongPress: () => _showActions(context),
        // Mouse/emulator: botão secundário (clique direito) abre o MESMO
        // menu de ações — um único caminho para toque e mouse.
        onSecondaryTapDown: (_) => _showActions(context),
        child: Align(
          alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment:
                isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (isMine) _actionsButton(context, mine: true),
              Flexible(
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  constraints: const BoxConstraints(maxWidth: 300),
                  decoration: BoxDecoration(
                    color: isMine
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                if (!isMine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: InkWell(
                      onTap: onOpenProfile,
                      borderRadius: BorderRadius.circular(8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (senderIdentity.hasAvatar) ...[
                            CircleAvatar(
                              radius: 8,
                              foregroundImage:
                                  NetworkImage(senderIdentity.avatarUrl),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              senderIdentity.safeDisplayName,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (message.replyTo != null)
                  _ReplyPreview(
                    reply: message.replyTo!,
                    onTap: onTapReplyPreview ?? () {},
                  ),
                if (message.type == ChatMessageType.image)
                  _ImageContent(attachment: message.attachments.first)
                else if (message.type == ChatMessageType.file)
                  _FileContent(attachment: message.attachments.first)
                else
                  Text(message.text),
                if (message.reactions.isNotEmpty)
                  _ReactionRow(
                    reactions: message.reactions,
                    onToggle: onToggleReaction,
                  ),
                if (message.deliveryStatus == ChatMessageStatus.sending)
                  Text('enviando…', style: theme.textTheme.labelSmall)
                else if (message.deliveryStatus == ChatMessageStatus.failed)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('falhou',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.error)),
                      TextButton(onPressed: onRetry, child: const Text('Tentar')),
                    ],
                  )
                else if (message.createdAt != null)
                  Text(
                    _formatTime(message.createdAt!),
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
          ),
              ),
              if (!isMine) _actionsButton(context, mine: false),
            ],
          ),
        ),
      ),
    );
  }

  /// Botão ⋮ visível (touch E mouse) — abre o MESMO menu de ações do
  /// long-press / clique direito. Uma única implementação.
  Widget _actionsButton(BuildContext context, {required bool mine}) {
    return Padding(
      padding: EdgeInsets.only(
        left: mine ? 4 : 0,
        right: mine ? 0 : 4,
        bottom: 8,
      ),
      child: IconButton(
        icon: const Icon(Icons.more_horiz),
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        color: Theme.of(context).colorScheme.onSurfaceVariant
            .withValues(alpha: 0.6),
        tooltip: 'Ações',
        onPressed: () => _showActions(context),
      ),
    );
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Responder'),
              onTap: () {
                Navigator.pop(sheetContext);
                onReply();
              },
            ),
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: const Text('Reagir'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(sheetContext);
                _showReactionPicker(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copiar'),
              onTap: () {
                Navigator.pop(sheetContext);
                if (message.text.isNotEmpty) {
                  Clipboard.setData(ClipboardData(text: message.text));
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(
                      content: Text('Mensagem copiada'),
                      duration: Duration(seconds: 2),
                    ));
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Picker de reação: barra rápida (configuração do backend) + 😊 abre o
  /// emoji picker completo.
  void _showReactionPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Reagir',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...quickReactions.map((emoji) => IconButton(
                        icon: Text(emoji, style: const TextStyle(fontSize: 26)),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          onReact(emoji);
                        },
                      )),
                  IconButton(
                    icon: const Text('😊', style: TextStyle(fontSize: 26)),
                    tooltip: 'Mais emojis',
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _showFullEmojiPicker(context);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Emoji picker completo (emoji_picker_flutter — BSD-2-Clause, mantido,
  /// compatível com o SDK do projeto). Busca, categorias e recentes.
  void _showFullEmojiPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: EmojiPicker(
            textEditingController: TextEditingController(),
            config: Config(
              height: MediaQuery.of(context).size.height * 0.6 - 40,
              checkPlatformCompatibility: true,
              emojiViewConfig: const EmojiViewConfig(
                emojiSizeMax: 28,
                columns: 8,
                recentsLimit: 12,
              ),
              categoryViewConfig: const CategoryViewConfig(
                initCategory: Category.RECENT,
              ),
              bottomActionBarConfig: const BottomActionBarConfig(
                showBackspaceButton: false,
                showSearchViewButton: true,
              ),
            ),
            onEmojiSelected: (category, emoji) {
              Navigator.pop(sheetContext);
              onReact(emoji.emoji);
            },
          ),
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({required this.reply, required this.onTap});

  final ChatReplyRef reply;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reply.originalSenderName,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            Text(
              reply.originalPreview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReactionRow extends StatelessWidget {
  const _ReactionRow({required this.reactions, required this.onToggle});

  final List<ChatReaction> reactions;
  final void Function(String emoji, bool mine) onToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        children: reactions
            .map((r) => InkWell(
                  onTap: () => onToggle(r.emoji, r.mine),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: r.mine
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: Text('${r.emoji} ${r.count}',
                        style: Theme.of(context).textTheme.labelMedium),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _ImageContent extends StatelessWidget {
  const _ImageContent({required this.attachment});

  final ChatAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.localPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          // ignore: avoid_slow_image_file
          File(attachment.localPath),
          width: 180,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
        ),
      );
    }
    if (attachment.url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          attachment.url,
          width: 180,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
        ),
      );
    }
    return const Icon(Icons.image_outlined);
  }
}

class _FileContent extends StatelessWidget {
  const _FileContent({required this.attachment});

  final ChatAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sizeMb = (attachment.size / (1024 * 1024)).toStringAsFixed(1);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file_outlined),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(attachment.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('$sizeMb MB', style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ],
    );
  }
}
