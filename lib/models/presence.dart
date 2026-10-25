import '../core/swift_json.dart';

/// A phone's status snapshot, shared (sealed) with its partner — the iPhone app's
/// `PresenceInfo`. Kept as the decoded JSON so fields this version doesn't know survive a
/// merge, with typed getters for what the app shows.
class Presence {
  Presence(this.json);
  final Map<String, Object?> json;

  bool get online => json['online'] as bool? ?? false;
  double? get lat => (json['lat'] as num?)?.toDouble();
  double? get lng => (json['lng'] as num?)?.toDouble();
  DateTime? get locationAt => SwiftJson.parseDateOrNull(json['locationAt']);
  double? get speed => (json['speed'] as num?)?.toDouble();
  double? get phoneBattery => (json['phoneBattery'] as num?)?.toDouble();
  bool? get phoneCharging => json['phoneCharging'] as bool?;
  bool? get bracelet => json['bracelet'] as bool?;
  int? get braceletBattery => (json['braceletBattery'] as num?)?.toInt();
  DateTime? get braceletLastConnected =>
      SwiftJson.parseDateOrNull(json['braceletLastConnected']);
  bool? get watchStandIn => json['watchStandIn'] as bool?;
  Map<String, Object?>? get weather =>
      (json['weather'] as Map?)?.cast<String, Object?>();
  MoodShare? get mood => json['mood'] is Map
      ? MoodShare((json['mood'] as Map).cast<String, Object?>())
      : null;
  DateTime get sentAt => SwiftJson.parseDate(json['sentAt']);
  bool get locationOff => json['locationOff'] == true;
  bool get moodOff => json['moodOff'] == true;

  /// This snapshot over the previous one: anything it lacks stays as last reported, unless
  /// the partner switched that sharing off (same rule as the iPhone app).
  Presence mergedOver(Presence? old) {
    if (old == null) return this;
    final out = Map<String, Object?>.from(json);
    void keep(List<String> keys) {
      for (final k in keys) {
        if (out[k] == null && old.json[k] != null) out[k] = old.json[k];
      }
    }

    if (out['lat'] == null && !locationOff) {
      keep(['lat', 'lng', 'locationAt', 'speed']);
    }
    if (!moodOff) {
      if (out['mood'] == null) {
        keep(['mood']);
      } else if (old.json['mood'] is Map) {
        final mood = Map<String, Object?>.from(out['mood'] as Map);
        final oldMood = (old.json['mood'] as Map).cast<String, Object?>();
        for (final k in ['series', 'heartRate']) {
          if ((mood[k] as List?)?.isEmpty ?? true) mood[k] = oldMood[k];
        }
        out['mood'] = SwiftJson.compact(mood);
      }
    }
    keep([
      'weather',
      'phoneBattery',
      'phoneCharging',
      'braceletBattery',
      'braceletLastConnected',
    ]);
    return Presence(out);
  }
}

/// How someone's feeling and their personal battery, with the day's HRV and heart rate.
class MoodShare {
  MoodShare(this.json);
  final Map<String, Object?> json;

  String get emoji => json['emoji'] as String? ?? '';
  String get label => json['label'] as String? ?? '';
  int get battery => (json['battery'] as num?)?.toInt() ?? 50;
  int get stress => 100 - battery;
  String get level => json['level'] as String? ?? 'ok';
  DateTime get at => SwiftJson.parseDate(json['at']);

  /// [time, HRV ms, stress] per reading.
  List<({DateTime at, double hrv, double stress})> get series => [
    for (final r in (json['series'] as List? ?? const []))
      if (r is List && r.length == 3)
        (
          at: DateTime.fromMillisecondsSinceEpoch(
            ((r[0] as num) * 1000).round(),
          ),
          hrv: (r[1] as num).toDouble(),
          stress: (r[2] as num).toDouble(),
        ),
  ];

  /// [time, bpm], one per 10 minutes.
  List<({DateTime at, double bpm})> get heartRate => [
    for (final r in (json['heartRate'] as List? ?? const []))
      if (r is List && r.length == 2)
        (
          at: DateTime.fromMillisecondsSinceEpoch(
            ((r[0] as num) * 1000).round(),
          ),
          bpm: (r[1] as num).toDouble(),
        ),
  ];

  static ({String emoji, String label}) face(int stress) {
    const faces = [
      (15, '😌', 'Relaxed'),
      (30, '🙂', 'Calm'),
      (45, '😐', 'Steady'),
      (60, '😕', 'A bit tense'),
      (75, '😟', 'Stressed'),
      (90, '😣', 'Very stressed'),
      (101, '😵‍💫', 'Overwhelmed'),
    ];
    final f = faces.firstWhere((f) => stress < f.$1, orElse: () => faces.last);
    return (emoji: f.$2, label: f.$3);
  }
}
