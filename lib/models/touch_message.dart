import 'dart:math' as math;

import 'package:uuid/uuid.dart';

/// A single "touch" exchanged between partners.
///
/// `pattern` is in the format of `generation` (see [TouchPattern]): generation 2 is an
/// on/off millisecond list; generation 3 (Bond Touch More, the on-screen and watch touch
/// bars) is one 50 ms position sample per entry — a 2D trace of time × finger position.
class TouchMessage {
  TouchMessage({
    String? id,
    required this.bondID,
    required this.senderID,
    required this.pattern,
    required this.generation,
    required this.colorRGB,
    required this.endColorRGB,
    DateTime? sentAt,
    this.meaningLabel,
    this.meaningEmoji,
    this.heartbeatBPM,
    this.effect,
  }) : id = id ?? const Uuid().v4().toUpperCase(),
       sentAt = sentAt ?? DateTime.now();

  final String id;

  /// Which bond (partner) this touch belongs to, so history is shown per partner.
  final String bondID;

  /// Who sent it (the partner's id, or "me").
  final String senderID;
  final List<int> pattern;

  /// 2 = on/off milliseconds, 3 = 50 ms position samples.
  final int generation;

  /// 0xRRGGBB start colour of the touch's gradient.
  final int colorRGB;

  /// 0xRRGGBB end colour of the gradient. Equals [colorRGB] for a single-colour touch.
  final int endColorRGB;

  /// When the sender created it.
  final DateTime sentAt;

  /// The saved meaning this touch is ("Love you"), when it was sent as one or closely
  /// matches one.
  String? meaningLabel;
  String? meaningEmoji;

  /// Set when this is a heartbeat (beats per minute): [pattern] then holds the EKG.
  int? heartbeatBPM;

  /// A light show on top of the pattern: "rainbow" plays it through the whole spectrum on
  /// the bracelet.
  String? effect;

  bool get isHeartbeat => heartbeatBPM != null;
  bool get isRainbow => effect == 'rainbow';

  /// The pattern as on/off milliseconds (for generation-2 bracelets).
  List<int> get onOffMs =>
      generation == 3 ? TouchPattern.onOffFromSamples(pattern) : pattern;

  /// The pattern as 50 ms position samples (for the Bond Touch More).
  List<int> get samples =>
      generation == 3 ? pattern : TouchPattern.samplesFromOnOff(pattern);
}

/// A change of the fingers on the bar: [t] seconds after the touch window opened, the
/// bar positions (0…8) now touched. Recorded as touch events arrive, independent of any
/// timer, so nothing depends on the screen keeping up.
class BarEvent {
  const BarEvent(this.t, this.fingers);
  final double t;
  final List<int> fingers;
}

/// The two touch formats the original backend and bracelets use (docs/BTM_TOUCH_FORMAT.md).
///
/// - **Generation 2** (Bond Touch / BT2 / BT4 / mini): an on/off millisecond list —
///   even indices finger down, odd indices finger up.
/// - **Generation 3** (Bond Touch More, the capacitive bar): one sample every 50 ms, each a
///   byte saying where the fingers are on the bar's 9 positions: `0xFF` no finger,
///   `0xF0 | p` one finger at position p (0…8), `(p2 << 4) | p1` two fingers. At most 200
///   samples (10 s). A slide is just consecutive samples whose position changes.
abstract final class TouchPattern {
  static const int sampleMs = 50;
  static const int maxSamples = 200;
  static const int positions = 9;
  static const int none = 0xFF;

  /// One sample byte for zero, one or two fingers (positions are clamped to 0…8).
  static int sample(List<int> fingers) {
    final p = fingers.take(2).map((f) => f.clamp(0, positions - 1)).toList();
    switch (p.length) {
      case 0:
        return none;
      case 1:
        return 0xF0 | p[0];
      default:
        return (p[1] << 4) | p[0];
    }
  }

  /// Turns finger changes into 50 ms samples. A slot gets the last finger position seen
  /// during it, so a tap shorter than 50 ms still counts, and a slot with no contact is
  /// "no finger". [duration] is how much of the window to sample (seconds).
  static List<int> samples(List<BarEvent> events, double duration) {
    const slot = sampleMs / 1000;
    final count = math.min(maxSamples, math.max(0, (duration / slot).ceil()));
    final out = <int>[];
    var state = <int>[];
    var i = 0;
    for (var n = 0; n < count; n++) {
      final end = (n + 1) * slot;
      var touched = state;
      while (i < events.length && events[i].t < end) {
        state = events[i].fingers;
        if (state.isNotEmpty) touched = state;
        i++;
      }
      if (state.isNotEmpty) touched = state;
      out.add(sample(touched));
    }
    return out;
  }

  /// How alike two touches are, 0…1, in any mix of formats — "the same general shape".
  /// Each touch becomes a line over time (finger position, or nothing), lined up by dynamic
  /// time warping; then a light penalty for a different length or number of presses. A
  /// gen-2 rhythm has no positions, so it's compared by contact only.
  static double matchScore(List<int> a, int ga, List<int> b, int gb) {
    final positional = ga == 3 && gb == 3;
    final la = _line(ga == 3 ? a : samplesFromOnOff(a), positional);
    final lb = _line(gb == 3 ? b : samplesFromOnOff(b), positional);
    return _shapeScore(la, lb);
  }

  /// Same as [matchScore] for two touch-bar touches.
  static double similarity(List<int> a, List<int> b) => matchScore(a, 3, b, 3);

  /// The score a touch needs to count as a saved meaning (about 75%).
  static double matchThreshold(int ga, int gb) => 0.72;

  static List<double?> _line(List<int> samples, bool positions) {
    return trimmed(samples).map((s) {
      final f = fingers(s);
      if (f.isEmpty) return null;
      return positions ? f.reduce((x, y) => x + y) / f.length : 0.0;
    }).toList();
  }

  static double _shapeScore(List<double?> a, List<double?> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final ratio = math.min(a.length, b.length) / math.max(a.length, b.length);
    if (ratio < 0.5) return 0;
    const n = 48;
    List<double?> resample(List<double?> s) {
      if (s.length <= 1) return List.filled(n, s[0]);
      final last = s.length - 1;
      final scale = last / (n - 1);
      return [
        for (var i = 0; i < n; i++)
          s[math.min(last, (i * scale + 0.5).truncate())],
      ];
    }

    double cost(double? x, double? y) {
      if (x == null && y == null) return 0;
      if (x != null && y != null) return math.min(1, (x - y).abs() / 3);
      return 1;
    }

    final ra = resample(a), rb = resample(b);
    final band = math.max(4, n ~/ 5);
    const inf = double.maxFinite;
    final d = List.generate(n + 1, (_) => List.filled(n + 1, inf));
    final len = List.generate(n + 1, (_) => List.filled(n + 1, 0));
    d[0][0] = 0;
    for (var i = 1; i <= n; i++) {
      for (var j = math.max(1, i - band); j <= math.min(n, i + band); j++) {
        var bestD = d[i - 1][j - 1], bestL = len[i - 1][j - 1];
        if (d[i - 1][j] < bestD) {
          bestD = d[i - 1][j];
          bestL = len[i - 1][j];
        }
        if (d[i][j - 1] < bestD) {
          bestD = d[i][j - 1];
          bestL = len[i][j - 1];
        }
        d[i][j] = bestD + cost(ra[i - 1], rb[j - 1]);
        len[i][j] = bestL + 1;
      }
    }
    final shape = 1 - d[n][n] / math.max(1, len[n][n]);
    var score = shape * (0.85 + 0.15 * ratio);
    final pressGap =
        (_presses(a.map((x) => x != null).toList()) -
                _presses(b.map((x) => x != null).toList()))
            .abs();
    if (pressGap == 1) {
      score *= 0.9;
    } else if (pressGap > 1) {
      score *= 0.6;
    }
    return score;
  }

  static int _presses(List<bool> c) {
    var count = 0;
    var prev = false;
    for (final on in c) {
      if (on && !prev) count++;
      prev = on;
    }
    return count;
  }

  /// The finger positions in one sample (empty when no finger is down).
  static List<int> fingers(int sample) {
    final lo = sample & 0x0F, hi = (sample >> 4) & 0x0F;
    return [lo, hi].where((p) => p < positions).toList();
  }

  /// Strips leading/trailing "no finger" samples and caps the length at 200.
  static List<int> trimmed(List<int> samples) {
    final first = samples.indexWhere((s) => s != none);
    final last = samples.lastIndexWhere((s) => s != none);
    if (first < 0 || last < 0) return [];
    return samples.sublist(first, last + 1).take(maxSamples).toList();
  }

  /// Generation 3 → 2: any sample with a finger is "on", in 50 ms steps (position is lost).
  static List<int> onOffFromSamples(List<int> samples) {
    final out = <int>[];
    var on = true;
    var run = 0;
    for (final s in trimmed(samples)) {
      final isOn = fingers(s).isNotEmpty;
      if (isOn == on) {
        run += sampleMs;
      } else {
        out.add(run);
        on = isOn;
        run = sampleMs;
      }
    }
    if (run > 0 && on) out.add(run);
    return out.isEmpty ? [200] : out;
  }

  /// Generation 2 → 3, as the original app does for a BTM: "on" becomes the sample
  /// `0x35` (two fingers, at positions 5 and 3), "off" becomes no finger.
  static List<int> samplesFromOnOff(List<int> onOff) {
    final out = <int>[];
    for (var i = 0; i < onOff.length; i++) {
      final count = math.max(1, (onOff[i] / sampleMs).round());
      out.addAll(List.filled(count, i.isEven ? 0x35 : none));
      if (out.length >= maxSamples) break;
    }
    return out.take(maxSamples).toList();
  }

  /// Duration of a pattern in milliseconds.
  static int durationMs(List<int> pattern, int generation) => generation == 3
      ? pattern.length * sampleMs
      : pattern.fold(0, (a, b) => a + b);
}
