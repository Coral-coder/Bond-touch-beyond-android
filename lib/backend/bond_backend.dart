import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/touch_message.dart';

/// Client for the original Bond Touch backend: Firebase Auth (project `bond-touch`) and the
/// Bond API at `api.bond-touch.com`. The same account, bonds, touches and Touch Language as
/// the official Bond Touch apps, and the same calls as the iPhone app's original-backend
/// mode (`BondBackend.swift` / `BondAPI.swift`).
///
/// Sign-in is Firebase Email Link, as in the official app: a link is emailed, the user pastes
/// it back, and its `oobCode` is exchanged for an ID token, sent as `Authorization: Bearer`.
class BondBackend {
  // The official iOS app's Firebase config; the key is authorised by the bundle-ID header.
  static const apiKey = 'AIzaSyBKWjCliQP5HvvM6QtTQfFaGTvD27847_c';
  static const iosBundleId = 'com.impossible.bondtouch';
  static const apiBase = 'https://api.bond-touch.com/';
  static const continueURL = 'https://bond-touch.firebaseapp.com/';
  static const _identity = 'https://identitytoolkit.googleapis.com/v1/';

  static http.Client client = http.Client();

  // MARK: Auth

  static Future<Map<String, dynamic>> _auth(
    String url,
    Map<String, Object?> body,
  ) async {
    final res = await client.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'X-Ios-Bundle-Identifier': iosBundleId,
      },
      body: jsonEncode(body),
    );
    final j = _json(res.body) as Map<String, dynamic>? ?? {};
    if (res.statusCode >= 400) {
      throw BackendError(
        (j['error'] as Map?)?['message'] as String? ??
            'Sign-in failed (${res.statusCode})',
      );
    }
    return j;
  }

  /// Emails a sign-in link to `email`.
  static Future<void> sendSignInLink(String email) =>
      _auth('${_identity}accounts:sendOobCode?key=$apiKey', {
        'requestType': 'EMAIL_SIGNIN',
        'email': email,
        'continueUrl': continueURL,
        'canHandleCodeInApp': true,
      });

  /// Signs in with the link pasted from that email.
  static Future<Session> signInWithLink(String email, String link) async {
    final code = oobCode(link);
    if (code == null) {
      throw const BackendError(
        "Couldn't find the sign-in code in that link. Paste the whole link from the email.",
      );
    }
    final j = await _auth(
      '${_identity}accounts:signInWithEmailLink?key=$apiKey',
      {'email': email, 'oobCode': code},
    );
    final id = j['idToken'] as String?, refresh = j['refreshToken'] as String?;
    if (id == null || refresh == null) {
      throw const BackendError('No token in response');
    }
    return Session(id, refresh, j['localId'] as String? ?? '');
  }

  /// The `oobCode` in a pasted sign-in link (plain, or wrapped in a Dynamic Link's `link=`).
  static String? oobCode(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null) return null;
    final code = uri.queryParameters['oobCode'];
    if (code != null && code.isNotEmpty) return code;
    final inner = uri.queryParameters['link'];
    return inner == null
        ? null
        : Uri.tryParse(inner)?.queryParameters['oobCode'];
  }

  /// A fresh ID token from the refresh token (ID tokens last an hour).
  static Future<Session> refresh(String refreshToken) async {
    final res = await client.post(
      Uri.parse('https://securetoken.googleapis.com/v1/token?key=$apiKey'),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-Ios-Bundle-Identifier': iosBundleId,
      },
      body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
    );
    final j = _json(res.body) as Map<String, dynamic>? ?? {};
    if (res.statusCode >= 400) {
      throw BackendError(
        (j['error'] as Map?)?['message'] as String? ??
            'Token refresh failed (${res.statusCode})',
      );
    }
    final id = j['id_token'] as String?, next = j['refresh_token'] as String?;
    if (id == null || next == null) {
      throw const BackendError('Token refresh returned no token');
    }
    return Session(id, next, j['user_id'] as String? ?? '');
  }

  /// When a Firebase ID token expires (its `exp` claim).
  static DateTime? tokenExpiry(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return null;
    try {
      final claims =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map;
      final exp = claims['exp'] as num?;
      return exp == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((exp * 1000).toInt());
    } catch (_) {
      return null;
    }
  }

  // MARK: Bond API

  static Future<Object?> _call(
    String path,
    String method,
    String bearer, [
    Map<String, Object?>? body,
  ]) async {
    final req = http.Request(method, Uri.parse(apiBase + path))
      ..headers['Authorization'] = 'Bearer $bearer'
      ..headers['Content-Type'] = 'application/json';
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await client.send(req));
    if (res.statusCode >= 400) {
      throw BackendError('HTTP ${res.statusCode} at /$path: ${res.body}');
    }
    return res.body.isEmpty ? null : _json(res.body);
  }

  static Object? _json(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  /// `GET bond/api/v3/user` — the account (email, profile {name, color, version, …}).
  static Future<Map<String, dynamic>> user(String bearer) async =>
      (await _call('bond/api/v3/user', 'GET', bearer))
          as Map<String, dynamic>? ??
      {};

  /// `GET bond/api/v4/bonds` — partners, sent and received invites, with each partner's
  /// unacknowledged touches and their Touch Language.
  static Future<List<Map<String, dynamic>>> bonds(String bearer) async {
    final j = await _call('bond/api/v4/bonds', 'GET', bearer) as Map?;
    return [
      for (final b in (j?['bonds'] as List? ?? const []))
        (b as Map).cast<String, dynamic>(),
    ];
  }

  /// `GET bond/api/v3/bonds/details` — per-partner location, battery and sharing flag.
  static Future<List<Map<String, dynamic>>> details(String bearer) async {
    final j = await _call('bond/api/v3/bonds/details', 'GET', bearer);
    return [
      for (final d in (j as List? ?? const []))
        (d as Map).cast<String, dynamic>(),
    ];
  }

  /// Invites someone by their account email.
  static Future<void> invite(String email, String bearer) =>
      _call('bond/api/v4/bonds', 'POST', bearer, {'email': email});

  static Future<void> accept(String bondId, String bearer) =>
      _call('bond/api/v4/bonds/$bondId/accept', 'POST', bearer);

  /// Unbonds, cancels a sent invite or declines a received one.
  static Future<void> cancel(String bondId, String bearer) =>
      _call('bond/api/v3/bonds/$bondId', 'DELETE', bearer);

  /// Your colour for a partner.
  static Future<void> setPartnerColor(
    String bondId,
    int rgb,
    String icon,
    String bearer,
  ) => _call('bond/api/v3/bonds/$bondId/settings', 'PUT', bearer, {
    'color': androidColor(rgb),
    'icon': icon,
  });

  /// Sends a touch; returns the id of the saved meaning the server matched, if any.
  static Future<String?> sendTouch(
    String bondId,
    List<int> pattern,
    int generation,
    String bearer,
  ) async {
    final j =
        await _call('bond/api/v3/bonds/$bondId/touches', 'POST', bearer, {
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'pattern': generation == 3
                  ? TouchPattern.trimmed(pattern)
                  : (pattern.isEmpty ? [200] : pattern),
              'generation': generation == 3 ? '3' : '2',
            })
            as Map?;
    return meaningRef(j?['meaning']);
  }

  /// Sends a saved meaning by id (the partner plays it as that meaning).
  static Future<void> sendMeaning(
    String bondId,
    String meaningId,
    String bearer,
  ) => _call('bond/api/v3/bonds/$bondId/touches/basic', 'POST', bearer, {
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'meaningId': meaningId,
  });

  static Future<void> ackTouch(String bondId, String touchId, String bearer) =>
      _call(
        'bond/api/v3/bonds/$bondId/touches/$touchId/acknowledge',
        'PUT',
        bearer,
      );

  /// Goes online / offline; returns each partner's online state by bond id.
  static Future<Map<String, bool>> setOnline(bool online, String bearer) async {
    final j =
        await _call('bond/api/v3/user/status', 'PUT', bearer, {
              'online': online,
            })
            as Map?;
    return {
      for (final p in (j?['partners'] as List? ?? const []))
        if ((p as Map)['bondId'] is String)
          p['bondId'] as String: p['online'] == true,
    };
  }

  static Future<void> updateLocation(double lat, double lng, String bearer) =>
      _call('bond/api/v3/user/details/location', 'PUT', bearer, {
        'lat': lat,
        'lng': lng,
        'timezone': DateTime.now().timeZoneName,
      });

  static Future<void> updateSharing(bool sharing, String bearer) => _call(
    'bond/api/v3/user/details/sharing',
    'PUT',
    bearer,
    {'sharing': sharing},
  );

  /// The account's name and colour (read, change, bump `profile.version`, write back).
  static Future<void> updateProfile(String name, int rgb, String bearer) async {
    final u = Map<String, dynamic>.from(await user(bearer));
    if (u.isEmpty) return;
    final profile = Map<String, dynamic>.from(u['profile'] as Map? ?? {});
    profile['name'] = name;
    profile['color'] = androidColor(rgb);
    profile['version'] = ((profile['version'] as num?)?.toInt() ?? 0) + 1;
    u['profile'] = profile;
    u.remove('bypassFlags');
    await _call('bond/api/v3/user', 'PUT', bearer, u);
  }

  // MARK: Wire helpers

  /// Android ARGB int → 0xRRGGBB.
  static int? rgb(Object? v) => v is num ? v.toInt() & 0xFFFFFF : null;

  /// 0xRRGGBB → opaque Android ARGB int (signed 32-bit, as Android stores it).
  static int androidColor(int rgb) =>
      (0xFF000000 | (rgb & 0xFFFFFF)).toSigned(32);

  /// `generation` comes as "2" / "3" or a number; anything else is 2.
  static int generation(Object? v) => (v == '3' || v == 3) ? 3 : 2;

  static List<int> pattern(Object? v) => [
    for (final n in (v as List? ?? const []))
      if (n is num) n.toInt(),
  ];

  static String? meaningRef(Object? v) =>
      v is String && v.isNotEmpty ? v : (v is num ? '$v' : null);
}

class Session {
  const Session(this.idToken, this.refreshToken, this.uid);
  final String idToken, refreshToken, uid;
}

class BackendError implements Exception {
  const BackendError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A saved touch in a partner's Touch Language (server `MeaningDto`).
class Meaning {
  Meaning(this.json);
  final Map<String, dynamic> json;
  String get id => '${json['id']}';
  String get name => json['name'] as String? ?? 'Touch';
  int get colorRGB => BondBackend.rgb(json['startColor']) ?? 0xFF2E74;
  int get endColorRGB => BondBackend.rgb(json['endColor']) ?? colorRGB;
  List<int> get pattern => BondBackend.pattern(json['pattern']);
  int get generation => BondBackend.generation(json['generation']);
}
