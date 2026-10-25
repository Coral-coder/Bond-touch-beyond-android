import 'dart:convert';

import 'package:bond_touch_beyond/core/bond_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The derivation and sealing must match the iPhone app's BondCrypto byte for byte. The
/// expected values come from an independent implementation (Python: hashlib PBKDF2, RFC 5869
/// HKDF with an empty salt, AES-GCM) of the same spec.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('locator matches the iPhone app', () async {
    expect(await BondCrypto.locator('ABCD2345'), 'e47abad568026c4de59a77f6b518e69f');
    expect(await BondCrypto.locator('abcd2345'), 'e47abad568026c4de59a77f6b518e69f');
  });

  test('opens a payload sealed by the reference implementation', () async {
    final sealed = base64Decode('Ff0eHPJrlh2PF8pMWqs98wrcX1niBc9ReZYrMSFuq2Q+IzY3GUFH4ztz9YL/M9Bt93W67K7SXWC0');
    expect(await BondCrypto.open(sealed, 'ABCD2345'), {'name': 'Alex', 'ownerID': 'x'});
  });

  test('round trip, and a wrong code opens nothing', () async {
    final sealed = await BondCrypto.seal({'touch': 3}, 'ABCD2345');
    expect(await BondCrypto.open(sealed, 'ABCD2345'), {'touch': 3});
    expect(await BondCrypto.open(sealed, 'WXYZ6789'), isNull);
  });
}
