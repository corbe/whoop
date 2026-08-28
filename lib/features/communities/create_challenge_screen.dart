/// Create challenge screen (Phase 7, spec §50).
///
/// Owner/admin only (backend enforces — spec §10). Metric/aggregation from
/// allowlists; dates validated (start <= end, max 90 days).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/challenge_providers.dart';
import '../../shared/models/challenge.dart';

class CreateChallengeScreen extends ConsumerStatefulWidget {
  const CreateChallengeScreen({
    super.key,
    required this.communityUuid,
    required this.communityName,
  });

  final String communityUuid;
  final String communityName;

  @override
  ConsumerState<CreateChallengeScreen> createState() =>
      _CreateChallengeScreenState();
}

class _CreateChallengeScreenState extends ConsumerState<CreateChallengeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  final _minDaysController = TextEditingController();
  final _targetController = TextEditingController();

  String _metric = 'readiness';
  String _aggregation = 'average';
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _startController.dispose();
    _endController.dispose();
    _minDaysController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year, now.month, now.day),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (picked != null) {
      controller.text =
          '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(challengeActionControllerProvider)
          .createChallenge(
            widget.communityUuid,
            ChallengeCreateRequest(
              name: _nameController.text.trim(),
              description: _descriptionController.text.trim(),
              metric: _metric,
              aggregation: _aggregation,
              startDate: _startController.text,
              endDate: _endController.text,
              minDays: _minDaysController.text.isEmpty
                  ? null
                  : int.tryParse(_minDaysController.text),
              targetValue: _targetController.text.isEmpty
                  ? null
                  : int.tryParse(_targetController.text),
            ),
          );
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Falha ao criar desafio: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Criar desafio')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Desafio em ${widget.communityName}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Desafios usam valores já registrados de DailyScore. '
              'Nenhuma fórmula de saúde é calculada aqui.',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 24),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Nome *'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Nome é obrigatório' : null,
            ),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(labelText: 'Descrição'),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _metric,
              decoration: const InputDecoration(labelText: 'Métrica *'),
              items: challengeMetrics
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) => setState(() => _metric = v!),
            ),
            DropdownButtonFormField<String>(
              initialValue: _aggregation,
              decoration: const InputDecoration(labelText: 'Agregação *'),
              items: challengeAggregations
                  .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                  .toList(),
              onChanged: (v) => setState(() => _aggregation = v!),
            ),
            // Fase 3 — meta opcional (Soma de zonas N / Consistência de sono).
            if (_aggregation == 'sum' ||
                (_metric == 'sleep' && _aggregation == 'average')) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _targetController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: _aggregation == 'sum'
                      ? 'Meta (pontos de strain) *'
                      : 'Meta (média de sono) *',
                  helperText: _aggregation == 'sum'
                      ? 'Ex.: 50 pontos de strain na semana'
                      : 'Ex.: 60 (sua média de sono no período)',
                ),
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '');
                  if (n == null || n <= 0) {
                    return 'Informe uma meta numérica maior que zero';
                  }
                  return null;
                },
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _startController,
                    readOnly: true,
                    decoration: const InputDecoration(labelText: 'Início *'),
                    onTap: () => _pickDate(_startController),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Data obrigatória' : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: _endController,
                    readOnly: true,
                    decoration: const InputDecoration(labelText: 'Fim *'),
                    onTap: () => _pickDate(_endController),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Data obrigatória';
                      final s = DateTime.tryParse(_startController.text);
                      final e = DateTime.tryParse(v);
                      if (s != null && e != null && e.isBefore(s)) {
                        return 'Fim < início';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
            TextFormField(
              controller: _minDaysController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Mínimo de dias (opcional)',
                helperText:
                    'Participante com menos dias válidos fica não-qualificado',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Criar desafio'),
            ),
          ],
        ),
      ),
    );
  }
}
