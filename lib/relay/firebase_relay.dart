import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/bond_crypto.dart';
import '../core/swift_json.dart';
import '../models/bond.dart';
import '../models/presence.dart';

/// Connects two phones through Firebase with ONE link, with the same record layout and the
/// same sealed payloads as the iPhone app's iCloud relay (CloudRelay.swift) — so an Android
/// and an iPhone partner read each other's records.
///
/// Firestore holds only opaque ids and ciphertext: collection `r`, one document per record,
/// named `<locator>-<suffix>`, with the sealed bytes in `p`, the writer's anonymous uid in `o`
/// (only the writer may change it) and a server time in `t`. Records are read by exact name;
/// the rules forbid listing, so nobody can enumerate them.
///
/// Records per bond (L = locator, R = A (inviter) or B; each phone writes only its own R):
///   L-bond     the inviter's name            L-R-pf   name, colour, push token, photo hash
///   L-R-ph     profile photo                 L-R-pr   presence (status snapshot)
///   L-R-hb     latest heartbeat              L-R-cur  newest touch / message numbers + Seen
///   `L-R-t-<n>`  touch ring (n = number % 50)  `L-R-m-<n>` chat ring
///   L-R-sx     the shared Us space           L-R-wb   the shared whiteboard
class FirebaseRelay {
  static const ringSize = 50;

  final _col = FirebaseFirestore.instance.collection('r');
  final _seenTags = <String, Object?>{};
  Future<void>? _sendTail;

  Future<String> signIn() async {
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser ?? (await auth.signInAnonymously()).user!;
    return user.uid;
  }

  Future<String> _name(String code, String suffix) async =>
      '${await BondCrypto.locator(code)}-$suffix';
  Future<String> _mine(Bond b, String what) =>
      _name(b.code, '${b.myRole}-$what');
  Future<String> _theirs(Bond b, String what) =>
      _name(b.code, '${b.theirRole}-$what');

  Future<void> _put(String name, Object? json, String code) async {
    final uid = await signIn();
    await _col.doc(name).set({
      'p': Blob(await BondCrypto.seal(json, code)),
      'o': uid,
      't': FieldValue.serverTimestamp(),
    });
  }

  /// Fetches records by name; missing ones are absent from the result.
  Future<Map<String, DocumentSnapshot<Map<String, dynamic>>>> _get(
    List<String> names,
  ) async {
    await signIn();
    final snaps = await Future.wait(names.map((n) => _col.doc(n).get()));
    return {
      for (final s in snaps)
        if (s.exists) s.id: s,
    };
  }

  Future<Map<String, Object?>?> _open(
    DocumentSnapshot<Map<String, dynamic>>? s,
    String code,
  ) async {
    final blob = s?.data()?['p'];
    if (blob is! Blob) return null;
    final v = await BondCrypto.open(blob.bytes, code);
    return v is Map ? v.cast<String, Object?>() : null;
  }

  /// True the first time a record's current version is seen.
  bool _isNew(DocumentSnapshot<Map<String, dynamic>> s) {
    final tag = s.data()?['t'];
    if (_seenTags[s.id] == tag) return false;
    _seenTags[s.id] = tag;
    return true;
  }

  // MARK: Create & join

  Future<Bond> createBond({
    required String name,
    required String myID,
    required int colorRGB,
    String? pushToken,
  }) async {
    final rnd = Random.secure();
    var code = Bond.newCode(rnd.nextInt);
    await BondCrypto.prepare(code);
    if ((await _get([await _name(code, 'bond')])).isNotEmpty) {
      code = Bond.newCode(rnd.nextInt);
    }
    final bond = Bond(
      code: code,
      partnerName: 'Pending…',
      isOwner: true,
      pending: true,
    );
    await _put(await _name(code, 'bond'), {
      'name': name,
      'ownerID': myID,
    }, code);
    await _put(
      await _mine(bond, 'pf'),
      SwiftJson.compact({
        'name': name,
        'colorRGB': colorRGB,
        'pushToken': pushToken,
      }),
      code,
    );
    await _announce('pf', bond);
    return bond;
  }

  Future<Bond> joinBond(
    String rawCode, {
    required String name,
    required int colorRGB,
    String? pushToken,
  }) async {
    final code = Bond.normalize(rawCode);
    await BondCrypto.prepare(code);
    final bondName = await _name(code, 'bond');
    final info = await _open((await _get([bondName]))[bondName], code);
    if (info == null) {
      throw const RelayException(
        'No bond with that code. Check it and try again.',
      );
    }
    final bond = Bond(
      code: code,
      partnerName: info['name'] as String? ?? 'Partner',
      isOwner: false,
    );
    await _put(
      await _mine(bond, 'pf'),
      SwiftJson.compact({
        'name': name,
        'colorRGB': colorRGB,
        'pushToken': pushToken,
      }),
      code,
    );
    await _announce('pf', bond);
    return bond;
  }

  /// The partner's name once they've joined an invite we created; null while pending.
  Future<String?> joinedPartnerName(Bond bond) async {
    final pf = await _theirs(bond, 'pf');
    return (await _open((await _get([pf]))[pf], bond.code))?['name'] as String?;
  }

  Future<void> deleteBond(Bond bond) async {
    final names = [
      for (final w in ['pf', 'ph', 'pr', 'hb', 'cur', 'sx', 'wb'])
        await _mine(bond, w),
      for (var i = 0; i < ringSize; i++) await _mine(bond, 't-$i'),
      for (var i = 0; i < ringSize; i++) await _mine(bond, 'm-$i'),
      if (bond.isOwner) await _name(bond.code, 'bond'),
    ];
    await Future.wait(
      names.map((n) => _col.doc(n).delete().catchError((_) {})),
    );
    final prefs = await SharedPreferences.getInstance();
    for (final k in ['Touch', 'Message']) {
      await prefs.remove(_seqKey(bond.code, k));
      await prefs.remove(_seenKey(bond.code, k));
    }
  }

  // MARK: Sending (sealed)

  /// Sends a touch payload (TouchPayload fields, without `seq`); returns its ring number.
  Future<int> sendTouch(Bond bond, Map<String, Object?> touch) =>
      _sendEvent(bond, 'Touch', (seq) => {...touch, 'seq': seq});

  Future<int> sendChat(Bond bond, Map<String, Object?> message) =>
      _sendEvent(bond, 'Message', (seq) => {...message, 'seq': seq});

  Future<void> sendHeartbeat(Bond bond, int bpm) async {
    await _put(await _mine(bond, 'hb'), {
      'bpm': bpm,
      'sentAt': SwiftJson.date(DateTime.now()),
    }, bond.code);
    await _announce('hb', bond);
  }

  Future<void> sendPresence(Bond bond, Map<String, Object?> presence) async {
    await _put(await _mine(bond, 'pr'), {
      ...presence,
      'sentAt': SwiftJson.date(DateTime.now()),
    }, bond.code);
    await _announce('pr', bond);
  }

  final _writtenPhotoHash = <String, String>{};

  Future<void> sendProfile(
    Bond bond, {
    required String name,
    required int colorRGB,
    String? pushToken,
    List<int>? photo,
    List<Object?>? meanings,
  }) async {
    String? photoHash;
    if (photo != null) {
      photoHash = hash.sha256
          .convert(photo)
          .bytes
          .take(8)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (_writtenPhotoHash[bond.code] != photoHash) {
        await _put(await _mine(bond, 'ph'), {
          'data': SwiftJson.data(photo),
        }, bond.code);
        _writtenPhotoHash[bond.code] = photoHash;
      }
    }
    await _put(
      await _mine(bond, 'pf'),
      SwiftJson.compact({
        'name': name,
        'colorRGB': colorRGB,
        'pushToken': pushToken,
        'photoHash': photoHash,
        'meanings': meanings,
      }),
      bond.code,
    );
    await _announce('pf', bond);
  }

  Future<void> sendSpace(Bond bond, Map<String, Object?> space) async {
    await _put(await _mine(bond, 'sx'), space, bond.code);
    await _announce('sx', bond);
  }

  Future<void> sendBoard(Bond bond, Map<String, Object?> board) async {
    await _put(await _mine(bond, 'wb'), board, bond.code);
    await _announce('wb', bond);
  }

  // MARK: Change counters

  /// Firestore's free plan allows 50 000 reads a day, so the partner polls only the cursor:
  /// it carries a counter per record (`rev`), bumped on every write, and the partner fetches a
  /// record only when its counter moved. Same scheme as the iPhone app.
  String _revKey(String code) => 'relay.rev.$code';

  Future<Map<String, int>> _revs(String code) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _revKey(code),
    );
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as num).toInt()),
    );
  }

  /// After writing record `what`: bumps its counter and rewrites the cursor.
  Future<void> _announce(String what, Bond bond) async {
    final r = await _revs(bond.code);
    r[what] = (r[what] ?? 0) + 1;
    await (await SharedPreferences.getInstance()).setString(
      _revKey(bond.code),
      jsonEncode(r),
    );
    await _loadCounters(bond);
    await _writeCursor(bond);
  }

  /// The partner's record counters already fetched (by record name), this launch.
  final _seenRevs = <String, int>{};

  // MARK: Rings

  String _seqKey(String code, String kind) => 'relay.seq.$kind.$code';
  String _seenKey(String code, String kind) => 'relay.seen.$kind.$code';

  /// One event after another, so an event is always written before the cursor announcing it.
  Future<int> _sendEvent(
    Bond bond,
    String kind,
    Map<String, Object?> Function(int seq) make,
  ) {
    final previous = _sendTail ?? Future.value();
    final task = previous.then((_) => _writeEvent(bond, kind, make));
    _sendTail = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<int> _writeEvent(
    Bond bond,
    String kind,
    Map<String, Object?> Function(int seq) make,
  ) async {
    final seq = await _nextSeq(bond, kind);
    final what = kind == 'Touch'
        ? 't-${seq % ringSize}'
        : 'm-${seq % ringSize}';
    await _put(await _mine(bond, what), make(seq), bond.code);
    await _writeCursor(bond);
    return seq;
  }

  Future<void> _writeCursor(Bond bond) async {
    final p = await SharedPreferences.getInstance();
    await _put(await _mine(bond, 'cur'), {
      'touch': p.getInt(_seqKey(bond.code, 'Touch')) ?? 0,
      'message': p.getInt(_seqKey(bond.code, 'Message')) ?? 0,
      'seenTouch': p.getInt(_seenKey(bond.code, 'Touch')) ?? 0,
      'seenMessage': p.getInt(_seenKey(bond.code, 'Message')) ?? 0,
      'rev': await _revs(bond.code),
    }, bond.code);
  }

  Future<int> _nextSeq(Bond bond, String kind) async {
    await _loadCounters(bond);
    final p = await SharedPreferences.getInstance();
    final next = (p.getInt(_seqKey(bond.code, kind)) ?? 0) + 1;
    await p.setInt(_seqKey(bond.code, kind), next);
    return next;
  }

  /// After a reinstall, continue numbering from the server so numbers are never reused.
  Future<void> _loadCounters(Bond bond) async {
    final p = await SharedPreferences.getInstance();
    final tk = _seqKey(bond.code, 'Touch'), mk = _seqKey(bond.code, 'Message');
    if (p.containsKey(tk) && p.containsKey(mk)) return;
    final cur = await _mine(bond, 'cur');
    final server = await _open((await _get([cur]))[cur], bond.code);
    if (!p.containsKey(tk)) {
      await p.setInt(tk, (server?['touch'] as num?)?.toInt() ?? 0);
    }
    if (!p.containsKey(mk)) {
      await p.setInt(mk, (server?['message'] as num?)?.toInt() ?? 0);
    }
  }

  Future<({int from, int to})?> _pending(
    String code,
    String kind,
    int newest,
  ) async {
    final p = await SharedPreferences.getInstance();
    final lastSeen = p.getInt(_seenKey(code, kind)) ?? 0;
    if (newest < lastSeen) {
      await p.setInt(_seenKey(code, kind), newest); // they restarted
    }
    if (newest <= lastSeen) return null;
    return (from: max(lastSeen + 1, newest - ringSize + 1), to: newest);
  }

  // MARK: Receiving

  /// Everything new from the partner: touches and chat from their rings, plus their heartbeat,
  /// presence, profile, Us space and whiteboard when those changed.
  Future<RelayEvents> fetchNewEvents(Bond bond) async {
    final code = bond.code;
    final ev = RelayEvents();
    final cur = await _theirs(bond, 'cur'),
        hb = await _theirs(bond, 'hb'),
        pr = await _theirs(bond, 'pr');
    final pf = await _theirs(bond, 'pf'),
        sx = await _theirs(bond, 'sx'),
        wb = await _theirs(bond, 'wb');
    // The cursor alone, then only the records whose counters moved. Without counters (no
    // cursor yet) read everything; with them, a record with no counter hasn't been written.
    final found = await _get([cur]);
    final rev = (await _open(found[cur], code))?['rev'] as Map?;
    final changed = [
      for (final e in {
        'hb': hb,
        'pr': pr,
        'pf': pf,
        'sx': sx,
        'wb': wb,
      }.entries)
        if (rev == null ||
            (rev[e.key] != null &&
                _seenRevs[e.value] != (rev[e.key] as num).toInt()))
          e,
    ];
    if (changed.isNotEmpty) {
      found.addAll(await _get([for (final e in changed) e.value]));
      for (final e in changed) {
        final n = rev?[e.key] as num?;
        if (n != null) _seenRevs[e.value] = n.toInt();
      }
    }

    if (found[sx] != null && _isNew(found[sx]!)) {
      ev.space = await _open(found[sx], code);
    }
    if (found[wb] != null && _isNew(found[wb]!)) {
      ev.board = await _open(found[wb], code);
    }
    if (found[hb] != null && _isNew(found[hb]!)) {
      final h = await _open(found[hb], code);
      if (h != null) {
        ev.latestBPM = (h['bpm'] as num?)?.toInt();
        ev.latestBPMAt = SwiftJson.parseDateOrNull(h['sentAt']);
      }
    }
    final presence = await _open(found[pr], code);
    if (presence != null) ev.presence = Presence(presence);
    if (found[pf] != null && _isNew(found[pf]!)) {
      final p = await _open(found[pf], code);
      if (p != null) {
        ev.partnerName = p['name'] as String?;
        ev.partnerColorRGB = (p['colorRGB'] as num?)?.toInt();
        ev.partnerPushToken = p['pushToken'] as String?;
        ev.partnerMeanings = p['meanings'] as List?;
        final hashValue = p['photoHash'] as String?;
        if (hashValue != null && hashValue != _seenPhotoHash[code]) {
          final ph = await _theirs(bond, 'ph');
          final photo = await _open((await _get([ph]))[ph], code);
          if (photo?['data'] != null) {
            ev.partnerPhoto = SwiftJson.parseData(photo!['data']);
            _seenPhotoHash[code] = hashValue;
          }
        }
      }
    }

    final cursor = await _open(found[cur], code) ?? const {};
    ev.partnerSeenTouch = (cursor['seenTouch'] as num?)?.toInt();
    ev.partnerSeenMessage = (cursor['seenMessage'] as num?)?.toInt();
    final touchRange = await _pending(
      code,
      'Touch',
      (cursor['touch'] as num?)?.toInt() ?? 0,
    );
    final messageRange = await _pending(
      code,
      'Message',
      (cursor['message'] as num?)?.toInt() ?? 0,
    );
    final touchSeqs = touchRange == null
        ? <int>[]
        : [for (var s = touchRange.from; s <= touchRange.to; s++) s];
    final messageSeqs = messageRange == null
        ? <int>[]
        : [for (var s = messageRange.from; s <= messageRange.to; s++) s];
    if (touchSeqs.isNotEmpty || messageSeqs.isNotEmpty) {
      final tNames = {
        for (final s in touchSeqs) s: await _theirs(bond, 't-${s % ringSize}'),
      };
      final mNames = {
        for (final s in messageSeqs)
          s: await _theirs(bond, 'm-${s % ringSize}'),
      };
      final records = await _get([...tNames.values, ...mNames.values]);
      for (final e in tNames.entries) {
        final t = await _open(records[e.value], code);
        // A slot holding a different number was overwritten (over 50 behind): skip it.
        if (t != null && (t['seq'] as num?)?.toInt() == e.key) {
          ev.touches.add(t);
        }
      }
      for (final e in mNames.entries) {
        final m = await _open(records[e.value], code);
        if (m != null && (m['seq'] as num?)?.toInt() == e.key) {
          ev.messages.add(m);
        }
      }
      final p = await SharedPreferences.getInstance();
      if (touchRange != null) {
        await p.setInt(_seenKey(code, 'Touch'), touchRange.to);
      }
      if (messageRange != null) {
        await p.setInt(_seenKey(code, 'Message'), messageRange.to);
      }
      // Tell the partner their touches and messages arrived (their Seen).
      await _loadCounters(bond);
      try {
        await _writeCursor(bond);
      } catch (_) {}
    }
    ev.touches.sort(
      (a, b) =>
          ((a['sentAt'] as num?) ?? 0).compareTo((b['sentAt'] as num?) ?? 0),
    );
    ev.messages.sort(
      (a, b) =>
          ((a['sentAt'] as num?) ?? 0).compareTo((b['sentAt'] as num?) ?? 0),
    );
    return ev;
  }

  final _seenPhotoHash = <String, String>{};

  /// Fires when the partner's cursor changes, i.e. anything of theirs (live while the app runs).
  Stream<void> watch(Bond bond) async* {
    await signIn();
    // The cursor announces every change (see `_announce`), so one listener is enough.
    final names = [await _theirs(bond, 'cur')];
    final controller = StreamController<void>();
    final subs = [
      for (final n in names)
        _col
            .doc(n)
            .snapshots()
            .listen((_) => controller.add(null), onError: (_) {}),
    ];
    controller.onCancel = () {
      for (final s in subs) {
        s.cancel();
      }
    };
    yield* controller.stream;
  }
}

class RelayEvents {
  final touches = <Map<String, Object?>>[];
  final messages = <Map<String, Object?>>[];
  int? latestBPM;
  DateTime? latestBPMAt;
  Presence? presence;
  String? partnerName;
  int? partnerColorRGB;
  List<int>? partnerPhoto;
  String? partnerPushToken;
  int? partnerSeenTouch;
  int? partnerSeenMessage;
  List<Object?>? partnerMeanings;
  Map<String, Object?>? space;
  Map<String, Object?>? board;
}

class RelayException implements Exception {
  const RelayException(this.message);
  final String message;
  @override
  String toString() => message;
}
