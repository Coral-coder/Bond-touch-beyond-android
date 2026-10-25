import 'dart:convert';
import 'dart:typed_data';

/// The iPhone app encodes its payloads with Swift's default `JSONEncoder`, and both apps must
/// read each other's byte for byte:
///   • dates are seconds since 2001-01-01 00:00 UTC (Apple's reference date), as a number;
///   • binary data is a base64 string;
///   • UUIDs are uppercase strings;
///   • an absent optional is simply a missing key.
class SwiftJson {
  static final DateTime referenceDate = DateTime.utc(2001, 1, 1);

  static double date(DateTime d) =>
      d.toUtc().difference(referenceDate).inMicroseconds /
      Duration.microsecondsPerSecond;

  static DateTime parseDate(Object? v) {
    final seconds = (v as num?)?.toDouble() ?? 0;
    return referenceDate
        .add(
          Duration(
            microseconds: (seconds * Duration.microsecondsPerSecond).round(),
          ),
        )
        .toLocal();
  }

  static DateTime? parseDateOrNull(Object? v) =>
      v == null ? null : parseDate(v);

  static String data(List<int> bytes) => base64Encode(bytes);
  static Uint8List parseData(Object? v) => base64Decode(v as String);

  /// Drops null values, as Swift's `encodeIfPresent` does.
  static Map<String, Object?> compact(Map<String, Object?> m) => {
    for (final e in m.entries)
      if (e.value != null) e.key: e.value,
  };
}
