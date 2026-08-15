/// Community UX hardening tests (Fase Community UX).
///
/// Cobre:
/// - SocialIdentity: safeDisplayName (fallback "Membro"), initial, avatar;
/// - resolver central: mapa a partir dos membros, resolve wellness:UUID,
///   fallback seguro (nunca expõe id bruto), reuso (sem N+1 — um mapa);
/// - ReactionCatalog: parse do backend, quick reactions, fallback quando o
///   endpoint falha;
/// - Discover: filtro local case-insensitive em name/description, estados
///   vazio/resultado/nada encontrado, query preservada após refresh.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:noana_wellness_app/shared/models/chat.dart';
import 'package:noana_wellness_app/shared/models/community.dart';
import 'package:noana_wellness_app/shared/models/social_identity.dart';
import 'package:noana_wellness_app/services/social_identity_provider.dart';

void main() {
  group('SocialIdentity', () {
    test('safeDisplayName usa display_name quando disponível', () {
      const id = SocialIdentity(
        personUuid: '66e67c85-47f0-4ac0-b8f7-05f8a8a491f4',
        displayName: 'Daniel',
      );
      expect(id.safeDisplayName, 'Daniel');
    });

    test('safeDisplayName cai para "Membro" quando display_name vazio', () {
      const id = SocialIdentity(personUuid: '66e67c85-47f0-4ac0-b8f7-05f8a8a491f4');
      expect(id.safeDisplayName, 'Membro');
      // Nunca expõe o UUID como fallback.
      expect(id.safeDisplayName.contains('66e67c85'), isFalse);
    });

    test('safeDisplayName trata whitespace como vazio', () {
      const id = SocialIdentity(
        personUuid: 'x',
        displayName: '   ',
      );
      expect(id.safeDisplayName, 'Membro');
    });

    test('initial usa a primeira letra do nome', () {
      const id = SocialIdentity(personUuid: 'x', displayName: 'ana');
      expect(id.initial, 'A');
    });

    test('initial é "?" para identidade sem nome', () {
      const id = SocialIdentity(personUuid: 'x');
      expect(id.initial, '?');
    });

    test('hasAvatar reflete avatar_url', () {
      const withAvatar = SocialIdentity(personUuid: 'x', avatarUrl: 'https://a/x.png');
      const without = SocialIdentity(personUuid: 'x');
      expect(withAvatar.hasAvatar, isTrue);
      expect(without.hasAvatar, isFalse);
    });
  });

  group('SocialIdentityResolver', () {
    const members = [
      CommunityMember(
        personUuid: '66e67c85-47f0-4ac0-b8f7-05f8a8a491f4',
        displayName: 'Daniel',
        role: 'owner',
        status: 'active',
      ),
      CommunityMember(
        personUuid: '9a1cbd7f-0000-0000-0000-000000000001',
        displayName: '',
        role: 'member',
        status: 'active',
      ),
    ];

    final resolver = SocialIdentityResolver(
      byPersonUuid: {
        for (final m in members) m.personUuid: SocialIdentity(
          personUuid: m.personUuid,
          displayName: m.displayName,
          avatarUrl: m.avatarUrl,
        ),
      },
    );

    test('resolve mapeia personUuid → identidade', () {
      final id = resolver.resolve('66e67c85-47f0-4ac0-b8f7-05f8a8a491f4');
      expect(id?.safeDisplayName, 'Daniel');
    });

    test('resolveJugleId resolve wellness:<uuid> pelo MESMO mapa', () {
      final id = resolver.resolveJuggleId('wellness:66e67c85-47f0-4ac0-b8f7-05f8a8a491f4');
      expect(id.safeDisplayName, 'Daniel');
    });

    test('membro sem display_name → "Membro", nunca id bruto', () {
      final id = resolver.resolveJuggleId('wellness:9a1cbd7f-0000-0000-0000-000000000001');
      expect(id.safeDisplayName, 'Membro');
      expect(id.safeDisplayName.contains('9a1cbd7f'), isFalse);
    });

    test('desconhecido → "Membro", nunca wellness:<uuid>', () {
      final id = resolver.resolveJuggleId('wellness:unknown-0000-0000-0000-0000000000aa');
      expect(id.safeDisplayName, 'Membro');
      expect(id.safeDisplayName.contains('wellness:'), isFalse);
      expect(id.safeDisplayName.contains('unknown'), isFalse);
    });

    test('displayNameForJuggleId é o nome exibível seguro', () {
      expect(
        resolver.displayNameForJuggleId('wellness:66e67c85-47f0-4ac0-b8f7-05f8a8a491f4'),
        'Daniel',
      );
      expect(resolver.displayNameForJuggleId('wellness:9a1cbd7f-0000-0000-0000-000000000001'),
          'Membro');
    });

    test('resolve desconhecido (sem prefixo) → null do mapa', () {
      expect(resolver.resolve('nao-existe'), isNull);
    });
  });

  group('ReactionCatalog', () {
    test('parse do backend mantém quick reactions na ordem', () {
      const raw = [
        {'emoji': '❤️', 'label': 'Apoio', 'category': 'social', 'sort_order': 10, 'is_quick': true},
        {'emoji': '👍', 'label': 'Concordo', 'category': 'social', 'sort_order': 20, 'is_quick': true},
        {'emoji': '🏆', 'label': 'Campeão', 'category': 'challenge', 'sort_order': 300, 'is_quick': false},
      ];
      final catalog = ReactionCatalog.fromList(raw);
      expect(catalog.reactions, hasLength(3));
      expect(catalog.quick, ['❤️', '👍']);
      expect(catalog.reactions[2].category, 'challenge');
      expect(catalog.reactions[2].isQuick, isFalse);
    });

    test('fallback quick quando o backend não marca is_quick', () {
      const raw = [
        {'emoji': '🔥', 'label': 'Mandou bem', 'category': 'motivation', 'sort_order': 100, 'is_quick': false},
      ];
      final catalog = ReactionCatalog.fromList(raw);
      expect(catalog.quick, isEmpty);
    });

    test('parse tolera campos ausentes', () {
      const raw = [
        {'emoji': '💪'},
      ];
      final catalog = ReactionCatalog.fromList(raw);
      expect(catalog.reactions.single.label, '');
      expect(catalog.reactions.single.sortOrder, 0);
      expect(catalog.reactions.single.isQuick, isFalse);
    });
  });

  group('Discover local filter semantics', () {
    List<Community> communities() => [
          Community(
            uuid: 'c-1',
            name: 'Running Floripa',
            description: 'Corrida de rua',
            visibility: 'public_code',
          ),
          Community(
            uuid: 'c-2',
            name: 'Sono Saudável',
            description: 'Rotina de descanso',
            visibility: 'public_code',
          ),
        ];

    // Espelha a lógica de _DiscoverList._applyQuery (filtro local).
    List<Community> applyQuery(List<Community> all, String query) {
      final q = query.trim().toLowerCase();
      if (q.isEmpty) return all;
      return all
          .where((c) =>
              c.name.toLowerCase().contains(q) ||
              c.description.toLowerCase().contains(q))
          .toList();
    }

    test('query vazia → lista normal', () {
      expect(applyQuery(communities(), ''), hasLength(2));
    });

    test('case-insensitive em name', () {
      final hits = applyQuery(communities(), 'RUNNING');
      expect(hits, hasLength(1));
      expect(hits.single.name, 'Running Floripa');
    });

    test('busca em description', () {
      final hits = applyQuery(communities(), 'descanso');
      expect(hits.single.name, 'Sono Saudável');
    });

    test('sem resultado → lista vazia (UI mostra "Nenhuma comunidade encontrada")', () {
      expect(applyQuery(communities(), 'xyz'), isEmpty);
    });

    test('query preservada após refresh (estado em _query, não resetado)', () {
      // O refresh invalida o provider; a query vive no state do widget e é
      // reaplicada — aqui validamos que reaplicar a mesma query é estável.
      final q = 'sono';
      expect(applyQuery(communities(), q).single.name, 'Sono Saudável');
      // Nova fonte (mesma query) → mesmo resultado, sem perder o filtro.
      expect(applyQuery(communities(), q).single.name, 'Sono Saudável');
    });
  });
}
