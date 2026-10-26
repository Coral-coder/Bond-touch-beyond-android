import '../core/swift_json.dart';

/// How you're feeling and your personal battery, with the day's HRV and heart rate.
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
