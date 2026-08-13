/// Wellness domain models (Phase 2) — mirror the backend serializers.
library;

/// WellnessPerson (spec §4) — identity entity, separate from Clinical Person.
class WellnessPerson {
  const WellnessPerson({
    required this.uuid,
    required this.cognitoSub,
    this.userUuid,
    this.displayName = '',
    this.avatarUrl = '',
    this.heightCm,
    this.birthDate,
    this.gender = '',
    this.createdAt,
    this.updatedAt,
  });

  final String uuid;
  final String cognitoSub;
  final String? userUuid;
  final String displayName;
  final String avatarUrl;
  final double? heightCm;
  final String? birthDate; // ISO yyyy-MM-dd
  final String gender;
  final String? createdAt;
  final String? updatedAt;

  factory WellnessPerson.fromJson(Map<String, dynamic> json) {
    return WellnessPerson(
      uuid: json['uuid'] as String,
      cognitoSub: json['cognito_sub'] as String,
      userUuid: json['user_uuid'] as String?,
      displayName: (json['display_name'] as String?) ?? '',
      avatarUrl: (json['avatar_url'] as String?) ?? '',
      heightCm: switch (json['height_cm']) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      },
      birthDate: json['birth_date'] as String?,
      gender: (json['gender'] as String?) ?? '',
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'cognito_sub': cognitoSub,
        'user_uuid': userUuid,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'height_cm': heightCm,
        'birth_date': birthDate,
        'gender': gender,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };
}

/// WellnessProfile (spec §5) — 1:1 with WellnessPerson.
class WellnessProfile {
  const WellnessProfile({
    this.bedTimeMin = '',
    this.sleepTargetMin,
    this.goalSteps,
    this.timezone = 'America/Sao_Paulo',
    this.formulaClientVersion = '',
    this.createdAt,
    this.updatedAt,
  });

  final String bedTimeMin;
  final int? sleepTargetMin;
  final int? goalSteps;
  final String timezone;
  final String formulaClientVersion;
  final String? createdAt;
  final String? updatedAt;

  factory WellnessProfile.fromJson(Map<String, dynamic> json) {
    return WellnessProfile(
      bedTimeMin: (json['bed_time_min'] as String?) ?? '',
      sleepTargetMin: json['sleep_target_min'] as int?,
      goalSteps: json['goal_steps'] as int?,
      timezone: (json['timezone'] as String?) ?? 'America/Sao_Paulo',
      formulaClientVersion: (json['formula_client_version'] as String?) ?? '',
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'bed_time_min': bedTimeMin,
        'sleep_target_min': sleepTargetMin,
        'goal_steps': goalSteps,
        'timezone': timezone,
        'formula_client_version': formulaClientVersion,
      };
}

/// Response of POST /wellness/bootstrap/ (person + profile + created flag).
class WellnessBootstrapResponse {
  const WellnessBootstrapResponse({
    required this.person,
    required this.profile,
    required this.created,
  });

  final WellnessPerson person;
  final WellnessProfile profile;
  final bool created;

  factory WellnessBootstrapResponse.fromJson(Map<String, dynamic> json) {
    return WellnessBootstrapResponse(
      person: WellnessPerson.fromJson(json['person'] as Map<String, dynamic>),
      profile: WellnessProfile.fromJson(json['profile'] as Map<String, dynamic>),
      created: (json['created'] as bool?) ?? false,
    );
  }
}

/// Response of GET/PATCH /wellness/me/ (person + profile, no created flag).
class WellnessMe {
  const WellnessMe({required this.person, required this.profile});

  final WellnessPerson person;
  final WellnessProfile profile;

  factory WellnessMe.fromJson(Map<String, dynamic> json) {
    return WellnessMe(
      person: WellnessPerson.fromJson(json['person'] as Map<String, dynamic>),
      profile: WellnessProfile.fromJson(json['profile'] as Map<String, dynamic>),
    );
  }
}
