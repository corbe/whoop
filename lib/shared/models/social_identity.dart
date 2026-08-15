/// Social identity (Community UX hardening) — UMA representação segura.
///
/// personUuid serve APENAS para mapeamento interno (chaves, chamadas de API).
/// NUNCA deve ser renderizado como UI normal. displayName vazio → UI mostra
/// "Membro"; avatarUrl vazio → iniciais ou avatar genérico.
library;

class SocialIdentity {
  const SocialIdentity({
    required this.personUuid,
    this.displayName = '',
    this.avatarUrl = '',
  });

  final String personUuid;

  /// Nome social seguro. Vazio quando o backend não forneceu (nunca o UUID).
  final String displayName;

  final String avatarUrl;

  /// Nome exibível: display_name quando disponível, senão "Membro".
  String get safeDisplayName =>
      displayName.trim().isEmpty ? 'Membro' : displayName.trim();

  bool get hasAvatar => avatarUrl.trim().isNotEmpty;

  /// Inicial (para avatar genérico quando não há avatar_url).
  String get initial {
    final name = safeDisplayName.trim();
    if (name.isEmpty || name == 'Membro') return '?';
    return name[0].toUpperCase();
  }
}
