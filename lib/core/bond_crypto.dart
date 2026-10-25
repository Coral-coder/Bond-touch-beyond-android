import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end encryption for a bond, keyed by its secret invite code — exactly as the iPhone
/// app does it (BondCrypto.swift), so the two read each other's payloads.
///
/// The code only travels in the invite the two people exchange; it is never stored online.
/// It's stretched with PBKDF2-SHA256 (210 000 rounds, salt "BondTouchBeyond.bond.v2") and
/// split with HKDF-SHA256 into the AES-GCM key every payload is sealed with ("payload", 32
/// bytes) and an opaque **locator** naming the bond's records ("locator", 16 bytes → hex).
class BondCrypto {
  static final _cache = <String, _Secrets>{};
  static final _aes = AesGcm.with256bits();

  /// Derives (once; ~0.1–1 s) and caches the secrets for a code. Call before seal/open.
  static Future<void> prepare(String rawCode) async {
    await _secrets(rawCode.toUpperCase());
  }

  /// The opaque id naming this bond's records (32 hex chars).
  static Future<String> locator(String code) async =>
      (await _secrets(code.toUpperCase())).locator;

  /// Seals a JSON value: nonce (12) + ciphertext + tag (16), as CryptoKit's `combined`.
  static Future<Uint8List> seal(Object? json, String code) async {
    final s = await _secrets(code.toUpperCase());
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: s.key,
    );
    return Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Opens a sealed payload; null if it isn't one of this bond's.
  static Future<Object?> open(List<int> combined, String code) async {
    if (combined.length < 28) return null;
    final s = await _secrets(code.toUpperCase());
    try {
      final box = SecretBox(
        combined.sublist(12, combined.length - 16),
        nonce: combined.sublist(0, 12),
        mac: Mac(combined.sublist(combined.length - 16)),
      );
      return jsonDecode(utf8.decode(await _aes.decrypt(box, secretKey: s.key)));
    } catch (_) {
      return null;
    }
  }

  static Future<_Secrets> _secrets(String code) async {
    final cached = _cache[code];
    if (cached != null) return cached;
    // The stretch is slow on purpose: keep the result on this phone.
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('bondSecrets.$code');
    if (stored != null) {
      final parts = stored.split(':');
      final s = _Secrets(SecretKey(base64Decode(parts[0])), parts[1]);
      _cache[code] = s;
      return s;
    }
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 210000,
      bits: 256,
    );
    final master = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(code)),
      nonce: utf8.encode('BondTouchBeyond.bond.v2'),
    );
    // CryptoKit's HKDF with an empty salt (HMAC pads it to zeros, as RFC 5869 says).
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: master,
      nonce: const [],
      info: utf8.encode('payload'),
    );
    final loc = await Hkdf(hmac: Hmac.sha256(), outputLength: 16).deriveKey(
      secretKey: master,
      nonce: const [],
      info: utf8.encode('locator'),
    );
    final keyBytes = await key.extractBytes();
    final locator = (await loc.extractBytes())
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final s = _Secrets(SecretKey(keyBytes), locator);
    _cache[code] = s;
    await prefs.setString(
      'bondSecrets.$code',
      '${base64Encode(keyBytes)}:$locator',
    );
    return s;
  }
}

class _Secrets {
  _Secrets(this.key, this.locator);
  final SecretKey key;
  final String locator;
}
