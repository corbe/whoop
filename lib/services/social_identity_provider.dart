/// Central social identity resolution (Community UX hardening).
///
/// UMA fonte para Members, Leaderboard e Chat: o mapa é construído a partir
/// da lista de membros da comunidade (já cacheada em communityMembersProvider)
/// + a identidade do usuário atual. NUNCA cria N chamadas por mensagem/membro.
///
/// Regras de renderização:
/// - display_name disponível → nome;
/// - display_name vazio → "Membro" (NUNCA o UUID/id interno);
/// - avatar_url disponível → avatar; senão iniciais/genérico.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/models/community.dart';
import '../shared/models/social_identity.dart';
import 'community_providers.dart' show communityMembersProvider;
import 'wellness_identity_providers.dart' show currentWellnessPersonProvider;

/// Resolvedor de identidade social de uma comunidade (family por uuid).
///
/// Observa a lista de membros da comunidade + o usuário atual e devolve um
/// mapa personUuid → SocialIdentity. Chat usa [resolveJuggleId] para
/// `wellness:<uuid>`; Members/Leaderboard usam [resolve].
class SocialIdentityResolver {
  const SocialIdentityResolver({required this.byPersonUuid});

  final Map<String, SocialIdentity> byPersonUuid;

  static const String jugglePrefix = 'wellness:';

  SocialIdentity? resolve(String? personUuid) {
    if (personUuid == null) return null;
    return byPersonUuid[personUuid];
  }

  /// Resolve um id do JuggleIM (`wellness:<uuid>`) para identidade social.
  /// Fallback seguro: identidade com nome "Membro" — nunca expõe o id bruto.
  SocialIdentity resolveJuggleId(String juggleId) {
    final stripped = juggleId.startsWith(jugglePrefix)
        ? juggleId.substring(jugglePrefix.length)
        : juggleId;
    final hit = byPersonUuid[stripped];
    if (hit != null) return hit;
    return SocialIdentity(personUuid: stripped);
  }

  /// Nome exibível seguro para um id do JuggleIM.
  String displayNameForJuggleId(String juggleId) =>
      resolveJuggleId(juggleId).safeDisplayName;
}

final socialIdentityProvider =
    Provider.family<SocialIdentityResolver, String>((ref, communityUuid) {
  final membersAsync = ref.watch(communityMembersProvider(communityUuid));
  final me = ref.watch(currentWellnessPersonProvider).valueOrNull;

  final map = <String, SocialIdentity>{};
  final members = membersAsync.valueOrNull ?? const <CommunityMember>[];
  for (final m in members) {
    map[m.personUuid] = SocialIdentity(
      personUuid: m.personUuid,
      displayName: m.displayName,
      avatarUrl: m.avatarUrl,
    );
  }
  if (me != null) {
    map[me.uuid] = SocialIdentity(
      personUuid: me.uuid,
      displayName: me.displayName,
      avatarUrl: me.avatarUrl,
    );
  }
  return SocialIdentityResolver(byPersonUuid: map);
});
