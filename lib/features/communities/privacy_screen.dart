/// Community privacy / sharing UI (Phase 5, spec §42–§43).
///
/// Score toggles per community. Updates call the backend privacy endpoint
/// (never only local state). Explains that only enabled scores are visible.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/score_providers.dart';
import '../../shared/models/score.dart';

class PrivacyScreen extends ConsumerStatefulWidget {
  const PrivacyScreen({super.key, required this.communityUuid, required this.communityName});

  final String communityUuid;
  final String communityName;

  @override
  ConsumerState<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends ConsumerState<PrivacyScreen> {
  late CommunityShareScope _scope;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _scope = CommunityShareScope.fromJson(
      ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ??
          const {},
    );
    _loaded = true;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(shareScopeControllerProvider)
          .update(widget.communityUuid, _scope);
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Privacidade atualizada.')),
      );
      Navigator.pop(context, _scope);
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
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Privacidade / Compartilhamento')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Compartilhar com ${widget.communityName}',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Apenas os scores que você ativar aqui ficam visíveis para os '
            'membros desta comunidade. Nenhum dado de saúde bruto (HR, HRV, '
            'SpO2, temperatura, hipnograma…) é compartilhado.',
            style: theme.textTheme.bodySmall,
          ),
          const Divider(height: 32),
          SwitchListTile(
            value: _scope.readiness,
            onChanged: (v) => setState(() => _scope = _scope.copyWith(readiness: v)),
            title: const Text('Readiness'),
          ),
          SwitchListTile(
            value: _scope.sleep,
            onChanged: (v) => setState(() => _scope = _scope.copyWith(sleep: v)),
            title: const Text('Sleep'),
          ),
          SwitchListTile(
            value: _scope.activity,
            onChanged: (v) => setState(() => _scope = _scope.copyWith(activity: v)),
            title: const Text('Activity'),
          ),
          SwitchListTile(
            value: _scope.strain,
            onChanged: (v) => setState(() => _scope = _scope.copyWith(strain: v)),
            title: const Text('Strain'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Salvar'),
          ),
        ],
      ),
    );
  }
}
