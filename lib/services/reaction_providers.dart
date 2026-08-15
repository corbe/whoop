/// Reaction catalog provider (Community UX hardening).
///
/// Busca a configuração de reações do backend
/// (GET /v1/wellness/chat/reactions/ — catálogo autoritativo, controlado via
/// Django Admin). Se o endpoint falhar temporariamente, degrada para o
/// conjunto rápido fallback (❤️ 👍 🔥 😂 👏 💪) — a UI continua funcional.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../shared/models/chat.dart';

/// Fallback usado APENAS quando o backend está indisponível (degradação
/// temporária). O backend é autoritativo quando disponível.
const List<String> _fallbackQuick = ['❤️', '👍', '🔥', '😂', '👏', '💪'];

final reactionCatalogProvider = FutureProvider<ReactionCatalog>((ref) async {
  final api = ref.watch(apiClientProvider);
  try {
    final res = await api.get('/wellness/chat/reactions/');
    final items = res.data as List<dynamic>;
    final catalog = ReactionCatalog.fromList(items);
    if (catalog.quick.isEmpty) {
      // Backend sem quick configurada → usa o fallback como barra rápida.
      return ReactionCatalog(
        reactions: catalog.reactions,
        quick: _fallbackQuick,
      );
    }
    return catalog;
  } catch (_) {
    // Degradação graciosa: endpoint fora → fallback local.
    return const ReactionCatalog(
      reactions: [],
      quick: _fallbackQuick,
    );
  }
});
