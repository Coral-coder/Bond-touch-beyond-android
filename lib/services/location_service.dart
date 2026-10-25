import 'dart:io';
import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Live location for partners: 100 m fixes, every 25 m on screen and every 100 m in the
/// background (as the iPhone app). The last fix is kept across launches so partners keep
/// seeing where you were, and when, until a new one comes in.
class LocationService {
  Position? last;
  double? speed;
  StreamSubscription<Position>? _sub;
  void Function(Position)? onUpdate;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getStringList('lastFix');
    if (s != null && s.length == 3) {
      last = Position(
        latitude: double.parse(s[0]),
        longitude: double.parse(s[1]),
        timestamp: DateTime.fromMillisecondsSinceEpoch(int.parse(s[2])),
        accuracy: 100,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
    }
  }

  Future<bool> start({bool background = false}) async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }
    await _sub?.cancel();
    _sub = Geolocator.getPositionStream(
      locationSettings: Platform.isIOS
          ? AppleSettings(
              accuracy:
                  LocationAccuracy.medium, // ~100 m: Wi-Fi / cell, little GPS
              distanceFilter: background ? 100 : 25,
              pauseLocationUpdatesAutomatically: false,
              allowBackgroundLocationUpdates: true,
              showBackgroundLocationIndicator: false,
            )
          : AndroidSettings(
              accuracy:
                  LocationAccuracy.medium, // ~100 m: Wi-Fi / cell, little GPS
              distanceFilter: background ? 100 : 25,
            ),
    ).listen(_got, onError: (_) {});
    return true;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> setBackground(bool background) async {
    if (_sub != null) await start(background: background);
  }

  /// One fresh fix (a partner asked), or the last one when it's under a minute old.
  Future<Position?> freshFix() async {
    if (last != null &&
        DateTime.now().difference(last!.timestamp) <
            const Duration(minutes: 1)) {
      return last;
    }
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      _got(p);
      return p;
    } catch (_) {
      return last;
    }
  }

  void _got(Position p) {
    if (p.speed >= 0 && p.speedAccuracy >= 0) {
      speed = p.speed;
    } else if (last != null) {
      final dt = p.timestamp.difference(last!.timestamp).inSeconds;
      speed = dt >= 5 && dt <= 600
          ? Geolocator.distanceBetween(
                  last!.latitude,
                  last!.longitude,
                  p.latitude,
                  p.longitude,
                ) /
                dt
          : null;
    }
    last = p;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setStringList('lastFix', [
        p.latitude.toString(),
        p.longitude.toString(),
        p.timestamp.millisecondsSinceEpoch.toString(),
      ]),
    );
    onUpdate?.call(p);
  }
}
