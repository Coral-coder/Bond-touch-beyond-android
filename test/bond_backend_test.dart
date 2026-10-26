import 'package:bond_touch_beyond/backend/bond_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android colours round-trip', () {
    expect(
      BondBackend.androidColor(0xFF4081),
      -49023,
    ); // 0xFFFF4081 as a signed int
    expect(BondBackend.rgb(-49023), 0xFF4081);
    expect(BondBackend.rgb(null), isNull);
  });

  test('generation and pattern parse leniently', () {
    expect(BondBackend.generation('3'), 3);
    expect(BondBackend.generation(3), 3);
    expect(BondBackend.generation('2'), 2);
    expect(BondBackend.generation(null), 2);
    expect(BondBackend.pattern([100, 200.0, 'x']), [100, 200]);
    expect(BondBackend.meaningRef(12), '12');
    expect(BondBackend.meaningRef(''), isNull);
  });

  test('oobCode from plain and Dynamic Link sign-in links', () {
    expect(
      BondBackend.oobCode(
        'https://bond-touch.firebaseapp.com/__/auth/action?mode=signIn&oobCode=ABC&apiKey=k',
      ),
      'ABC',
    );
    final inner = Uri.encodeComponent(
      'https://bond-touch.firebaseapp.com/?mode=signIn&oobCode=XYZ',
    );
    expect(
      BondBackend.oobCode('https://bondtouch.page.link/?link=$inner'),
      'XYZ',
    );
    expect(BondBackend.oobCode('not a link'), isNull);
  });

  test('token expiry from the exp claim', () {
    // {"exp":2000000000}
    const jwt = 'e30.eyJleHAiOjIwMDAwMDAwMDB9.sig';
    expect(
      BondBackend.tokenExpiry(jwt),
      DateTime.fromMillisecondsSinceEpoch(2000000000000),
    );
    expect(BondBackend.tokenExpiry('bad'), isNull);
  });
}
