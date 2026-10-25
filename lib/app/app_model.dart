import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/firebase_config.dart';
import '../bracelet/bracelet_manager.dart';
import '../core/bond_crypto.dart';
import '../core/swift_json.dart';
import '../models/bond.dart';
import '../models/chat_message.dart';
import '../models/presence.dart';
import '../models/touch_message.dart';
import '../relay/firebase_relay.dart';
import '../services/health_service.dart';
import '../services/location_service.dart';
import '../services/notifier.dart';

/// A partner: their bond plus what we know about them (profile, last status, photo).
class Partner {
  Partner(this.bond);
  final Bond bond;
  String get id => bond.code;
  String get name => bond.partnerName;
  int colorRGB = 0xFF4081;
  Uint8List? photo;
  Presence? presence;
  String? pushToken;
  int seenTouch = 0, seenMessage = 0;
  int? lastBPM;
  DateTime? lastBPMAt;

  bool get online =>
      presence?.online == true &&
      DateTime.now().difference(presence!.sentAt) < const Duration(minutes: 15);
}

/// The whole app's state and its link to partners, the bracelet, Health and location.
class AppModel extends ChangeNotifier {
  AppModel();

  final relay = FirebaseRelay();
  final bracelet = BraceletManager();
  final health = HealthService();
  final location = LocationService();
  final notifier = Notifier();
  final _battery = Battery();

  bool firebaseReady = false;
  String? firebaseError;
  String myID = '';

  // Profile
  String name = '';
  int colorRGB = 0xFF4081;
  Uint8List? myPhoto;
  bool get profileComplete => name.isNotEmpty;

  // Settings
  bool sharingLocation = true;
  bool shareMood = true;

  final partners = <Partner>[];
  final pending = <Bond>[];
  String? selectedID;
  Partner? get selected =>
      partners.where((p) => p.id == selectedID).firstOrNull ??
      partners.firstOrNull;

  final history = <TouchMessage>[];
  final chats = <String, List<ChatMessage>>{};
  final _historyIDs = <String>{};

  /// The mood you logged last (kept 12 hours in what partners see).
  ({String emoji, String label, String level, int energy, DateTime at})?
  loggedMood;

  bool inForeground = true;
  Timer? _poll;
  final _watches = <String, StreamSubscription<void>>{};
  DateTime _lastPresence = DateTime.fromMillisecondsSinceEpoch(0);

  // MARK: Start-up

  Future<void> start() async {
    await _loadLocal();
    await health.load();
    await location.load();
    await notifier.init();
    location.onUpdate = (_) => publishPresence();
    bracelet.onTouchDrawn = (pattern, generation) =>
        sendTouch(pattern: pattern, generation: generation);
    bracelet.addListener(_braceletChanged);
    unawaited(bracelet.start());
    try {
      await Firebase.initializeApp(options: FirebaseConfig.options);
      myID = await relay.signIn();
      firebaseReady = true;
    } catch (e) {
      firebaseError = '$e';
    }
    notifyListeners();
    if (!firebaseReady) return;
    if (sharingLocation) unawaited(location.start());
    unawaited(health.refresh().then((_) => publishPresence(force: true)));
    await refreshAll();
    _startPolling();
    for (final p in partners) {
      _watch(p.bond);
    }
  }

  void _braceletChanged() {
    notifyListeners();
    publishPresence(force: true);
  }

  Future<void> setForeground(bool fg) async {
    inForeground = fg;
    await location.setBackground(!fg);
    _startPolling();
    await publishPresence(force: true);
    if (fg) await refreshAll();
  }

  void _startPolling() {
    _poll?.cancel();
    // Partners' changes arrive live through the cursor listener (`_watch`); polling is only
    // a fallback, kept slow for Firestore's free daily read allowance.
    _poll = Timer.periodic(
      Duration(seconds: inForeground ? 30 : 60),
      (_) => refreshAll(),
    );
  }

  void _watch(Bond bond) {
    _watches[bond.code]?.cancel();
    _watches[bond.code] = relay.watch(bond).listen((_) => refreshAll());
  }

  // MARK: Local storage

  Future<void> _loadLocal() async {
    final p = await SharedPreferences.getInstance();
    name = p.getString('name') ?? '';
    colorRGB = p.getInt('color') ?? 0xFF4081;
    final photo = p.getString('photo');
    myPhoto = photo == null ? null : base64Decode(photo);
    sharingLocation = p.getBool('shareLocation') ?? true;
    shareMood = p.getBool('shareMood') ?? true;
    selectedID = p.getString('selected');
    for (final raw in p.getStringList('bonds') ?? const []) {
      final b = Bond.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
      if (b.pending) {
        pending.add(b);
      } else {
        final partner = Partner(b);
        final cached = p.getString('presence.${b.code}');
        if (cached != null) {
          partner.presence = Presence(
            (jsonDecode(cached) as Map).cast<String, Object?>(),
          );
        }
        partner.colorRGB = p.getInt('pcolor.${b.code}') ?? 0xFF4081;
        final ph = p.getString('pphoto.${b.code}');
        if (ph != null) partner.photo = base64Decode(ph);
        partners.add(partner);
      }
    }
    for (final raw in p.getStringList('history') ?? const []) {
      final t = _touchFromStore(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
      history.add(t);
      _historyIDs.add(t.id);
    }
    for (final b in [...partners.map((p) => p.bond), ...pending]) {
      chats[b.code] = [
        for (final raw in p.getStringList('chat.${b.code}') ?? const [])
          ChatMessage.fromJson(
            (jsonDecode(raw) as Map).cast<String, Object?>(),
          ),
      ];
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
      for (final b in [...partners.map((x) => x.bond), ...pending])
        jsonEncode(b.toJson()),
    ]);
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

  Future<void> _saveChat(String code) async {
    final p = await SharedPreferences.getInstance();
    final list = chats[code] ?? [];
    final keep = list.length > 500 ? list.sublist(list.length - 500) : list;
    await p.setStringList('chat.$code', [
      for (final m in keep) jsonEncode(m.toJson()),
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
    'me': t.meaningEmoji,
    'bpm': t.heartbeatBPM,
    'fx': t.effect,
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
    meaningEmoji: j['me'] as String?,
    heartbeatBPM: (j['bpm'] as num?)?.toInt(),
    effect: j['fx'] as String?,
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
    for (final partner in partners) {
      unawaited(_sendProfile(partner.bond));
    }
  }

  Future<void> _sendProfile(Bond bond) async {
    try {
      await relay.sendProfile(
        bond,
        name: name.isEmpty ? 'Me' : name,
        colorRGB: colorRGB,
        photo: myPhoto,
      );
    } catch (_) {}
  }

  Future<void> setLocationSharing(bool on) async {
    sharingLocation = on;
    (await SharedPreferences.getInstance()).setBool('shareLocation', on);
    on
        ? await location.start(background: !inForeground)
        : await location.stop();
    notifyListeners();
    await publishPresence(force: true);
  }

  Future<void> setMoodSharing(bool on) async {
    shareMood = on;
    (await SharedPreferences.getInstance()).setBool('shareMood', on);
    notifyListeners();
    await publishPresence(force: true);
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
    await publishPresence(force: true);
  }

  void select(String id) {
    selectedID = id;
    SharedPreferences.getInstance().then((p) => p.setString('selected', id));
    notifyListeners();
  }

  // MARK: Bonds

  Future<String> createInvite() async {
    final bond = await relay.createBond(
      name: name.isEmpty ? 'Me' : name,
      myID: myID,
      colorRGB: colorRGB,
    );
    pending.add(bond);
    chats[bond.code] = [];
    await _saveBonds();
    notifyListeners();
    return Bond.inviteLink(bond.code);
  }

  Future<void> join(String codeOrLink) async {
    final code = Bond.codeFromLink(codeOrLink) ?? Bond.normalize(codeOrLink);
    if (partners.any((p) => p.id == code) ||
        pending.any((b) => b.code == code)) {
      return;
    }
    final bond = await relay.joinBond(
      code,
      name: name.isEmpty ? 'Me' : name,
      colorRGB: colorRGB,
    );
    _addPartner(bond);
    await _sendProfile(bond);
    await refreshAll();
  }

  void _addPartner(Bond bond) {
    final partner = Partner(bond);
    partners.add(partner);
    chats.putIfAbsent(bond.code, () => []);
    selectedID ??= bond.code;
    _saveBonds();
    _watch(bond);
    notifyListeners();
  }

  Future<void> removePartner(Bond bond) async {
    await relay.deleteBond(bond);
    partners.removeWhere((p) => p.id == bond.code);
    pending.removeWhere((b) => b.code == bond.code);
    await _watches.remove(bond.code)?.cancel();
    if (selectedID == bond.code) selectedID = partners.firstOrNull?.id;
    await _saveBonds();
    notifyListeners();
  }

  // MARK: Sync

  bool _refreshing = false;

  Future<void> refreshAll() async {
    if (!firebaseReady || _refreshing) return;
    _refreshing = true;
    try {
      // An invite we made: once their profile appears, they've joined.
      for (final b in [...pending]) {
        final joined = await relay.joinedPartnerName(b);
        if (joined != null) {
          pending.remove(b);
          b.pending = false;
          b.partnerName = joined;
          _addPartner(b);
          await _sendProfile(b);
        }
      }
      for (final partner in [...partners]) {
        try {
          await _sync(partner);
        } catch (_) {}
      }
      await publishPresence();
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _sync(Partner partner) async {
    final ev = await relay.fetchNewEvents(partner.bond);
    final prefs = await SharedPreferences.getInstance();
    var changed = false;
    if (ev.partnerName != null && ev.partnerName != partner.bond.partnerName) {
      partner.bond.partnerName = ev.partnerName!;
      await _saveBonds();
      changed = true;
    }
    if (ev.partnerColorRGB != null) {
      partner.colorRGB = ev.partnerColorRGB!;
      await prefs.setInt('pcolor.${partner.id}', partner.colorRGB);
      changed = true;
    }
    if (ev.partnerPhoto != null) {
      partner.photo = Uint8List.fromList(ev.partnerPhoto!);
      await prefs.setString(
        'pphoto.${partner.id}',
        base64Encode(partner.photo!),
      );
      changed = true;
    }
    if (ev.partnerPushToken != null) partner.pushToken = ev.partnerPushToken;
    if (ev.partnerSeenTouch != null) partner.seenTouch = ev.partnerSeenTouch!;
    if (ev.partnerSeenMessage != null) {
      partner.seenMessage = ev.partnerSeenMessage!;
    }
    if (ev.presence != null) {
      partner.presence = ev.presence!.mergedOver(partner.presence);
      await prefs.setString(
        'presence.${partner.id}',
        jsonEncode(partner.presence!.json),
      );
      changed = true;
    }
    if (ev.latestBPM != null) {
      partner.lastBPM = ev.latestBPM;
      partner.lastBPMAt = ev.latestBPMAt;
    }
    for (final raw in ev.touches) {
      final t = TouchMessage(
        id: raw['id'] as String,
        bondID: partner.id,
        senderID: '${partner.id}-${partner.bond.theirRole}',
        pattern: (raw['pattern'] as List)
            .cast<num>()
            .map((n) => n.toInt())
            .toList(),
        generation: (raw['generation'] as num?)?.toInt() ?? 2,
        colorRGB: (raw['colorRGB'] as num?)?.toInt() ?? partner.colorRGB,
        endColorRGB: (raw['endColorRGB'] as num?)?.toInt() ?? partner.colorRGB,
        sentAt: SwiftJson.parseDate(raw['sentAt']),
        meaningLabel: raw['meaningLabel'] as String?,
        meaningEmoji: raw['meaningEmoji'] as String?,
        heartbeatBPM: (raw['heartbeatBPM'] as num?)?.toInt(),
        effect: raw['effect'] as String?,
      );
      if (_historyIDs.add(t.id)) {
        history.add(t);
        await _deliver(t, partner);
        changed = true;
      }
    }
    if (ev.touches.isNotEmpty) await _saveHistory();
    if (ev.messages.isNotEmpty) {
      final list = chats.putIfAbsent(partner.id, () => []);
      for (final m in ev.messages) {
        final msg = ChatMessage(
          id: m['id'] as String,
          bondID: partner.id,
          senderID: partner.id,
          kind: m['kind'] as String? ?? 'text',
          text: m['text'] as String? ?? '',
          colorRGB: (m['colorRGB'] as num?)?.toInt() ?? partner.colorRGB,
          sentAt: SwiftJson.parseDate(m['sentAt']),
        );
        if (list.any((x) => x.id == msg.id)) continue;
        list.add(msg);
        if (!inForeground) {
          await notifier.show(
            msg.id.hashCode,
            partner.name,
            msg.kind == 'image' ? '📷 Photo' : msg.text,
            channel: 'messages',
          );
        }
      }
      await _saveChat(partner.id);
      changed = true;
    }
    if (changed) notifyListeners();
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
        t.isHeartbeat
            ? '💓 Heartbeat · ${t.heartbeatBPM} BPM'
            : (t.meaningLabel != null
                  ? '${t.meaningEmoji ?? ''} ${t.meaningLabel}'
                  : 'Sent you a touch'),
      );
    }
  }

  // MARK: Sending

  Future<void> sendTouch({
    required List<int> pattern,
    required int generation,
    int? color,
    int? endColor,
    String? meaningLabel,
    String? meaningEmoji,
    int? heartbeatBPM,
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
      colorRGB: color ?? colorRGB,
      endColorRGB: endColor ?? color ?? colorRGB,
      meaningLabel: meaningLabel,
      meaningEmoji: meaningEmoji,
      heartbeatBPM: heartbeatBPM,
    );
    history.add(t);
    _historyIDs.add(t.id);
    notifyListeners();
    await _saveHistory();
    await relay.sendTouch(
      partner.bond,
      SwiftJson.compact({
        'id': t.id,
        'sentAt': SwiftJson.date(t.sentAt),
        'pattern': t.pattern,
        'generation': t.generation,
        'colorRGB': t.colorRGB,
        'endColorRGB': t.endColorRGB,
        'meaningLabel': t.meaningLabel,
        'meaningEmoji': t.meaningEmoji,
        'heartbeatBPM': t.heartbeatBPM,
        'effect': t.effect,
      }),
    );
  }

  Future<void> sendChat(String text) async {
    final partner = selected;
    if (partner == null || text.trim().isEmpty) return;
    final msg = ChatMessage(
      bondID: partner.id,
      senderID: ChatMessage.me,
      text: text.trim(),
      colorRGB: colorRGB,
    );
    chats.putIfAbsent(partner.id, () => []).add(msg);
    notifyListeners();
    msg.ringSeq = await relay.sendChat(partner.bond, {
      'id': msg.id,
      'sentAt': SwiftJson.date(msg.sentAt),
      'kind': 'text',
      'text': msg.text,
      'colorRGB': msg.colorRGB,
    });
    await _saveChat(partner.id);
  }

  // MARK: Presence

  /// This phone's status for partners — the iPhone app's PresenceInfo. Throttled: every 15 s
  /// moving / 2 min still on screen, 30 s / 3 min in the background, unless forced.
  Future<void> publishPresence({bool force = false}) async {
    if (!firebaseReady || partners.isEmpty) return;
    final moving = (location.speed ?? 0) > 0.5;
    final interval = inForeground ? (moving ? 15 : 120) : (moving ? 30 : 180);
    if (!force &&
        DateTime.now().difference(_lastPresence).inSeconds < interval) {
      return;
    }
    _lastPresence = DateTime.now();
    await health.refresh();
    final info = <String, Object?>{'online': true};
    final fix = location.last;
    if (sharingLocation && fix != null) {
      info['lat'] = fix.latitude;
      info['lng'] = fix.longitude;
      info['locationAt'] = SwiftJson.date(fix.timestamp);
      info['speed'] = DateTime.now().difference(fix.timestamp).inSeconds < 60
          ? (location.speed ?? 0)
          : 0;
    } else if (!sharingLocation) {
      info['locationOff'] = true;
    }
    try {
      info['phoneBattery'] = (await _battery.batteryLevel) / 100;
      final state = await _battery.batteryState;
      info['phoneCharging'] =
          state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {}
    info['bracelet'] = bracelet.isReady;
    if (bracelet.batteryPercent != null) {
      info['braceletBattery'] = bracelet.batteryPercent;
    }
    final last = bracelet.isReady ? DateTime.now() : bracelet.lastConnectedAt;
    if (last != null) info['braceletLastConnected'] = SwiftJson.date(last);
    if (shareMood) {
      final mood = health.moodShare(logged: loggedMood);
      if (mood != null) info['mood'] = mood;
    } else {
      info['moodOff'] = true;
    }
    for (final p in partners) {
      try {
        await relay.sendPresence(p.bond, info);
      } catch (_) {}
    }
  }

  Future<void> prepareCrypto() async {
    for (final b in [...partners.map((p) => p.bond), ...pending]) {
      await BondCrypto.prepare(b.code);
    }
  }
}
