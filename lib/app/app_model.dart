import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/bond_backend.dart';
import '../bracelet/bracelet_manager.dart';
import '../models/bond.dart';
import '../models/touch_message.dart';
import '../services/health_service.dart';
import '../services/location_service.dart';
import '../services/notifier.dart';

/// A partner on the original Bond Touch backend, with what it tells us about them.
class Partner {
  Partner(this.bond);
  final Bond bond;
  String get id => bond.id;
  String get name => bond.partnerName;
  int colorRGB = 0xFF4081;
  Uint8List? photo;
  String icon = '';
  bool online = false;
  DateTime? lastSeen;
  double? lat, lng;

  /// 0…1, as the partner's phone reports it.
  double? phoneBattery;
  List<Meaning> meanings = [];
}

/// The whole app's state: the account on the original Bond Touch backend, partners, the
/// bracelet, Health and location. Mirrors the original app's sync, as the iPhone app does
/// in its original-backend mode: it polls `GET bond/api/v4/bonds` (partners, invites,
/// received touches, Touch Language), plays new touches and acknowledges them, and pushes
/// this phone's changes with the matching calls. (The official app is woken by pushes sent to
/// its own app id, which no other app receives, so this one polls while it runs.)
class AppModel extends ChangeNotifier {
  AppModel();

  final bracelet = BraceletManager();
  final health = HealthService();
  final location = LocationService();
  final notifier = Notifier();

  // Account
  String email = '';
  String _idToken = '', _refreshToken = '';
  bool get signedIn => _refreshToken.isNotEmpty;
  String? syncError;
  DateTime? lastSync;

  // Profile
  String name = '';
  int colorRGB = 0xFF4081;
  Uint8List? myPhoto;
  bool get profileComplete => signedIn && name.isNotEmpty;

  bool sharingLocation = true;

  final partners = <Partner>[];
  final sentInvites = <Bond>[];
  final receivedInvites = <Bond>[];
  String? selectedID;
  Partner? get selected =>
      partners.where((p) => p.id == selectedID).firstOrNull ??
      partners.firstOrNull;

  final history = <TouchMessage>[];
  final _historyIDs = <String>{};

  /// The mood you logged last (shown on Stress & mood).
  ({String emoji, String label, String level, int energy, DateTime at})?
  loggedMood;

  bool inForeground = true;
  Timer? _poll;
  int _cycle = 0;
  bool _primed = false;
  Set<String> _seenTouches = {};
  DateTime _lastLocationPush = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _profileDebounce;

  // MARK: Start-up

  Future<void> start() async {
    await _loadLocal();
    await health.load();
    await location.load();
    await notifier.init();
    location.onUpdate = (_) => _pushLocation();
    bracelet.onTouchDrawn = (pattern, generation) =>
        sendTouch(pattern: pattern, generation: generation);
    bracelet.addListener(notifyListeners);
    unawaited(bracelet.start());
    unawaited(health.refresh().then((_) => notifyListeners()));
    notifyListeners();
    if (signedIn) _startSync();
  }

  Future<void> setForeground(bool fg) async {
    inForeground = fg;
    await location.setBackground(!fg);
    if (signedIn) {
      _startSync();
      if (fg) await syncOnce();
    }
  }

  // Every 4 s on screen, every 15 s in the background — as the iPhone app.
  void _startSync() {
    _poll?.cancel();
    _poll = Timer.periodic(
      Duration(seconds: inForeground ? 4 : 15),
      (_) => syncOnce(),
    );
    if (_cycle == 0) {
      unawaited(_setOnline(true));
      unawaited(syncOnce());
      if (sharingLocation) unawaited(location.start(background: !inForeground));
    }
  }

  // MARK: Account

  Future<void> sendSignInLink(String email) async {
    await BondBackend.sendSignInLink(email.trim());
    this.email = email.trim();
    (await SharedPreferences.getInstance()).setString('bt.email', this.email);
  }

  Future<void> completeSignIn(String link) async {
    final s = await BondBackend.signInWithLink(email, link);
    await _saveSession(s);
    // Your name and colour as the account has them.
    try {
      final profile = (await BondBackend.user(_idToken))['profile'] as Map?;
      final n = profile?['name'] as String?;
      if (n != null && n.isNotEmpty && name.isEmpty) name = n;
      final c = BondBackend.rgb(profile?['color']);
      if (c != null) colorRGB = c;
      final p = await SharedPreferences.getInstance();
      await p.setString('name', name);
      await p.setInt('color', colorRGB);
    } catch (_) {}
    _primed = false;
    _cycle = 0;
    notifyListeners();
    _startSync();
  }

  Future<void> signOut() async {
    _poll?.cancel();
    try {
      await BondBackend.setOnline(false, await _token());
    } catch (_) {}
    _idToken = _refreshToken = '';
    partners.clear();
    sentInvites.clear();
    receivedInvites.clear();
    _seenTouches = {};
    _primed = false;
    _cycle = 0;
    final p = await SharedPreferences.getInstance();
    for (final k in ['bt.idToken', 'bt.refreshToken', 'bonds', 'seenTouches']) {
      await p.remove(k);
    }
    notifyListeners();
  }

  Future<void> _saveSession(Session s) async {
    _idToken = s.idToken;
    _refreshToken = s.refreshToken;
    final p = await SharedPreferences.getInstance();
    await p.setString('bt.idToken', _idToken);
    await p.setString('bt.refreshToken', _refreshToken);
  }

  /// A valid ID token, refreshed when it's about to expire.
  Future<String> _token() async {
    final exp = BondBackend.tokenExpiry(_idToken);
    if (exp != null &&
        exp.difference(DateTime.now()) > const Duration(minutes: 5)) {
      return _idToken;
    }
    await _saveSession(await BondBackend.refresh(_refreshToken));
    return _idToken;
  }

  // MARK: Local storage

  Future<void> _loadLocal() async {
    final p = await SharedPreferences.getInstance();
    email = p.getString('bt.email') ?? '';
    _idToken = p.getString('bt.idToken') ?? '';
    _refreshToken = p.getString('bt.refreshToken') ?? '';
    name = p.getString('name') ?? '';
    colorRGB = p.getInt('color') ?? 0xFF4081;
    final photo = p.getString('photo');
    myPhoto = photo == null ? null : base64Decode(photo);
    sharingLocation = p.getBool('shareLocation') ?? true;
    selectedID = p.getString('selected');
    _seenTouches = (p.getStringList('seenTouches') ?? const []).toSet();
    _primed = _seenTouches.isNotEmpty;
    for (final raw in p.getStringList('bonds') ?? const []) {
      final b = Bond.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
      final partner = Partner(b)
        ..colorRGB = p.getInt('pcolor.${b.id}') ?? 0xFF4081;
      partners.add(partner);
    }
    for (final raw in p.getStringList('history') ?? const []) {
      final t = _touchFromStore(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
      history.add(t);
      _historyIDs.add(t.id);
    }
    final mood = p.getString('loggedMood');
    if (mood != null) {
      final m = jsonDecode(mood) as Map;
      loggedMood = (
        emoji: m['emoji'] as String,
        label: m['label'] as String,
        level: m['level'] as String,
        energy: (m['energy'] as num).toInt(),
        at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()),
      );
    }
  }

  Future<void> _saveBonds() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('bonds', [
      for (final x in partners) jsonEncode(x.bond.toJson()),
    ]);
    for (final x in partners) {
      await p.setInt('pcolor.${x.id}', x.colorRGB);
    }
  }

  Future<void> _saveHistory() async {
    final p = await SharedPreferences.getInstance();
    final keep = history.length > 300
        ? history.sublist(history.length - 300)
        : history;
    await p.setStringList('history', [
      for (final t in keep) jsonEncode(_touchToStore(t)),
    ]);
  }

  Map<String, Object?> _touchToStore(TouchMessage t) => {
    'id': t.id,
    'bond': t.bondID,
    'sender': t.senderID,
    'pattern': t.pattern,
    'gen': t.generation,
    'c': t.colorRGB,
    'e': t.endColorRGB,
    'at': t.sentAt.millisecondsSinceEpoch,
    'ml': t.meaningLabel,
  };

  TouchMessage _touchFromStore(Map<String, Object?> j) => TouchMessage(
    id: j['id'] as String,
    bondID: j['bond'] as String,
    senderID: j['sender'] as String,
    pattern: (j['pattern'] as List).cast<num>().map((n) => n.toInt()).toList(),
    generation: (j['gen'] as num).toInt(),
    colorRGB: (j['c'] as num).toInt(),
    endColorRGB: (j['e'] as num).toInt(),
    sentAt: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
    meaningLabel: j['ml'] as String?,
  );

  // MARK: Profile & settings

  Future<void> saveProfile({
    required String name,
    required int colorRGB,
    Uint8List? photo,
  }) async {
    this.name = name.trim();
    this.colorRGB = colorRGB;
    if (photo != null) myPhoto = photo;
    final p = await SharedPreferences.getInstance();
    await p.setString('name', this.name);
    await p.setInt('color', colorRGB);
    if (photo != null) await p.setString('photo', base64Encode(photo));
    notifyListeners();
    // The colour picker fires per change: send the last one.
    _profileDebounce?.cancel();
    _profileDebounce = Timer(const Duration(seconds: 1), () async {
      try {
        await BondBackend.updateProfile(
          this.name,
          this.colorRGB,
          await _token(),
        );
      } catch (_) {}
    });
  }

  Future<void> setLocationSharing(bool on) async {
    sharingLocation = on;
    (await SharedPreferences.getInstance()).setBool('shareLocation', on);
    on
        ? await location.start(background: !inForeground)
        : await location.stop();
    notifyListeners();
    try {
      await BondBackend.updateSharing(on, await _token());
    } catch (_) {}
    if (on) await _pushLocation(force: true);
  }

  Future<void> logMood(
    String emoji,
    String label,
    String level,
    int energy,
  ) async {
    loggedMood = (
      emoji: emoji,
      label: label,
      level: level,
      energy: energy,
      at: DateTime.now(),
    );
    (await SharedPreferences.getInstance()).setString(
      'loggedMood',
      jsonEncode({
        'emoji': emoji,
        'label': label,
        'level': level,
        'energy': energy,
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    notifyListeners();
  }

  /// Health readings changed (after asking for access, or a refresh).
  void healthChanged() => notifyListeners();

  void select(String id) {
    selectedID = id;
    SharedPreferences.getInstance().then((p) => p.setString('selected', id));
    notifyListeners();
  }

  // MARK: Bonds

  /// Invites someone by the email of their Bond Touch account.
  Future<void> invite(String email) async {
    await BondBackend.invite(email.trim(), await _token());
    await syncOnce();
  }

  Future<void> accept(Bond bond) async {
    await BondBackend.accept(bond.id, await _token());
    selectedID = bond.id;
    await syncOnce();
  }

  /// Unbonds, cancels a sent invite or declines a received one.
  Future<void> removeBond(Bond bond) async {
    await BondBackend.cancel(bond.id, await _token());
    partners.removeWhere((p) => p.id == bond.id);
    sentInvites.removeWhere((b) => b.id == bond.id);
    receivedInvites.removeWhere((b) => b.id == bond.id);
    if (selectedID == bond.id) selectedID = partners.firstOrNull?.id;
    await _saveBonds();
    notifyListeners();
  }

  Future<void> setPartnerColor(Partner partner, int rgb) async {
    partner.colorRGB = rgb;
    notifyListeners();
    await _saveBonds();
    try {
      await BondBackend.setPartnerColor(
        partner.id,
        rgb,
        partner.icon,
        await _token(),
      );
    } catch (_) {}
  }

  // MARK: Sync

  bool _syncing = false;

  Future<void> syncOnce() async {
    if (!signedIn || _syncing) return;
    _syncing = true;
    try {
      final token = await _token();
      await _apply(await BondBackend.bonds(token), token);
      _cycle++;
      // Partner details and presence change slowly: every few cycles.
      if (_cycle % 4 == 1) await _refreshDetails(token);
      if (_cycle % 8 == 1) await _setOnline(true);
      lastSync = DateTime.now();
      syncError = null;
    } catch (e) {
      syncError = '$e';
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _apply(List<Map<String, dynamic>> bonds, String token) async {
    final next = <Partner>[];
    sentInvites.clear();
    receivedInvites.clear();
    final toAck = <(String, String)>[];
    final fresh = <TouchMessage>[];

    for (final b in bonds) {
      final id = b['bondId'] as String?;
      if (id == null) continue;
      final profile = (b['profile'] as Map?) ?? const {};
      final settings = (b['settings'] as Map?) ?? const {};
      final email = b['email'] as String? ?? '';
      final n = profile['name'] as String?;
      final bond = Bond(
        id: id,
        partnerName: (n == null || n.isEmpty)
            ? (email.isEmpty ? 'Partner' : email)
            : n,
        email: email,
        status: b['status'] as String? ?? '',
        firebaseId: b['firebaseId'] as String? ?? '',
      );
      if (bond.sent) {
        sentInvites.add(bond);
        continue;
      }
      if (bond.received) {
        receivedInvites.add(bond);
        continue;
      }
      if (!bond.bonded) continue;

      // Keep what the slower refreshes learned.
      final known = partners.where((p) => p.id == id).firstOrNull;
      final partner = Partner(bond)
        ..colorRGB =
            BondBackend.rgb(settings['color']) ??
            BondBackend.rgb(profile['color']) ??
            0xFF4081
        ..icon = settings['icon'] as String? ?? ''
        ..online = known?.online ?? false
        ..lastSeen = known?.lastSeen
        ..lat = known?.lat
        ..lng = known?.lng
        ..phoneBattery = known?.phoneBattery
        ..meanings = [
          for (final m in (b['meanings'] as List? ?? const []))
            Meaning((m as Map).cast<String, dynamic>()),
        ];
      next.add(partner);

      // Received touches: into the history and onto the bracelet, then acknowledged so the
      // sender sees them delivered. The first sync after signing in only records what's
      // already there.
      for (final t in (b['touches'] as List? ?? const [])) {
        final touch = (t as Map).cast<String, dynamic>();
        final touchId = touch['id'] as String?;
        if (touchId == null || _seenTouches.contains(touchId)) continue;
        _seenTouches.add(touchId);
        final msg = (touch['message'] as Map?) ?? const {};
        final ms =
            (msg['timestamp'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
        final ref = BondBackend.meaningRef(touch['meaning']);
        final meaning = ref == null
            ? null
            : partner.meanings.where((m) => m.id == ref).firstOrNull;
        final tm = TouchMessage(
          id: touchId,
          bondID: id,
          senderID: bond.firebaseId.isEmpty ? id : bond.firebaseId,
          pattern: BondBackend.pattern(msg['pattern']),
          generation: BondBackend.generation(msg['generation']),
          colorRGB: meaning?.colorRGB ?? partner.colorRGB,
          endColorRGB: meaning?.endColorRGB ?? partner.colorRGB,
          sentAt: DateTime.fromMillisecondsSinceEpoch(ms),
          meaningLabel: meaning?.name,
        );
        fresh.add(tm);
        if (_primed) await _deliver(tm, partner);
        toAck.add((id, touchId));
      }
    }

    partners
      ..clear()
      ..addAll(next);
    for (final t in fresh) {
      if (_historyIDs.add(t.id)) history.add(t);
    }
    history.sort((a, b) => a.sentAt.compareTo(b.sentAt));
    _primed = true;
    if (selectedID == null || !partners.any((p) => p.id == selectedID)) {
      selectedID = partners.firstOrNull?.id;
    }
    final p = await SharedPreferences.getInstance();
    final seen = _seenTouches.toList();
    await p.setStringList(
      'seenTouches',
      seen.length > 2000 ? seen.sublist(seen.length - 2000) : seen,
    );
    await _saveBonds();
    if (fresh.isNotEmpty) await _saveHistory();
    for (final (bondId, touchId) in toAck) {
      try {
        await BondBackend.ackTouch(bondId, touchId, token);
      } catch (_) {}
    }
  }

  /// Partner location, sharing and phone battery.
  Future<void> _refreshDetails(String token) async {
    try {
      for (final d in await BondBackend.details(token)) {
        final partner = partners.where((p) => p.id == d['bondId']).firstOrNull;
        if (partner == null) continue;
        final loc = d['location'] as Map?;
        if (d['sharing'] == true && loc?['lat'] is num && loc?['lng'] is num) {
          partner.lat = (loc!['lat'] as num).toDouble();
          partner.lng = (loc['lng'] as num).toDouble();
        } else {
          partner.lat = partner.lng = null;
        }
        final raw = (d['battery'] as num?)?.toDouble();
        if (raw != null && raw >= 0) {
          partner.phoneBattery = raw > 1 ? (raw / 100).clamp(0, 1) : raw;
        }
      }
    } catch (_) {}
  }

  Future<void> _setOnline(bool online) async {
    try {
      final status = await BondBackend.setOnline(online, await _token());
      for (final p in partners) {
        final on = status[p.id];
        if (on == null) continue;
        if (p.online && !on) p.lastSeen = DateTime.now();
        p.online = on;
      }
    } catch (_) {}
  }

  /// This phone's location, at most every 30 s on screen and 2 min in the background.
  Future<void> _pushLocation({bool force = false}) async {
    final fix = location.last;
    if (!signedIn || !sharingLocation || fix == null) return;
    final gap = Duration(seconds: inForeground ? 30 : 120);
    if (!force && DateTime.now().difference(_lastLocationPush) < gap) return;
    _lastLocationPush = DateTime.now();
    try {
      await BondBackend.updateLocation(
        fix.latitude,
        fix.longitude,
        await _token(),
      );
    } catch (_) {}
  }

  /// A partner's touch: on the bracelet if connected, else the phone's vibration; a
  /// notification when the app isn't on screen. Touches over a minute old aren't replayed.
  Future<void> _deliver(TouchMessage t, Partner partner) async {
    if (DateTime.now().difference(t.sentAt) > const Duration(minutes: 1)) {
      return;
    }
    final played = await bracelet.play(t);
    if (!played && inForeground) await HapticFeedback.heavyImpact();
    if (!inForeground) {
      await notifier.show(
        t.id.hashCode,
        partner.name,
        t.meaningLabel ?? 'Sent you a touch',
      );
    }
  }

  // MARK: Sending

  Future<void> sendTouch({
    required List<int> pattern,
    required int generation,
    String? toBond,
  }) async {
    final partner = toBond == null
        ? selected
        : partners.where((p) => p.id == toBond).firstOrNull;
    if (partner == null || pattern.isEmpty) return;
    final t = TouchMessage(
      bondID: partner.id,
      senderID: 'me',
      pattern: pattern,
      generation: generation,
      colorRGB: colorRGB,
      endColorRGB: colorRGB,
    );
    history.add(t);
    _historyIDs.add(t.id);
    notifyListeners();
    final ref = await BondBackend.sendTouch(
      partner.id,
      pattern,
      generation,
      await _token(),
    );
    // The server matched it to a saved meaning: show it as that.
    final meaning = ref == null
        ? null
        : partner.meanings.where((m) => m.id == ref).firstOrNull;
    if (meaning != null) {
      t.meaningLabel = meaning.name;
      notifyListeners();
    }
    await _saveHistory();
  }

  /// Sends one of the partner's saved touches (Touch Language) by its id.
  Future<void> sendMeaning(Meaning m) async {
    final partner = selected;
    if (partner == null) return;
    final t = TouchMessage(
      bondID: partner.id,
      senderID: 'me',
      pattern: m.pattern,
      generation: m.generation,
      colorRGB: m.colorRGB,
      endColorRGB: m.endColorRGB,
      meaningLabel: m.name,
    );
    history.add(t);
    _historyIDs.add(t.id);
    notifyListeners();
    await BondBackend.sendMeaning(partner.id, m.id, await _token());
    await _saveHistory();
  }
}
