/// Community notification settings (Phase 6, spec §55–§56).
///
/// Per-community mode: All messages | Mentions only | Muted. Persists to the
/// backend. No global settings system in this phase (spec §56).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/community_providers.dart';
import '../../services/community_service.dart';

class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({
    super.key,
    required this.communityUuid,
    required this.communityName,
  });

  final String communityUuid;
  final String communityName;

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen> {
  String? _mode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ref
        .read(communityNotificationPreferenceProvider(widget.communityUuid).future)
        .then((mode) {
      if (mounted) setState(() => _mode = mode);
    }).catchError((_) {
      if (mounted) setState(() => _mode = 'all');
    });
  }

  Future<void> _save(String mode) async {
    setState(() {
      _saving = true;
      _mode = mode;
    });
    try {
      final saved = await ref
          .read(communityServiceProvider)
          .updateNotificationPreference(widget.communityUuid, mode);
      if (!mounted) return;
      setState(() {
        _mode = saved;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preferência salva.')),
      );
      ref.invalidate(communityNotificationPreferenceProvider(widget.communityUuid));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao salvar: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Notificações')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Notificações de ${widget.communityName}',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Mensagens de chat. Membros que saírem ou forem banidos nunca '
            'recebem notificações desta comunidade.',
            style: theme.textTheme.bodySmall,
          ),
          const Divider(height: 32),
          if (_saving) const LinearProgressIndicator(minHeight: 2),
          RadioGroup<String>(
            groupValue: _mode,
            onChanged: (v) {
              if (v != null) _save(v);
            },
            child: Column(
              children: [
                const RadioListTile<String>(
                  value: 'all',
                  title: Text('Todas as mensagens'),
                  subtitle: Text('Notifica qualquer mensagem da comunidade.'),
                ),
                const RadioListTile<String>(
                  value: 'mentions_only',
                  title: Text('Apenas menções'),
                  subtitle: Text('Notifica só quando você é mencionado.'),
                ),
                const RadioListTile<String>(
                  value: 'muted',
                  title: Text('Silenciado'),
                  subtitle: Text('Nenhuma notificação desta comunidade.'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
