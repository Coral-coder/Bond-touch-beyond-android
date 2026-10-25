import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/swift_json.dart';

/// Your body's side of stress & mood, from Health Connect: heart-rate variability against
/// your usual, resting heart rate, last night's sleep, and the day's heart rate — the same
/// battery the iPhone app works out from Apple Health, shared with partners as a `MoodShare`.
///
/// The last good reading is kept on the phone, so a read that returns nothing (no access yet,
/// the watch not worn) never blanks what partners see.
class HealthService {
  final _health = Health();

  int? bodyBattery;
  double? hrv, hrvBaseline, restingHR, sleepHours;
  List<({DateTime at, double hrv, double stress})> series = [];
  List<({DateTime at, double bpm})> heartRate = [];
  DateTime? readAt;

  // Apple Health only has SDNN for HRV and per-stage sleep; Health Connect has RMSSD and
  // whole sleep sessions.
  static final _hrvType = Platform.isIOS
      ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
      : HealthDataType.HEART_RATE_VARIABILITY_RMSSD;
  static final _sleepType = Platform.isIOS
      ? HealthDataType.SLEEP_ASLEEP
      : HealthDataType.SLEEP_SESSION;

  static final _types = [
    _hrvType,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.HEART_RATE,
    _sleepType,
  ];

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('healthCache');
    if (raw == null) return;
    final c = jsonDecode(raw) as Map<String, Object?>;
    bodyBattery = (c['battery'] as num?)?.toInt();
    hrv = (c['hrv'] as num?)?.toDouble();
    hrvBaseline = (c['base'] as num?)?.toDouble();
    restingHR = (c['rhr'] as num?)?.toDouble();
    sleepHours = (c['sleep'] as num?)?.toDouble();
    readAt = c['at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((c['at'] as num).toInt());
    series = [
      for (final r in (c['series'] as List? ?? const []))
        (
          at: DateTime.fromMillisecondsSinceEpoch((r[0] as num).toInt()),
          hrv: (r[1] as num).toDouble(),
          stress: (r[2] as num).toDouble(),
        ),
    ];
    heartRate = [
      for (final r in (c['hr'] as List? ?? const []))
        (
          at: DateTime.fromMillisecondsSinceEpoch((r[0] as num).toInt()),
          bpm: (r[1] as num).toDouble(),
        ),
    ];
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      'healthCache',
      jsonEncode({
        'battery': bodyBattery,
        'hrv': hrv,
        'base': hrvBaseline,
        'rhr': restingHR,
        'sleep': sleepHours,
        'at': readAt?.millisecondsSinceEpoch,
        'series': [
          for (final s in series)
            [s.at.millisecondsSinceEpoch, s.hrv, s.stress],
        ],
        'hr': [
          for (final h in heartRate) [h.at.millisecondsSinceEpoch, h.bpm],
        ],
      }),
    );
  }

  /// Asks for access the first time (the system sheet).
  Future<bool> requestAccess() async {
    await _health.configure();
    return _health.requestAuthorization(
      _types,
      permissions: _types.map((_) => HealthDataAccess.READ).toList(),
    );
  }

  /// Lower HRV than usual reads as more stress (50 = usual).
  static double stress(double hrv, double baseline) =>
      min(100, max(0, 50 - (hrv / baseline - 1) * 90));

  /// Re-reads Health Connect. False when it gave nothing (the last reading then stays).
  Future<bool> refresh() async {
    try {
      await _health.configure();
      final now = DateTime.now();
      final month = await _health.getHealthDataFromTypes(
        types: [_hrvType, HealthDataType.RESTING_HEART_RATE],
        startTime: now.subtract(const Duration(days: 30)),
        endTime: now,
      );
      final week = await _health.getHealthDataFromTypes(
        types: const [HealthDataType.HEART_RATE],
        startTime: now.subtract(const Duration(days: 7)),
        endTime: now,
      );
      final sleeps = await _health.getHealthDataFromTypes(
        types: [_sleepType],
        startTime: now.subtract(const Duration(hours: 20)),
        endTime: now,
      );
      double v(HealthDataPoint p) =>
          (p.value as NumericHealthValue).numericValue.toDouble();
      final hrvs = month.where((p) => p.type == _hrvType).toList()
        ..sort((a, b) => a.dateTo.compareTo(b.dateTo));
      final rhrs =
          month
              .where((p) => p.type == HealthDataType.RESTING_HEART_RATE)
              .toList()
            ..sort((a, b) => a.dateTo.compareTo(b.dateTo));
      final hrs = week.toList()..sort((a, b) => a.dateTo.compareTo(b.dateTo));
      if (hrvs.isEmpty &&
          rhrs.isEmpty &&
          hrs.isEmpty &&
          sleeps.isEmpty &&
          readAt != null) {
        return false;
      }

      // The last day of readings, ending now or at the newest one (watch not worn since).
      final hrvEnd = hrvs.isEmpty ? now : hrvs.last.dateTo;
      final recent = hrvs
          .where(
            (p) => p.dateTo.isAfter(hrvEnd.subtract(const Duration(hours: 36))),
          )
          .map(v)
          .toList();
      hrv = recent.isEmpty
          ? null
          : recent.reduce((a, b) => a + b) / recent.length;
      hrvBaseline = _median(hrvs.map(v).toList());
      final base = hrvBaseline;
      if (base != null && base > 0) {
        final start = hrvEnd.subtract(const Duration(hours: 24));
        series = [
          for (final p in hrvs.where((p) => p.dateTo.isAfter(start)))
            (at: p.dateTo, hrv: v(p), stress: stress(v(p), base)),
        ];
      }
      if (hrs.isNotEmpty) {
        final start = hrs.last.dateTo.subtract(const Duration(hours: 24));
        final buckets = <int, List<double>>{};
        for (final p in hrs.where((p) => p.dateTo.isAfter(start))) {
          buckets
              .putIfAbsent(p.dateTo.millisecondsSinceEpoch ~/ 600000, () => [])
              .add(v(p));
        }
        heartRate = [
          for (final k in buckets.keys.toList()..sort())
            (
              at: DateTime.fromMillisecondsSinceEpoch(k * 600000 + 300000),
              bpm: (buckets[k]!.reduce((a, b) => a + b) / buckets[k]!.length)
                  .roundToDouble(),
            ),
        ];
      }
      restingHR = rhrs.isEmpty ? null : v(rhrs.last);
      final asleep = sleeps.fold<double>(
        0,
        (t, p) => t + p.dateTo.difference(p.dateFrom).inMinutes / 60,
      );
      sleepHours = sleeps.isEmpty ? null : asleep;

      var score = 60.0;
      if (hrv != null && base != null && base > 0) {
        score += (hrv! / base - 1) * 80;
      }
      final rBase = _median(rhrs.map(v).toList());
      if (restingHR != null && rBase != null && rBase > 0) {
        score -= (restingHR! / rBase - 1) * 120;
      }
      if (sleepHours != null) score += (sleepHours! - 7) * 6;
      bodyBattery = (hrv == null && sleepHours == null)
          ? null
          : min(100, max(3, score)).round();
      readAt = now;
      await _save();
      return true;
    } catch (_) {
      return false;
    }
  }

  static double? _median(List<double> v) {
    if (v.isEmpty) return null;
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }

  /// What partners see (the iPhone app's MoodShare), or null with nothing to share yet.
  Map<String, Object?>? moodShare({
    ({String emoji, String label, String level, int energy, DateTime at})?
    logged,
  }) {
    final recent =
        logged != null &&
            DateTime.now().difference(logged.at) < const Duration(hours: 12)
        ? logged
        : null;
    final body = bodyBattery;
    final level = switch ((body, recent)) {
      (int b, final r?) => ((b + r.energy) / 2).round(),
      (int b, null) => b,
      (null, final r?) => r.energy,
      _ => null,
    };
    if (level == null) return null;
    final face = _face(100 - level);
    return SwiftJson.compact({
      'emoji': recent?.emoji ?? face.$1,
      'label': recent?.label ?? face.$2,
      'battery': level,
      'level': recent?.level ?? (level < 20 ? 'low' : 'ok'),
      'at': SwiftJson.date(recent?.at ?? DateTime.now()),
      'series': [
        for (final s
            in series.length > 60 ? series.sublist(series.length - 60) : series)
          [
            (s.at.millisecondsSinceEpoch / 1000).roundToDouble(),
            (s.hrv * 10).round() / 10,
            s.stress.roundToDouble(),
          ],
      ],
      'heartRate': [
        for (final h
            in heartRate.length > 144
                ? heartRate.sublist(heartRate.length - 144)
                : heartRate)
          [(h.at.millisecondsSinceEpoch / 1000).roundToDouble(), h.bpm],
      ],
    });
  }

  static (String, String) _face(int stress) {
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
    return (f.$2, f.$3);
  }
}
