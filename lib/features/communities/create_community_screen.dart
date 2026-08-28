/// Create community screen (Phase 4, spec §30).
///
/// Fields: name, description, avatar_url (optional), visibility. After
/// successful creation → navigate to Community Detail. The client NEVER
/// creates the JuggleIM group directly — the backend does (spec §30).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/community_providers.dart';
import '../../shared/models/community.dart';

class CreateCommunityScreen extends ConsumerStatefulWidget {
  const CreateCommunityScreen({super.key});

  @override
  ConsumerState<CreateCommunityScreen> createState() =>
      _CreateCommunityScreenState();
}

class _CreateCommunityScreenState extends ConsumerState<CreateCommunityScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _avatarController = TextEditingController();
  String _visibility = 'invite_only';
  bool _submitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _avatarController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final result = await ref
          .read(communityActionControllerProvider)
          .create(CommunityCreateRequest(
            name: _nameController.text.trim(),
            description: _descriptionController.text.trim(),
            avatarUrl: _avatarController.text.trim(),
            visibility: _visibility,
          ));
      if (!mounted) return;
      final community = result.community;
      if (community != null) {
        // Navega para o detalhe da comunidade criada (spec §30).
        context.go('/communities/${community.uuid}');
      } else {
        context.go('/communities');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao criar: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nova comunidade')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Nome *',
                hintText: 'Ex.: Running Floripa',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Informe o nome' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Descrição',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _avatarController,
              decoration: const InputDecoration(
                labelText: 'Avatar URL (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text('Visibilidade', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            ..._visibilityOptions(),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Criar comunidade'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _visibilityOptions() {
    const options = [
      ('invite_only', 'Somente convite', 'Novos membros entram por convite.'),
      ('public_code', 'Acesso por código', 'Qualquer pessoa entra com o código.'),
      ('private', 'Privada', 'Entrada apenas aprovada pelo owner.'),
    ];
    return [
      RadioGroup<String>(
        groupValue: _visibility,
        onChanged: (v) => setState(() => _visibility = v ?? 'invite_only'),
        child: Column(
          children: options
              .map((o) => RadioListTile<String>(
                    value: o.$1,
                    title: Text(o.$2),
                    subtitle: Text(o.$3),
                  ))
              .toList(),
        ),
      ),
    ];
  }
}
