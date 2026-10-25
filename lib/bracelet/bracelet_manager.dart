// The Bond Touch bracelet central — a port of the iOS app's BraceletManager.swift on top of
// flutter_blue_plus. Scans by advertised name (BOND*, any case), connects, detects the
// bracelet generation (v1/v2/v3/v4/mini), runs the token/AUID pairing handshake,
// subscribes to the state + event channels, and sends touches and buzz/glow using the
// per-generation wire format in `BondGATT`. Writes are serialised.
//
// Not ported (by request): firmware recovery / DFU (update mode, update offers) and the
// Bond Heart pendant. iOS-only pieces have Android equivalents noted where they're used.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/touch_message.dart';
import 'bond_gatt.dart';

enum BraceletState {
  bluetoothOff,
  scanning,
  connecting,
  connected,
  disconnected,
}

/// A touch the user made on their own bracelet: the pattern, its generation (3 = Bond
/// Touch More position samples, 2 = on/off milliseconds), and — on a Bond Touch More /
/// Touch 4 — the bond of the partner slot it was made for (null = selected partner).
class LocalTouch {
  const LocalTouch(this.pattern, this.generation, this.bondID);
  final List<int> pattern;
  final int generation;
  final String? bondID;
}

/// A bracelet found stuck in firmware-update (DFU) mode (detection only; no updater here).
class DfuCandidate {
  const DfuCandidate(this.id, this.model);
  final String id;
  final BraceletModel model;
}

enum BraceletLogKind { send, ok, fail }

class BraceletManager extends ChangeNotifier {
  BraceletManager();

  /// Log sink (NetLog in the iOS app). Defaults to debugPrint.
  void Function(BraceletLogKind kind, String title, String detail) onLog =
      (kind, title, detail) => debugPrint(
        '[Bracelet ${kind.name}] $title${detail.isEmpty ? '' : ' — $detail'}',
      );

  void _log(BraceletLogKind k, String title, [String detail = '']) =>
      onLog(k, title, detail);

  // MARK: - Published state

  BraceletState _state = BraceletState.disconnected;
  BraceletState get state => _state;
  final StreamController<BraceletState> _stateCtl =
      StreamController<BraceletState>.broadcast();
  Stream<BraceletState> get stateStream => _stateCtl.stream;
  set _st(BraceletState v) {
    if (_state == v) return;
    _state = v;
    _stateCtl.add(v);
    notifyListeners();
  }

  /// Battery percentage (last known value): the standard battery service (2A19), or
  /// d3c0ff06 on v1 (from millivolts) and v2/v4/mini (byte 0).
  int? get batteryPercent => _batteryPercent;
  int? _batteryPercent;
  set _battery(int? v) {
    if (_batteryPercent == v) return;
    _batteryPercent = v;
    notifyListeners();
  }

  /// When the bracelet was last connected (now, while it is), kept across launches.
  DateTime? get lastConnectedAt => _lastConnectedAt;
  DateTime? _lastConnectedAt;
  set _lastConnected(DateTime? v) {
    _lastConnectedAt = v;
    if (v == null) {
      _prefs?.remove(_kLastConnected);
    } else {
      _prefs?.setInt(_kLastConnected, v.millisecondsSinceEpoch);
    }
    notifyListeners();
  }

  /// Which bracelet generation is connected (null: none yet).
  BondGeneration? get braceletGeneration => _gen;
  BondGeneration? _genValue;
  BondGeneration? get _gen => _genValue;
  set _gen(BondGeneration? v) {
    if (_genValue == v) return;
    _genValue = v;
    notifyListeners();
  }

  /// The touch generation the connected bracelet uses: 3 for a Bond Touch More (BTM), 2
  /// for every other model (as the original backend tags touches); null when none.
  int? get generation =>
      _gen == null ? null : (_gen == BondGeneration.v3 ? 3 : 2);

  /// True when the connected bracelet is third-generation (BTM).
  bool get isThirdGeneration => _gen == BondGeneration.v3;

  /// Connected and the handshake is done.
  bool get isReady => _state == BraceletState.connected && _gen != null;

  /// Device info: firmware (Bond Touch More from its 0xAC answer, v1 from d3c0ff03, others
  /// from 2A26), model number (2A24), charging ("full" counts as charging), and a Bond
  /// Touch More's battery-alert settings.
  String? firmwareVersion;
  String? modelNumber;
  bool? charging;
  BatteryAlertSettings? batteryAlert;

  /// The bracelet is in setup mode and waits for a double tap to pair with this phone.
  bool needsSetupTap = false;

  /// A bracelet seen advertising in update (DFU) mode. Never connected to as a bracelet.
  DfuCandidate? dfuDevice;

  bool heartbeatActive = false;

  // MARK: - Callbacks / streams

  /// Called with each touch the user draws on the bracelet (gen 3 = 50 ms samples, gen 2 =
  /// on/off ms), so the app can send it to the partner.
  void Function(List<int> pattern, int generation)? onTouchDrawn;

  /// As [onTouchDrawn], with the partner bond the touch was made for (Touch More / Touch 4).
  Stream<LocalTouch> get touches => _touchCtl.stream;
  final _touchCtl = StreamController<LocalTouch>.broadcast();

  /// A double tap on the bracelet — an action, not a touch.
  Stream<void> get doubleTaps => _doubleTapCtl.stream;
  final _doubleTapCtl = StreamController<void>.broadcast();

  /// The partner slot (1…3) the user picked on the bracelet itself.
  Stream<int> get slotSelections => _slotCtl.stream;
  final _slotCtl = StreamController<int>.broadcast();

  /// A touch handed to the bracelet didn't make it (a write failed, or the link dropped
  /// right after) — so it can be played on the phone instead.
  Stream<TouchMessage> get playFailures => _playFailedCtl.stream;
  final _playFailedCtl = StreamController<TouchMessage>.broadcast();

  void _emitLocalTap(List<int> pattern, int gen, String? bondID) {
    onTouchDrawn?.call(pattern, gen);
    _touchCtl.add(LocalTouch(pattern, gen, bondID));
  }

  // MARK: - Persisted settings (the original's UserBraceletData + SAVED_USER_INDEX)

  static const _kLastConnected = 'BondBraceletLastConnected';
  static const _kVibrationLevel = 'BondVibrationLevel';
  static const _kVibrationBalance = 'BondVibrationBalance';
  static const _kUserColor = 'BondUserColor';
  static const _kSelectedSlot = 'BondSelectedSlot';
  static const _kAuid = 'BondAUID';
  static const _kSavedID = 'BondBraceletID';

  SharedPreferences? _prefs;

  int? get _vibrationLevel {
    final v = _prefs?.getInt(_kVibrationLevel);
    return v != null && BondGATT.vibrationLevels.contains(v) ? v : null;
  }

  set _vibrationLevel(int? v) => v == null
      ? _prefs?.remove(_kVibrationLevel)
      : _prefs?.setInt(_kVibrationLevel, v);

  int get _vibrationBalance => _prefs?.getInt(_kVibrationBalance) ?? 2;
  set _vibrationBalance(int v) => _prefs?.setInt(_kVibrationBalance, v);

  int? get _userColor => _prefs?.getInt(_kUserColor);
  set _userColor(int? v) =>
      v == null ? _prefs?.remove(_kUserColor) : _prefs?.setInt(_kUserColor, v);

  int get _selectedSlot {
    final v = _prefs?.getInt(_kSelectedSlot);
    return v != null && v >= 1 && v <= 3 ? v : 1;
  }

  set _selectedSlot(int v) => _prefs?.setInt(_kSelectedSlot, v);

  /// The bracelet this phone pairs with (its remote id: the MAC address on Android).
  String? get _savedID => _prefs?.getString(_kSavedID);
  set _savedID(String? v) =>
      v == null ? _prefs?.remove(_kSavedID) : _prefs?.setString(_kSavedID, v);

  /// Persisted per-install AUID (device/user id) sent during pairing.
  int _auid = 1;

  // MARK: - Settings actions

  /// Vibration strength (28, 33, 40, 58, 60, 73, 80, 88 or 100) and left/right balance
  /// (0…4, 2 = centre). Bond Touch More: `[1,0x48,2,level,balance,3]`; v2/v4/mini: the
  /// motor-strength setting (no balance); classic v1 has no setting.
  void setVibration(int level, int balance) {
    if (!BondGATT.vibrationLevels.contains(level) ||
        balance < 0 ||
        balance > 4) {
      return;
    }
    _vibrationLevel = level;
    _vibrationBalance = balance;
    final gen = _gen;
    if (!_paired || gen == null) return;
    _enqueue(_vibrationWrites(gen, level, balance));
  }

  /// Plays a vibration once without saving it (Bond Touch More `[1,0x48,0,…]`, v2/v4/mini
  /// a 2 s motor-only frame).
  void previewVibration(int level, int balance) {
    final gen = _gen;
    if (!isReady ||
        gen == null ||
        !BondGATT.vibrationLevels.contains(level) ||
        balance < 0 ||
        balance > 4) {
      return;
    }
    switch (gen) {
      case BondGeneration.v3:
        _enqueue([BondGATT.v3VibrationPreview(level: level, balance: balance)]);
      case BondGeneration.v2 || BondGeneration.v4 || BondGeneration.mini:
        _enqueue([BondGATT.v2VibrationPreview(level)]);
      case BondGeneration.v1:
        break;
    }
  }

  /// The user's own colour: v2 touch + double-tap colour, v4/mini touch colour + own menu
  /// entry, v1 its colour config. (The original sends nothing to a Bond Touch More.)
  void setUserColor(int rgb) {
    _userColor = rgb & 0xFFFFFF;
    final gen = _gen;
    if (!_paired || gen == null) return;
    _enqueue(_userColorWrites(gen, rgb & 0xFFFFFF));
  }

  /// Lights the bracelet in a colour until [endColorPreview].
  void previewColor(int rgb) {
    final gen = _gen;
    if (!isReady || gen == null) return;
    switch (gen) {
      case BondGeneration.v3:
        _enqueue([BondGATT.v3Color(rgb & 0xFFFFFF)]);
      case BondGeneration.v2 || BondGeneration.v4 || BondGeneration.mini:
        _enqueue([BondGATT.v2HoldColor(rgb)]);
      case BondGeneration.v1:
        _enqueue([_v1.previewColor(rgb)]);
    }
  }

  void endColorPreview() {
    final gen = _gen;
    if (!isReady || gen == null) return;
    switch (gen) {
      case BondGeneration.v3:
        _enqueue([BondGATT.v3LedsOff]);
      case BondGeneration.v2 || BondGeneration.v4 || BondGeneration.mini:
        _enqueue([BondGATT.v2LedsOff]);
      case BondGeneration.v1:
        _enqueue([_v1.colorOff()]);
    }
  }

  /// Picks the partner slot (1…3) the bracelet sends to. Only the Bond Touch 4 takes it
  /// from the app (SELECTED_USER); it's remembered and re-sent after pairing.
  void selectPartnerSlot(int slot) {
    if (slot < 1 || slot > 3) return;
    _selectedSlot = slot;
    if (_gen != BondGeneration.v4 || !_paired) return;
    _v4Selected = slot;
    _enqueue(_v4SelectWrites(slot));
  }

  void _reportSlotSelected(int slot) {
    _selectedSlot = slot;
    _slotCtl.add(slot);
  }

  List<GattWrite> _vibrationWrites(BondGeneration gen, int level, int balance) {
    switch (gen) {
      case BondGeneration.v3:
        return [BondGATT.v3Vibration(level: level, balance: balance)];
      case BondGeneration.v2 || BondGeneration.v4 || BondGeneration.mini:
        return [BondGATT.v2MotorStrength(level)];
      case BondGeneration.v1:
        return [];
    }
  }

  List<GattWrite> _userColorWrites(BondGeneration gen, int rgb) {
    switch (gen) {
      case BondGeneration.v3:
        return [];
      case BondGeneration.v2 || BondGeneration.v4 || BondGeneration.mini:
        return BondGATT.v2UserColor(gen, rgb);
      case BondGeneration.v1:
        return _v1.userColor(rgb);
    }
  }

  V3Recording _v3Recording = V3Recording();
  bool _v3FeaturesSent = false;

  // Bond Touch More session state, reset on every connection.
  bool _v3FirmwareRead = false;
  int? _v3LastState;
  bool _slotsSynced = false;

  /// The partner slots the bracelet should show — one colour per partner, up to three —
  /// and which bond each slot is. Set by the app from the partner list.
  List<V3Slot> _desiredSlots = const [
    V3Slot.inactive,
    V3Slot.inactive,
    V3Slot.inactive,
  ];
  List<String> _slotBondIDs = [];

  /// Sets the bracelet's partner slots (colour per partner, up to 3, in order). Like the
  /// original app, a change is pushed to a paired Bond Touch More / Touch 4 right away.
  void setPartnerMenu(List<({String id, int rgb})> partners) {
    final top = partners.take(3).toList();
    _slotBondIDs = top.map((p) => p.id).toList();
    final slots = [
      for (final p in top) V3Slot(V3SlotState.active, p.rgb & 0xFFFFFF),
      for (var i = top.length; i < 3; i++) V3Slot.inactive,
    ];
    if (_slotsEqual(slots, _desiredSlots)) return;
    _desiredSlots = slots;
    if (_gen == BondGeneration.v3 && _v3FirmwareRead) {
      _syncPartnerSlots();
    } else if (_gen == BondGeneration.v4 && _paired) {
      _enqueue(_v4MenuWrites());
    }
  }

  static bool _slotsEqual(List<V3Slot> a, List<V3Slot> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // MARK: - Bond Touch 4 partner menu (BleBondManagerV4)

  /// The slot the v4 sends to, FIRST until told otherwise.
  int _v4Selected = 1;
  bool get _v4MenuEnabled =>
      _desiredSlots[1].state == V3SlotState.active ||
      _desiredSlots[2].state == V3SlotState.active;

  /// A(): the three menu entries — slot 1 shows only once there's a second or third
  /// partner — then the selected slot, capped to the last active one (T()).
  List<GattWrite> _v4MenuWrites() {
    GattWrite entry(int i, bool shown) {
      final s = _desiredSlots[i];
      return BondGATT.v2MenuEntry(
        slot: i + 1,
        rgb: shown && s.state == V3SlotState.active ? s.rgb : null,
      );
    }

    return [
      entry(0, _v4MenuEnabled),
      entry(1, true),
      entry(2, true),
      ..._v4SelectWrites(_v4MenuIndex()),
    ];
  }

  /// T(): the selected slot, no higher than the last active partner.
  int _v4MenuIndex() {
    final last = _desiredSlots[2].state == V3SlotState.active
        ? 3
        : _desiredSlots[1].state == V3SlotState.active
        ? 2
        : 1;
    return math.min(last, _v4Selected);
  }

  /// V(): SELECTED_USER, skipped while the menu isn't enabled.
  List<GattWrite> _v4SelectWrites(int slot) =>
      _v4MenuEnabled ? [BondGATT.v2SelectedUser(slot)] : [];

  String? _bondIDForSlot(int slot) =>
      slot >= 1 && slot <= _slotBondIDs.length ? _slotBondIDs[slot - 1] : null;

  // MARK: - Connection fields

  BluetoothDevice? _bracelet;
  final Map<String, BluetoothCharacteristic> _chars = {};
  final Set<String> _notifying = {};
  bool _hasV3Service = false;

  final List<GattWrite> _writeQueue = [];
  bool _writing = false;

  /// The write awaiting its response (to pause after a v2-base 0x32, as the original does).
  GattWrite? _inFlight;

  /// The original's command-queue pause: after a 0x32, while the bracelet records a message
  /// (v2-base 0x86, 15 s) or is busy (v1 247, 30 s). Lifted early by a CONNECTED state.
  DateTime? _queuePausedUntil;
  Timer? _queueResumeTimer;

  /// Bumped on every connection reset, so callbacks from an older link are ignored.
  int _session = 0;

  // Session state, reset on every connection. `_paired` is the original's "device paired"
  // (listener j()): the settings go out once per connection when it's reached.
  bool _paired = false;
  int _v2LastState = 0x00; // NO_STATE, as the original starts
  bool _v2FirmwareRead = false;

  /// A state read we asked for: its answer doesn't re-arm the check.
  bool _v2StateReadPending = false;
  Timer? _v2QueueCheck;
  List<int> _v2Touch = [];
  int _v2TouchSlot = 0;
  V1Commands _v1 = V1Commands();
  bool _v1Started = false;
  List<({int at, int count, int ms})> _v1Touches = [];
  static final Stopwatch _uptime = Stopwatch()..start();

  Timer? _heartbeatTimer;
  Timer? _heartbeatWatchdog;

  /// A Bond Touch More is glowing between heartbeat spikes.
  bool _heartbeatGlow = false;

  /// A connect can stall in discovery or the handshake — this fires if we haven't reached
  /// `connected` in time and recovers by cancelling and retrying.
  Timer? _connectWatchdog;
  int _connectAttempts = 0;

  /// True from the connected event until the disconnected event — the radio link is up
  /// (the handshake may still be running).
  bool _linkUp = false;
  DeviceIdentifier? _linkedId;

  /// Identifies the latest connect() we issued, so failures of superseded ones are ignored.
  int _connectAttempt = 0;

  /// A touch that arrived while the bracelet was (re)connecting; played once it's back if
  /// still fresh, instead of being dropped.
  ({TouchMessage touch, DateTime at})? _pendingPlay;

  /// When we started trying to reach the current bracelet.
  DateTime? _connectStartedAt;

  /// Set by [forget]: don't reconnect on our own until [scanAndConnect].
  bool _userPaused = false;

  /// The user asked to look for a bracelet ([scanAndConnect]); until one is connected,
  /// starting up again (e.g. Bluetooth turned on) scans for one.
  bool _discoverRequested = false;

  /// Scans are bounded (Android throttles and battery); this long each.
  static const _scanWindow = Duration(seconds: 30);

  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;
  bool get _poweredOn => _adapter == BluetoothAdapterState.on;
  final Map<String, DateTime> _seenAdverts = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _started = false;
  bool _powerAlertShown = false;

  /// Whether to ask the user to turn Bluetooth on at start (iOS's ShowPowerAlert).
  bool showPowerAlert = true;

  bool get _isForeground {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == null ||
          s == AppLifecycleState.resumed ||
          s == AppLifecycleState.inactive;
    } catch (_) {
      return true;
    }
  }

  static String _key(Guid g) => g.str128.toLowerCase();

  // MARK: - Start / public connection API

  /// Loads the settings, subscribes to the Bluetooth events and reconnects to the
  /// remembered bracelet, if any. Without one it waits for [scanAndConnect].
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final last = prefs.getInt(_kLastConnected);
    _lastConnectedAt = last == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(last);
    final existing = prefs.getInt(_kAuid) ?? 0;
    if (existing != 0) {
      _auid = existing;
    } else {
      _auid = math.Random.secure().nextInt(0x7FFFFFFF) + 1; // 1…Int32.max
      await prefs.setInt(_kAuid, _auid);
    }
    _subs.add(
      FlutterBluePlus.events.onConnectionStateChanged.listen(
        _onConnectionState,
      ),
    );
    _subs.add(FlutterBluePlus.events.onCharacteristicReceived.listen(_onValue));
    _subs.add(FlutterBluePlus.onScanResults.listen(_onScanResults));
    _subs.add(
      FlutterBluePlus.isScanning.listen((scanning) {
        if (!scanning && _state == BraceletState.scanning) {
          _st = BraceletState.disconnected;
        }
      }),
    );
    // Emits the current state first: the iOS centralManagerDidUpdateState.
    _subs.add(FlutterBluePlus.adapterState.listen(_onAdapterState));
    notifyListeners();
  }

  /// "Find my bracelet": forgets the remembered one, scans for BOND* and connects/pairs
  /// the first found; it's remembered once connected. (Swift's `reconnect()`.)
  Future<void> scanAndConnect() async {
    if (!_started) await start();
    _clearConnectWatchdog();
    _connectAttempts = 0;
    _discoverRequested = true;
    final old = _bracelet;
    _bracelet = null;
    _savedID = null;
    _linkUp = false;
    _linkedId = null;
    if (old != null) _cancel(old);
    _resetConnectionState();
    _st = BraceletState.disconnected;
    await _startScanning();
  }

  /// Disconnects and forgets the remembered bracelet; no auto-reconnect until
  /// [scanAndConnect]. (Swift's `disconnect()`.)
  Future<void> forget() async {
    _clearConnectWatchdog();
    _userPaused = true;
    _discoverRequested = false;
    _stopScan();
    final p = _bracelet;
    _bracelet = null; // so the disconnect doesn't reconnect it straight back
    _savedID = null;
    if (p != null) _cancel(p);
    _resetConnectionState();
    _st = BraceletState.disconnected;
  }

  /// Looks for the bracelet: one already connected to the system, else the remembered one
  /// by id (an Android autoConnect, completing whenever it's in range), else — only if the
  /// user asked ([scanAndConnect]) — a scan by name.
  Future<void> _startScanning() async {
    if (!_poweredOn) {
      _st = BraceletState.bluetoothOff;
      return;
    }
    _userPaused = false;

    // A bracelet already connected at the system level won't advertise; ask for it.
    // (Android returns all connected LE devices, so filter by name.)
    List<BluetoothDevice> known = [];
    try {
      known = (await FlutterBluePlus.systemDevices([
        Guid(BondGATT.serviceV3),
        Guid(BondGATT.serviceApp),
      ])).where((d) => BondGATT.isBondName(d.platformName)).toList();
    } catch (_) {}
    if (_linkUp || _state == BraceletState.connected) return;
    final saved = _savedID;
    if (known.isNotEmpty &&
        (saved == null || known.any((d) => d.remoteId.str == saved))) {
      final p = saved == null
          ? known.first
          : known.firstWhere((d) => d.remoteId.str == saved);
      _log(
        BraceletLogKind.send,
        'Bracelet: already connected to the phone — attaching',
      );
      _connect(p, autoConnect: false);
      return;
    }

    // Our own bracelet, by identifier: a pending (auto) connect completes the moment it's
    // in range, with no scan needed.
    if (saved != null) {
      _log(BraceletLogKind.send, 'Bracelet: reconnecting to saved bracelet');
      _connect(BluetoothDevice.fromId(saved), autoConnect: true);
      if (_isForeground) {
        _scanAll(); // also look fresh, in case it shows up under a new id
      }
      return;
    }

    if (!_discoverRequested) {
      _st = BraceletState.disconnected;
      return;
    }
    // The bracelet does not advertise its vendor service UUID — scan all, filter by name.
    _log(BraceletLogKind.send, 'Bracelet: scanning');
    _st = BraceletState.scanning;
    _scanAll();
  }

  void _scanAll() {
    if (FlutterBluePlus.isScanningNow || !_poweredOn) return;
    _seenAdverts.clear();
    FlutterBluePlus.startScan(timeout: _scanWindow).catchError((Object e) {
      _log(BraceletLogKind.fail, 'Bracelet: scan failed', '$e');
    });
  }

  void _stopScan() {
    if (!FlutterBluePlus.isScanningNow) return;
    FlutterBluePlus.stopScan().catchError((Object _) {});
  }

  void _connect(BluetoothDevice p, {required bool autoConnect}) {
    final old = _bracelet;
    if (old != null && old.remoteId != p.remoteId) _cancel(old);
    if (old?.remoteId != p.remoteId) _connectStartedAt = DateTime.now();
    _bracelet = p;
    _stopScan();
    _issueConnect(p, autoConnect: autoConnect);
    _enterConnecting();
  }

  /// `central.connect`: autoConnect = a pending connect that waits for the bracelet to be
  /// in range (Android's autoConnect, which requires mtu: null; the MTU is requested once
  /// connected). A direct connect is faster for a bracelet that's advertising right now.
  void _issueConnect(BluetoothDevice p, {required bool autoConnect}) {
    final attempt = ++_connectAttempt;
    p
        .connect(
          autoConnect: autoConnect,
          mtu: null,
          timeout: const Duration(seconds: 30),
        )
        .catchError((Object e) {
          if (attempt != _connectAttempt ||
              _bracelet?.remoteId != p.remoteId ||
              _linkUp) {
            return;
          }
          _didFailToConnect(p, e);
        });
  }

  /// `central.cancelPeripheralConnection`: cancels a pending connect or drops the link.
  void _cancel(BluetoothDevice p) {
    _connectAttempt++;
    p.disconnect(queue: false).catchError((Object _) {});
  }

  // MARK: - Connection watchdog

  /// Enters the connecting state and arms the watchdog.
  void _enterConnecting([Duration timeout = const Duration(seconds: 15)]) {
    _st = BraceletState.connecting;
    _connectWatchdog?.cancel();
    _connectWatchdog = Timer(timeout, _connectTimedOut);
  }

  /// Reached a fully usable connection — clears the watchdog and resets the attempt count.
  void _markConnected() {
    _clearConnectWatchdog();
    _connectAttempts = 0;
    final was = _state;
    _st = BraceletState.connected;
    _discoverRequested = false;
    _lastConnected = DateTime.now();
    final id = _bracelet?.remoteId.str;
    if (id != null) _savedID = id;
    if (was != BraceletState.connected) {
      _log(BraceletLogKind.ok, 'Bracelet connected', _gen?.name ?? '');
    }
    // A touch that came in while we were reconnecting: play it now if it's still fresh,
    // after a moment for the pairing handshake to settle.
    final pending = _pendingPlay;
    if (pending != null) {
      _pendingPlay = null;
      if (DateTime.now().difference(pending.at) <
          const Duration(seconds: 120)) {
        Timer(const Duration(seconds: 2), () => play(pending.touch));
      }
    }
  }

  void _clearConnectWatchdog() {
    _connectWatchdog?.cancel();
    _connectWatchdog = null;
  }

  void _connectTimedOut() {
    final p = _bracelet;
    if (_state != BraceletState.connecting || p == null) return;
    _connectAttempts += 1;
    // Never give up on the bracelet: keep a pending connect.
    if (!_poweredOn) {
      _enterConnecting(const Duration(seconds: 30));
      return;
    }
    if (_linkUp) {
      // The link is up but discovery / the handshake stalled: drop it. The disconnect
      // event re-issues the connect.
      _log(
        BraceletLogKind.fail,
        'Bracelet handshake stalled — reconnecting',
        'attempt $_connectAttempts',
      );
      _cancel(p);
    } else if (_isForeground) {
      // Foreground, possibly a half-open attempt: cancel it, let any fresh discovery take
      // over at once, and re-issue the connect after a beat.
      _log(
        BraceletLogKind.fail,
        'Bracelet not answering — retrying',
        'attempt $_connectAttempts',
      );
      _cancel(p);
      _resetConnectionState();
      _connectStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
      _scanAll();
      Timer(const Duration(milliseconds: 500), () {
        if (_bracelet?.remoteId != p.remoteId ||
            _linkUp ||
            _state == BraceletState.connected) {
          return;
        }
        _issueConnect(p, autoConnect: false);
      });
    } else {
      // Background, no link: make sure a pending connect really exists. A repeated
      // autoConnect on a device already connecting is a no-op in flutter_blue_plus.
      _issueConnect(p, autoConnect: true);
    }
    _enterConnecting(
      Duration(seconds: math.min(15 * (_connectAttempts + 1), 60)),
    );
  }

  // MARK: - Public actions

  /// Plays a received touch: replays the rhythm and glows/buzzes in its colour. Returns
  /// false if the bracelet isn't connected; then, with [holdIfOffline], the touch is held
  /// and played when it's back (if still fresh).
  Future<bool> play(TouchMessage touch, {bool holdIfOffline = true}) async {
    final gen = _gen;
    if (gen == null || _state != BraceletState.connected) {
      if (holdIfOffline) {
        _pendingPlay = (touch: touch, at: DateTime.now());
        _log(
          BraceletLogKind.fail,
          'Bracelet not connected — touch held until it reconnects',
        );
      }
      return false;
    }
    // Into the slot of the partner it is from, so it shows in their colour.
    final idx = _slotBondIDs.indexOf(touch.bondID);
    final slot = idx >= 0 ? idx + 1 : 1;
    if (gen == BondGeneration.v1) {
      _enqueue(
        _v1.touch(
          touch.onOffMs.isEmpty ? BondGATT.miniPattern : touch.onOffMs,
          touch.colorRGB,
        ),
      );
    } else if (touch.isRainbow && gen == BondGeneration.v3) {
      // A rainbow on the Bond Touch More: short pieces back to back, each its next hue.
      for (final piece in BondGATT.v3RainbowPieces(touch.samples, slot: slot)) {
        if (piece.at == 0) {
          _enqueue(piece.writes);
          continue;
        }
        Timer(Duration(microseconds: (piece.at * 1e6).round()), () {
          if (_gen == BondGeneration.v3) _enqueue(piece.writes);
        });
      }
    } else if (touch.isRainbow && gen != BondGeneration.mini) {
      _enqueue(
        BondGATT.v2RainbowSteps(
          onOff: touch.onOffMs,
          strength: (_vibrationLevel ?? 80).clamp(0, 255),
        ),
      );
      if (gen == BondGeneration.v4) _enqueue(_v4SelectWrites(slot));
    } else {
      // v2-base plays it at the user's vibration strength (80 when unset, as the original).
      _enqueue(
        BondGATT.touchSend(
          gen,
          touch,
          slot: slot,
          strength: _vibrationLevel ?? 80,
        ),
      );
      // The Bond Touch 4 then selects that partner, so a reply goes back to them (V4.g).
      if (gen == BondGeneration.v4) _enqueue(_v4SelectWrites(slot));
    }
    _lastPlayed = (touch: touch, at: DateTime.now());
    return true;
  }

  ({TouchMessage touch, DateTime at})? _lastPlayed;

  void _reportPlayFailed(String why) {
    final last = _lastPlayed;
    if (last == null ||
        DateTime.now().difference(last.at) >= const Duration(seconds: 5)) {
      return;
    }
    _lastPlayed = null;
    _log(BraceletLogKind.fail, "Touch didn't reach the bracelet", why);
    _playFailedCtl.add(last.touch);
  }

  /// Waits until every queued write has reached the bracelet (or [timeout] passes).
  Future<void> waitUntilIdle(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while ((_writing || _writeQueue.isNotEmpty) &&
        _bracelet != null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Plays a received heartbeat: one pulse per beat at [bpm] for [seconds] (5 s), then
  /// stops on its own.
  void playHeartbeat(int bpm, {double seconds = 5, int colorRGB = 0xE85D75}) {
    final clamped = bpm.clamp(30, 220);
    stopHeartbeat();
    heartbeatActive = true;
    notifyListeners();
    final interval = Duration(microseconds: (60.0 / clamped * 1e6).round());
    final total = Duration(microseconds: (seconds * 1e6).round());
    if (_gen == BondGeneration.v3) {
      // Bond Touch More: the band glows steadily between beats (light only, no motor);
      // each beat is a short spike up and down the bar, which is all that vibrates.
      _heartbeatGlow = true;
      void beat() {
        if (_gen != BondGeneration.v3) return;
        _enqueue(BondGATT.v3HeartbeatSpike(colorRGB));
        Timer(const Duration(milliseconds: 300), () {
          if (!_heartbeatGlow) return;
          _enqueue([BondGATT.v3Color(colorRGB)]);
        });
      }

      _enqueue([BondGATT.v3Color(colorRGB)]);
      beat();
      _heartbeatTimer = Timer.periodic(interval, (_) => beat());
      _heartbeatWatchdog = Timer(total, stopHeartbeat);
      return;
    }
    final gen = _gen;
    if (gen != null) _enqueue(_heartbeatPulse(gen, colorRGB));
    _heartbeatTimer = Timer.periodic(interval, (_) {
      final g = _gen;
      if (g == null) return;
      _enqueue(_heartbeatPulse(g, colorRGB));
    });
    _heartbeatWatchdog = Timer(total, stopHeartbeat);
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatWatchdog?.cancel();
    _heartbeatWatchdog = null;
    if (_heartbeatGlow) {
      _heartbeatGlow = false;
      if (_gen == BondGeneration.v3) {
        _enqueue([BondGATT.v3LedsOff]); // the glow goes out
      }
    }
    if (heartbeatActive) {
      heartbeatActive = false;
      notifyListeners();
    }
  }

  List<GattWrite> _heartbeatPulse(BondGeneration gen, int rgb) =>
      gen == BondGeneration.v1
      ? _v1.touch(const [130], rgb)
      : BondGATT.heartbeatPulse(gen, rgb);

  // MARK: - Light lab (debug)

  /// Writes raw frames in order. Each frame goes to [characteristic], by default the
  /// generation's command characteristic (FFB1 on a Bond Touch More, FFA6 otherwise).
  void send(List<List<int>> writes, {String? characteristic}) {
    final char =
        characteristic ??
        (_gen == BondGeneration.v3 ? BondGATT.ffb1 : BondGATT.charAppCmd);
    _enqueue([for (final w in writes) GattWrite(char, w)]);
  }

  /// Writes frames built by [BondGATT] in order.
  void sendWrites(List<GattWrite> writes) => _enqueue(writes);

  /// Bond Touch More, experimental: vibration level 0 so touch playback lights the bar
  /// without the motors, then the user's level back.
  bool get motorSilenced => _motorSilenced;
  bool _motorSilenced = false;
  void silenceMotor(bool on) {
    if (_gen != BondGeneration.v3) return;
    _motorSilenced = on;
    _enqueue([
      BondGATT.v3Vibration(
        level: on ? 0 : (_vibrationLevel ?? 80).clamp(0, 255),
        balance: _vibrationBalance.clamp(0, 255),
      ),
    ]);
  }

  /// Bond Touch More: samples played as a touch in [rgb] (several touches back to back when
  /// longer than one touch holds), into slot 1. Returns the seconds it takes.
  double playSamples(List<int> samples, int rgb) {
    if (_gen != BondGeneration.v3) return 0;
    const chunk = TouchPattern.maxSamples;
    var at = 0.0;
    for (var start = 0; start < samples.length; start += chunk) {
      final part = samples.sublist(
        start,
        math.min(samples.length, start + chunk),
      );
      final writes = BondGATT.v3Samples(part, rgb);
      if (at == 0) {
        _enqueue(writes);
      } else {
        Timer(
          Duration(microseconds: (at * 1e6).round()),
          () => _enqueue(writes),
        );
      }
      at += part.length * TouchPattern.sampleMs / 1000;
    }
    return at;
  }

  // MARK: - Write queue

  void _enqueue(List<GattWrite> writes) {
    _writeQueue.addAll(writes);
    _pump();
  }

  void _pump() {
    final p = _bracelet;
    if (_writing || p == null || _writeQueue.isEmpty) return;
    final until = _queuePausedUntil;
    if (until != null && until.isAfter(DateTime.now())) return;
    final w = _writeQueue.first;
    final c = _chars[w.char];
    if (c == null) {
      _writeQueue.removeAt(0);
      _pump();
      return;
    }
    final session = _session;
    _writing = true;
    _writeQueue.removeAt(0);
    if (c.properties.write) {
      _inFlight = w;
      final long = w.data.length > p.mtuNow - 3;
      c
          .write(w.data, withoutResponse: false, allowLongWrite: long)
          .then(
            (_) {
              if (session == _session) _didWriteValue(null);
            },
            onError: (Object e) {
              if (session == _session) _didWriteValue(e);
            },
          );
    } else {
      // Without response: the await stands in for canSendWriteWithoutResponse.
      c
          .write(w.data, withoutResponse: true)
          .then(
            (_) {
              if (session != _session) return;
              _writing = false;
              _didWrite(w);
              _pump();
            },
            onError: (Object e) {
              if (session != _session) return;
              _writing = false;
              _log(BraceletLogKind.fail, 'Bracelet: write failed', '$e');
              _pump();
            },
          );
    }
  }

  void _didWriteValue(Object? error) {
    _writing = false;
    final wrote = _inFlight;
    _inFlight = null;
    if (error != null) {
      _reportPlayFailed('$error');
    } else {
      if (wrote != null) _didWrite(wrote);
      if (_writeQueue.isEmpty) {
        _lastPlayed = null; // the touch fully reached the bracelet
      }
    }
    _pump();
  }

  /// The original pauses its queue 5 s once a v2-base 0x32 (end of a queued message) is
  /// written, until the bracelet reports CONNECTED again (BleBondManagerV2Base.b).
  void _didWrite(GattWrite w) {
    if (_gen?.usesV2Base == true &&
        w.char == BondGATT.charAppCmd &&
        w.data.isNotEmpty &&
        w.data.first == 0x32) {
      _pauseQueue(const Duration(seconds: 5));
    }
  }

  void _pauseQueue(Duration d) {
    _queuePausedUntil = DateTime.now().add(d);
    _queueResumeTimer?.cancel();
    _queueResumeTimer = Timer(d, _resumeQueue);
  }

  void _resumeQueue() {
    _queueResumeTimer?.cancel();
    _queueResumeTimer = null;
    _queuePausedUntil = null;
    _pump();
  }

  // MARK: - GATT helpers

  void _read(String key) {
    final c = _chars[key];
    if (c == null || !c.properties.read) return;
    c.read().catchError(
      (Object e) => <int>[],
    ); // the value arrives via _onValue
  }

  bool _canNotify(BluetoothCharacteristic c) =>
      c.properties.notify || c.properties.indicate;

  /// `setNotifyValue(true)` then `didUpdateNotificationStateFor`. On Android, if the
  /// encrypted ffa8 refuses (no bond yet), bond explicitly (the original's createBond())
  /// and try once more.
  Future<void> _setNotify(String key) async {
    final c = _chars[key];
    if (c == null) return;
    final session = _session;
    try {
      await c.setNotifyValue(true);
    } catch (e) {
      if (session != _session) return;
      if (key == BondGATT.charBondNotify && Platform.isAndroid) {
        try {
          await _bracelet?.createBond();
          if (session != _session) return;
          await c.setNotifyValue(true);
        } catch (e2) {
          _log(
            BraceletLogKind.fail,
            "Bracelet: couldn't enable notifications",
            '$e2',
          );
          return;
        }
      } else {
        _log(
          BraceletLogKind.fail,
          "Bracelet: couldn't enable notifications",
          '$e',
        );
        return;
      }
    }
    if (session != _session) return;
    _notifying.add(key);
    _didEnableNotifications(key);
  }

  static String _decodeString(List<int> data) {
    final s = utf8.decode(data, allowMalformed: true);
    var start = 0, end = s.length;
    bool trim(int c) => c == 0 || String.fromCharCode(c).trim().isEmpty;
    while (start < end && trim(s.codeUnitAt(start))) {
      start++;
    }
    while (end > start && trim(s.codeUnitAt(end - 1))) {
      end--;
    }
    return s.substring(start, end);
  }

  // MARK: - Handshake

  void _sendToken() {
    final gen = _gen;
    if (gen == null) return;
    _enqueue(BondGATT.tokenWrites(gen));
  }

  void _sendAuid() {
    final gen = _gen;
    if (gen == null) return;
    _enqueue(BondGATT.auidWrites(gen, _auid));
  }

  /// The original's "device paired" (listener j()): the bracelet is usable; then, once per
  /// connection, the user's colour (f()), vibration (B()), partner menu (A()) and saved
  /// slot (s()), in that order.
  void _devicePaired() {
    _markConnected();
    if (needsSetupTap) {
      needsSetupTap = false;
      notifyListeners();
    }
    final gen = _gen;
    if (_paired || gen == null) return;
    _paired = true;
    final rgb = _userColor;
    if (rgb != null) _enqueue(_userColorWrites(gen, rgb));
    final level = _vibrationLevel;
    if (level != null) {
      _enqueue(_vibrationWrites(gen, level, _vibrationBalance));
    }
    switch (gen) {
      case BondGeneration.v3:
        _syncPartnerSlots();
      case BondGeneration.v4:
        _enqueue(_v4MenuWrites());
        _v4Selected = _selectedSlot;
        _enqueue(_v4SelectWrites(_selectedSlot));
      default:
        break;
    }
    _read(BondGATT.modelChar);
  }

  void _setNeedsSetupTap() {
    needsSetupTap = true;
    notifyListeners();
  }

  // MARK: - v2 / v4 / mini session (the original app's BleBondManagerV2Base)

  /// As the original's constructor: read the battery (ff06) and enable notifications on
  /// it, the event channel (ffa5) and the state channel (ffa4); then a v2 sends the token
  /// right away and a v4/mini reads the state. The bracelet is usable only once its
  /// firmware (2A26) has been read after it reports CONNECTED.
  void _startV2Base() {
    final battery = _chars[BondGATT.charFF06];
    if (battery != null) {
      if (battery.properties.read) _read(BondGATT.charFF06);
      if (battery.properties.notify) _setNotify(BondGATT.charFF06);
    }
    for (final key in [BondGATT.charEvent, BondGATT.charState]) {
      if (_chars.containsKey(key)) _setNotify(key);
    }
    if (_gen == BondGeneration.v2) {
      _sendToken();
    } else {
      _readV2State();
    }
  }

  void _readV2State() {
    final s = _chars[BondGATT.charState];
    if (_bracelet == null || s == null || !s.properties.read) return;
    _v2StateReadPending = true;
    _read(BondGATT.charState);
  }

  void _handleV2Base(String key, List<int> data) {
    switch (key) {
      case BondGATT.charState:
        final wasRead = _v2StateReadPending;
        _v2StateReadPending = false;
        final s = V2State.parse(data);
        if (s != null) _handleV2State(s, notified: !wasRead);
      case BondGATT.charEvent:
        _handleV2Event(BondGATT.v2Event(data));
      case BondGATT.charFF06:
        if (data.length >= 2) _battery = math.min(data[0], 100);
      case BondGATT.firmwareChar:
        if (_v2FirmwareRead) return;
        _v2FirmwareRead = true;
        final fw = _decodeString(data);
        firmwareVersion = fw;
        _log(BraceletLogKind.ok, 'Bracelet paired', 'firmware $fw');
        _devicePaired();
        _v2AfterPairing();
      default:
        break;
    }
  }

  /// The original's onStateReadOrChanged (O()): charging, then each new bond state once.
  void _handleV2State(V2State s, {required bool notified}) {
    switch (s.charging) {
      case 0 || 0xFF:
        charging = false;
      case 1 || 2:
        charging = true;
      default:
        break;
    }
    const known = [0x00, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88];
    if (!known.contains(s.bond)) return;
    // QUEUE_EXECUTING notified: read the state again in 5 s to see whether it's still busy.
    if (notified && s.bond == 0x88) {
      _v2QueueCheck?.cancel();
      final session = _session;
      _v2QueueCheck = Timer(const Duration(seconds: 5), () {
        if (session == _session) _readV2State();
      });
    }
    if (s.bond == _v2LastState) return;
    _v2LastState = s.bond;
    if (_state != BraceletState.connected) {
      _enterConnecting(const Duration(seconds: 60)); // handshake in progress
    }
    switch (s.bond) {
      case 0x82:
        _log(BraceletLogKind.send, 'Bracelet: waiting for token — sending it');
        _sendToken();
      case 0x83:
        _log(BraceletLogKind.send, 'Bracelet: waiting for id — sending it');
        _sendAuid();
      case 0x84:
        _log(
          BraceletLogKind.fail,
          'Bracelet is in setup mode — double-tap it to pair',
        );
        _setNeedsSetupTap();
      case 0x85:
        // Connected, queue free: resume writes; the first time, read the firmware — that
        // answer is what makes the bracelet paired.
        _v2QueueCheck?.cancel();
        _v2QueueCheck = null;
        _resumeQueue();
        if (_v2FirmwareRead) return;
        final fw = _chars[BondGATT.firmwareChar];
        if (_bracelet != null && fw != null && fw.properties.read) {
          _read(BondGATT.firmwareChar);
        } else {
          // The original drops the connection here; we'd rather keep a usable bracelet.
          _log(
            BraceletLogKind.fail,
            'Bracelet: no firmware characteristic (2A26)',
          );
          _v2FirmwareRead = true;
          _devicePaired();
          _v2AfterPairing();
        }
      case 0x86:
        _pauseQueue(const Duration(seconds: 15)); // recording/playing a message
      default:
        break; // 0x00, 0x87 factory, 0x88 busy
    }
  }

  /// After the firmware read (S()) and the OS bond (D()). v2: the bonded settings, ANCS
  /// off. v4/mini: ANCS off, then subscribe to the encrypted ffa8 — that makes the phone
  /// bond, and once it's on the bonded settings go out.
  void _v2AfterPairing() {
    final gen = _gen;
    if (gen == null || !gen.usesV2Base) return;
    if (gen == BondGeneration.v2) {
      _enqueue(BondGATT.v2BondedSettings(gen));
      return;
    }
    _enqueue([BondGATT.v2Ancs(false)]);
    final bond = _chars[BondGATT.charBondNotify];
    if (_bracelet != null && bond != null && _canNotify(bond)) {
      _setNotify(BondGATT.charBondNotify);
    } else {
      _enqueue(BondGATT.v2BondedSettings(gen));
    }
  }

  void _handleV2Event(V2Event event) {
    switch (event) {
      case V2AuidError():
        _log(
          BraceletLogKind.fail,
          "Bracelet rejected this phone's id",
          'Double-tap the bracelet to pair it with this phone',
        );
      case V2PairedSignal():
        _log(BraceletLogKind.send, 'Bracelet: paired signal — confirming');
        _enqueue([BondGATT.v2PairedReply]);
      case V2Segment() || V2Timeout():
        _v2TouchReceived(event);
      case V2Tap():
        break; // the original only logs a single tap
      case V2DoubleTap():
        _doubleTapCtl.add(null);
      case V2Ignored():
        break;
    }
  }

  /// P(): v2/v4 assemble the on/off pattern from the segments (each ≥ 50 ms); the mini
  /// reports its fixed pattern for every touch event.
  void _v2TouchReceived(V2Event event) {
    if (_gen == BondGeneration.mini) {
      _emitLocalTap(BondGATT.miniPattern, 2, null);
      return;
    }
    switch (event) {
      case V2Segment(
        :final touchMs,
        :final releaseMs,
        :final counter,
        :final stop,
        :final slot,
      ):
        final on = math.max(touchMs, 50);
        if (counter == 1) {
          _v2Touch = [on];
          _v2TouchSlot = slot;
        } else {
          _v2Touch = [..._v2Touch, math.max(releaseMs, 50), on];
        }
        if (stop) _v2TouchEnded();
      case V2Timeout(:final counter, :final slot):
        if (counter == 0) {
          _v2Touch = [];
          _v2TouchSlot = slot;
        }
        _v2TouchEnded();
      default:
        break;
    }
  }

  /// T() / U(): deliver the touch. A v4 touch is for the slot it was recorded in; if that
  /// isn't the selected one, the bracelet switched partner.
  void _v2TouchEnded() {
    final pattern = _v2Touch;
    _v2Touch = [];
    if (_gen != BondGeneration.v4) {
      if (pattern.isNotEmpty) _emitLocalTap(pattern, 2, null);
      return;
    }
    final slot = (_v2TouchSlot >= 1 && _v2TouchSlot <= 3) ? _v2TouchSlot : 1;
    _v2TouchSlot = 0;
    if (_v4MenuIndex() != slot) _reportSlotSelected(slot);
    _v4Selected = slot;
    if (pattern.isNotEmpty) _emitLocalTap(pattern, 2, _bondIDForSlot(slot));
  }

  // MARK: - Classic v1 session (the original app's BleBondManagerV1)

  /// As the original: read the firmware (ff03), follow the battery (ff06); once the
  /// firmware is known, enable the event, state and command-result channels and send the
  /// token. The bracelet then asks for the AUID (244) and reports connected (246).
  void _startV1() {
    final battery = _chars[BondGATT.charFF06];
    if (battery != null) {
      if (battery.properties.notify) _setNotify(BondGATT.charFF06);
      if (battery.properties.read) _read(BondGATT.charFF06);
    }
    final fw = _chars[BondGATT.v1Firmware];
    if (fw != null && fw.properties.read) {
      _read(BondGATT.v1Firmware);
    } else {
      _beginV1Handshake();
    }
  }

  void _beginV1Handshake() {
    if (_v1Started || _bracelet == null) return;
    _v1Started = true;
    for (final key in [
      BondGATT.charEvent,
      BondGATT.charState,
      BondGATT.v1Ack,
    ]) {
      if (_chars.containsKey(key)) _setNotify(key);
    }
    _sendToken();
  }

  void _handleV1(String key, List<int> data) {
    switch (key) {
      case BondGATT.v1Firmware:
        if (data.length < 2) return;
        firmwareVersion = '1.${data[1]}.${data[0]}';
        notifyListeners();
        _beginV1Handshake();
      case BondGATT.charFF06:
        final pct = BondGATT.v1BatteryPercent(data);
        if (pct != null) _battery = pct;
      case BondGATT.charState:
        final s = V1State.parse(data);
        if (s == null) return;
        if (s.charging == 0) {
          charging = false;
        } else if (s.charging == 1) {
          charging = true;
        }
        if (_state != BraceletState.connected) {
          _enterConnecting(const Duration(seconds: 60));
        }
        switch (s.paired) {
          case 244:
            _log(BraceletLogKind.send, 'Bracelet: waiting for id — sending it');
            _sendAuid();
          case 246:
            _resumeQueue();
            if (!_paired) {
              _log(
                BraceletLogKind.ok,
                'Bracelet paired',
                firmwareVersion == null ? '' : 'firmware $firmwareVersion',
              );
            }
            _devicePaired();
          case 247:
            _pauseQueue(const Duration(seconds: 30));
            _doubleTapCtl.add(null); // as the original (listener l())
          default:
            break;
        }
      case BondGATT.charEvent:
        final e = V1Event.parse(data);
        if (e == null) return;
        switch (e.id) {
          case 18:
            _log(
              BraceletLogKind.fail,
              "Bracelet rejected this phone's id",
              'Double-tap the bracelet to pair it with this phone',
            );
          case 19:
            _enqueue([BondGATT.v1PairedReply]);
          case 20:
            _v1TouchEvent(e);
          default:
            break;
        }
      case BondGATT.v1Ack:
        if (data.length >= 2 && (data[0] | data[1] << 8) != 1) {
          _log(
            BraceletLogKind.fail,
            'Bracelet: command not accepted',
            'result ${data[0] | data[1] << 8}',
          );
        }
      default:
        break;
    }
  }

  /// BleTouchMessages: each segment arrives as it ends, with its press time; gaps come from
  /// the arrival times. Count 1 starts a touch, 0xFFFE (timeout) / 0xFFFF end it. Times are
  /// rounded to 50 ms.
  void _v1TouchEvent(V1Event e) {
    final now = _uptime.elapsedMilliseconds;
    switch (e.count) {
      case 1:
        _v1Touches = [(at: now, count: e.count, ms: e.touchMs)];
      case 0xFFFE || 0xFFFF:
        int round50(int x) => (x / 50 + 0.5).floor() * 50;
        final pattern = <int>[];
        for (var i = 0; i < _v1Touches.length; i++) {
          final m = _v1Touches[i];
          pattern.add(round50(m.ms));
          if (i < _v1Touches.length - 1) {
            final next = _v1Touches[i + 1];
            final gap = next.at - next.ms - m.at;
            pattern.add(round50(gap < 0 ? 100 : gap));
          }
        }
        _v1Touches = [];
        if (pattern.isNotEmpty) _emitLocalTap(pattern, 2, null);
      default:
        _v1Touches.add((at: now, count: e.count, ms: e.touchMs));
    }
  }

  // MARK: - Bond Touch More session (the original app's BleBondManagerV3, step for step)

  /// Every FFB1 notification from a Bond Touch More: system states, bond events, the
  /// firmware answer and command acks.
  void _handleV3(List<int> b) {
    if (b.isEmpty) return;
    final kind = b[0];
    if (kind == 0x04 && b.length >= 2) {
      // system state
      final s = b[1];
      if (s == _v3LastState) return; // the original ignores repeats
      _v3LastState = s;
      if (_state != BraceletState.connected) {
        _enterConnecting(const Duration(seconds: 60)); // handshake in progress
      }
      switch (s) {
        case 130:
          _log(
            BraceletLogKind.send,
            'Bracelet: waiting for token — sending it',
          );
          _sendToken();
        case 131:
          _log(BraceletLogKind.send, 'Bracelet: waiting for id — sending it');
          _sendAuid();
        case 132:
          _log(
            BraceletLogKind.fail,
            'Bracelet is in setup mode',
            'Double-tap the bracelet to pair it with this phone',
          );
          _setNeedsSetupTap();
        case 133:
          _log(BraceletLogKind.ok, 'Bracelet: handshake complete');
          if (!_v3FirmwareRead && !_v3FeaturesSent) {
            _v3FeaturesSent = true;
            _enqueue(BondGATT.v3ConnectedWrites);
          }
          _enableV3TouchNotifications();
          _markConnected();
        case 138:
          _log(BraceletLogKind.send, 'Bracelet: confirming pairing');
          _enqueue([BondGATT.v3PairedConfirm]);
        default:
          break;
      }
    } else if (kind == 0x02 && b.length >= 2) {
      // bond events
      switch (b[1]) {
        case 19: // APP_EVENT_PAIRED_SIGNAL
          _log(BraceletLogKind.send, 'Bracelet: paired signal — confirming');
          _enqueue([BondGATT.v3PairedConfirm]);
        case 178: // EVENT_NO_ACTION_DOUBLE_TAP_DETECTED
          _doubleTapCtl.add(null);
        case 180
            when b.length >= 3 &&
                b[2] >= 1 &&
                b[2] <= 3: // EVENT_USER_SELECTED [index]
          _reportSlotSelected(b[2]);
        default:
          break;
      }
    } else if (kind == 0xAC && b.length >= 4) {
      // firmware [minor, major, generation]
      if (_v3FirmwareRead) return;
      _v3FirmwareRead = true;
      firmwareVersion = '${b[3]}.${b[2]}.${b[1]}';
      _log(
        BraceletLogKind.ok,
        'Bracelet paired',
        'firmware ${b[3]}.${b[2]}.${b[1]}',
      );
      _enableV3TouchNotifications();
      final battery = _chars[BondGATT.batteryLevel];
      if (_bracelet != null && battery != null) {
        if (battery.properties.read) _read(BondGATT.batteryLevel);
        if (battery.properties.notify) _setNotify(BondGATT.batteryLevel);
      }
      _devicePaired(); // then the settings, as the original
    } else if (kind == 0x0A && b.length >= 2) {
      // command acks
      switch (b[1]) {
        case 0x45:
          final current = BondGATT.v3UserColors(b);
          if (current != null) _reconcileSlots(current);
        case 0x48 when b.length >= 4:
          // As the original: if the bracelet's vibration isn't the user's, send it again.
          final level = _vibrationLevel;
          if (!_motorSilenced &&
              level != null &&
              (b[2] != level || b[3] != _vibrationBalance)) {
            _enqueue([
              BondGATT.v3Vibration(level: level, balance: _vibrationBalance),
            ]);
          }
        case 0x49:
          final alert = BatteryAlertSettings.fromV3Ack(b);
          if (alert != null) {
            batteryAlert = alert;
            notifyListeners();
          }
        default:
          break;
      }
    }
  }

  /// FFB2 carries touches made on the bar; the original enables it once paired.
  void _enableV3TouchNotifications() {
    final ffb2 = _chars[BondGATT.ffb2];
    if (_bracelet == null ||
        ffb2 == null ||
        !ffb2.properties.notify ||
        _notifying.contains(BondGATT.ffb2)) {
      return;
    }
    _notifying.add(
      BondGATT.ffb2,
    ); // don't ask twice while the first is in flight
    _setNotify(BondGATT.ffb2);
  }

  /// As the original: ask the bracelet for its partner slots; the ack is answered with a
  /// write of only the slots that differ. If no ack comes, write them outright.
  void _syncPartnerSlots() {
    _slotsSynced = false;
    _enqueue([BondGATT.v3ReadUserColors]);
    final session = _session;
    Timer(const Duration(milliseconds: 2500), () {
      if (session != _session ||
          _gen != BondGeneration.v3 ||
          !_linkUp ||
          _slotsSynced) {
        return;
      }
      _slotsSynced = true;
      _enqueue([BondGATT.v3WriteUserColors(_desiredSlots)]);
      _log(BraceletLogKind.send, 'Bracelet: partner colours written');
    });
  }

  void _reconcileSlots(List<V3Slot> current) {
    _slotsSynced = true;
    final out = <V3Slot>[];
    var changed = false;
    for (var i = 0; i < _desiredSlots.length; i++) {
      final want = _desiredSlots[i];
      if (i < current.length && current[i] == want) {
        out.add(V3Slot(V3SlotState.ignore, want.rgb)); // leave as is
      } else {
        out.add(want);
        changed = true;
      }
    }
    if (!changed) return;
    _enqueue([BondGATT.v3WriteUserColors(out)]);
    _log(BraceletLogKind.send, 'Bracelet: partner colours updated');
  }

  // MARK: - Adapter / scan / connection events (the CBCentralManagerDelegate)

  void _onAdapterState(BluetoothAdapterState s) {
    _adapter = s;
    switch (s) {
      case BluetoothAdapterState.on:
        if (_userPaused) return;
        final p = _bracelet;
        if (p != null && !_linkUp && !p.isConnected) {
          // A bracelet we were reaching before Bluetooth went off: connects only work
          // once powered on, so (re)issue it now.
          _issueConnect(p, autoConnect: true);
          _enterConnecting();
          if (_isForeground) _scanAll();
        } else if (_state == BraceletState.disconnected ||
            _state == BraceletState.bluetoothOff) {
          _startScanning();
        }
      case BluetoothAdapterState.off || BluetoothAdapterState.turningOff:
        _st = BraceletState.bluetoothOff;
        if (s == BluetoothAdapterState.off &&
            showPowerAlert &&
            !_powerAlertShown &&
            Platform.isAndroid) {
          // iOS's CBCentralManagerOptionShowPowerAlertKey: ask once to turn it on.
          _powerAlertShown = true;
          FlutterBluePlus.turnOn().catchError((Object _) {});
        }
      case BluetoothAdapterState.unknown || BluetoothAdapterState.turningOn:
        break; // transient; the next state decides
      default:
        _st = BraceletState.disconnected; // unauthorized / unavailable
    }
  }

  void _onScanResults(List<ScanResult> results) {
    for (final r in results) {
      final id = r.device.remoteId.str;
      final prev = _seenAdverts[id];
      if (prev != null && !r.timeStamp.isAfter(prev)) continue;
      _seenAdverts[id] = r.timeStamp;
      _didDiscover(r);
    }
  }

  void _didDiscover(ScanResult r) {
    final peripheral = r.device;
    final adv = r.advertisementData.advName;
    final advName = adv.isNotEmpty
        ? adv
        : (peripheral.platformName.isNotEmpty ? peripheral.platformName : null);
    // A bracelet stuck in update mode: never connect to it as a bracelet.
    final model = BondGATT.dfuModel(advName);
    if (model != null) {
      if (dfuDevice?.id != peripheral.remoteId.str) {
        dfuDevice = DfuCandidate(peripheral.remoteId.str, model);
        notifyListeners();
      }
      return;
    }
    if (!BondGATT.isBondName(advName) || _userPaused) return;
    final current = _bracelet;
    // Already connecting to this one (e.g. the pending connect to our saved bracelet).
    if (current?.remoteId == peripheral.remoteId &&
        (_state == BraceletState.connecting ||
            _state == BraceletState.connected)) {
      return;
    }
    if (current != null && current.remoteId != peripheral.remoteId) {
      // Prefer the bracelet we're already reaching — but if it hasn't answered in 10 s
      // (e.g. it was reset and shows up under a new id), take this one. A partner's
      // bracelet connected to their phone doesn't advertise, so this won't grab theirs.
      if (_state == BraceletState.connected) return;
      final started = _connectStartedAt;
      if (started != null &&
          DateTime.now().difference(started) < const Duration(seconds: 10)) {
        return;
      }
      _log(
        BraceletLogKind.send,
        "Bracelet: saved one isn't answering — switching to ${advName ?? 'bracelet'}",
      );
    }
    _connect(peripheral, autoConnect: false);
  }

  void _onConnectionState(OnConnectionStateChangedEvent e) {
    final id = e.device.remoteId;
    if (e.connectionState == BluetoothConnectionState.connected) {
      final p = _bracelet;
      if (p == null || p.remoteId != id) {
        // A link we no longer want (cancelled, or replaced): drop it.
        if (_linkedId != id) {
          e.device.disconnect(queue: false).catchError((Object _) {});
        }
        return;
      }
      if (_linkUp && _linkedId == id) return;
      _didConnect(p);
    } else if (e.connectionState == BluetoothConnectionState.disconnected) {
      if (!_linkUp || _linkedId != id) {
        return; // a failed attempt is handled by connect()
      }
      _didDisconnect(e.device);
    }
  }

  void _didConnect(BluetoothDevice p) {
    _linkUp = true;
    _linkedId = p.remoteId;
    _stopScan();
    _resetConnectionState();
    // A fresh window for discovery + the pairing handshake — long enough for an Android
    // pairing request to be answered. Each state the bracelet reports extends it.
    _enterConnecting(const Duration(seconds: 30));
    final session = _session;
    () async {
      // iOS negotiates a large MTU by itself; Android starts at 23, which only fits 20-byte
      // frames (the batched 0x88 writes need more).
      if (Platform.isAndroid) {
        try {
          await p.requestMtu(512);
        } catch (_) {}
      }
      if (session != _session) return;
      List<BluetoothService> services;
      try {
        services = await p.discoverServices();
      } catch (e) {
        _log(
          BraceletLogKind.fail,
          "Bracelet: couldn't discover services",
          '$e',
        );
        return; // the watchdog recovers
      }
      if (session != _session || !_linkUp) return;
      _didDiscoverServices(services);
    }();
  }

  void _didDiscoverServices(List<BluetoothService> services) {
    _hasV3Service = services.any((s) => _key(s.uuid) == BondGATT.serviceV3);
    var hasBatteryService = false;
    for (final service in services) {
      if (_key(service.uuid) == BondGATT.batteryService) {
        hasBatteryService = true;
      }
      for (final c in service.characteristics) {
        _chars[_key(c.uuid)] = c;
      }
    }

    // Battery level (standard battery service): read it now and follow changes. (A Bond
    // Touch More's battery is read once it's paired, as the original app does.)
    final battery = _chars[BondGATT.batteryLevel];
    if (!_hasV3Service && hasBatteryService && battery != null) {
      if (battery.properties.read) _read(BondGATT.batteryLevel);
      if (battery.properties.notify) _setNotify(BondGATT.batteryLevel);
    }

    if (_hasV3Service) {
      // Bond Touch More, as the original app: enable FFB1 notifications; once they're on
      // ask for the firmware version, and answer the bracelet's state notifications.
      // FFB2 is enabled once it's paired.
      if (_gen == null && _chars.containsKey(BondGATT.ffb1)) {
        _gen = BondGeneration.v3;
        _setNotify(BondGATT.ffb1);
      }
    } else if (_gen == null) {
      // Non-v3: read the API-version byte to pick the generation.
      final api = _chars[BondGATT.charApiVer];
      if (api != null && api.properties.read) {
        _read(BondGATT.charApiVer);
      } else if (_chars.containsKey(BondGATT.charEvent)) {
        // App service present but no readable version char — default to the v2 base.
        _gen = BondGeneration.v2;
        _startSession();
      }
    }
  }

  void _didFailToConnect(BluetoothDevice p, Object error) {
    _linkUp = false;
    _resetConnectionState();
    _log(BraceletLogKind.fail, 'Bracelet connect failed — retrying', '$error');
    if (!_poweredOn) {
      _st = BraceletState.bluetoothOff; // reissued when Bluetooth is back on
      return;
    }
    if (_bracelet?.remoteId != p.remoteId) {
      _st = BraceletState.disconnected;
      _startScanning();
      return;
    }
    // Keep a pending connect alive; a short pause so an instant failure can't spin the radio.
    _st = BraceletState.connecting;
    Timer(const Duration(seconds: 1), () {
      if (_bracelet?.remoteId != p.remoteId || _linkUp) return;
      _issueConnect(p, autoConnect: true);
      _enterConnecting();
    });
  }

  void _didDisconnect(BluetoothDevice p) {
    if (_state == BraceletState.connected) _lastConnected = DateTime.now();
    _linkUp = false;
    _linkedId = null;
    _st = BraceletState.disconnected;
    _resetConnectionState();
    _reportPlayFailed('bracelet disconnected');
    final reason = p.disconnectReason;
    if (reason != null && (reason.code ?? 0) != 0) {
      _log(
        BraceletLogKind.fail,
        'Bracelet disconnected — reconnecting',
        reason.description ?? '${reason.code}',
      );
    }
    if (!_poweredOn) {
      _st = BraceletState.bluetoothOff; // the adapter-on handler reconnects
      return;
    }
    // Reconnect automatically (also in the background): a pending connect completes
    // whenever the bracelet comes back in range.
    if (_bracelet?.remoteId == p.remoteId) {
      _issueConnect(p, autoConnect: true);
      _enterConnecting();
    }
    // In the foreground, also scan so a bracelet that rebooted under a new id is noticed.
    if (_isForeground && !_userPaused) _scanAll();
  }

  void _resetConnectionState() {
    _session++;
    _gen = null;
    _v3FeaturesSent = false;
    _v3FirmwareRead = false;
    _v3LastState = null;
    _slotsSynced = false;
    _v3Recording = V3Recording();
    _chars.clear();
    _notifying.clear();
    _hasV3Service = false;
    _writeQueue.clear();
    _writing = false;
    _inFlight = null;
    _queueResumeTimer?.cancel();
    _queueResumeTimer = null;
    _queuePausedUntil = null;
    _paired = false;
    _v2LastState = 0x00;
    _v2FirmwareRead = false;
    _v2StateReadPending = false;
    _v2QueueCheck?.cancel();
    _v2QueueCheck = null;
    _v2Touch = [];
    _v2TouchSlot = 0;
    _v4Selected = 1;
    _v1 = V1Commands();
    _v1Started = false;
    _v1Touches = [];
  }

  /// The generation is known: start its session as the original's manager does.
  void _startSession() {
    switch (_gen) {
      case BondGeneration.v1:
        _startV1();
      case BondGeneration.v2 || BondGeneration.v4 || BondGeneration.mini:
        _startV2Base();
      case BondGeneration.v3 || null:
        break;
    }
  }

  // MARK: - Characteristic values / notification state (the CBPeripheralDelegate)

  void _onValue(OnCharacteristicReceivedEvent e) {
    final p = _bracelet;
    if (p == null ||
        e.device.remoteId != p.remoteId ||
        !_linkUp ||
        e.error != null) {
      return;
    }
    _didUpdateValue(_key(e.characteristic.uuid), e.value);
  }

  void _didUpdateValue(String key, List<int> data) {
    if (key == BondGATT.batteryLevel) {
      if (data.isNotEmpty) _battery = math.min(data[0], 100);
      return;
    }

    if (key == BondGATT.charApiVer && _gen == null) {
      final version = data.isEmpty ? null : data[0];
      final detected = BondGATT.generation(
        hasV3Service: false,
        apiVersion: version,
      );
      _gen = detected;
      _log(
        BraceletLogKind.send,
        'Bracelet: generation ${detected.name}',
        version == null
            ? ''
            : 'API 0x${version.toRadixString(16).toUpperCase().padLeft(2, '0')}',
      );
      _startSession();
      return;
    }

    if (key == BondGATT.modelChar) {
      modelNumber = _decodeString(data);
      notifyListeners();
      return;
    }

    final gen = _gen;
    if (gen == null) return;
    switch (gen) {
      case BondGeneration.v3:
        if (key == BondGATT.ffb2) {
          // A touch made on the bar, for the partner in its slot.
          final touch = _v3Recording.feed(data);
          if (touch != null) {
            _emitLocalTap(touch.samples, 3, _bondIDForSlot(touch.slot));
          }
          return;
        }
        if (key == BondGATT.ffb1) _handleV3(data);
      case BondGeneration.v1:
        _handleV1(key, data);
      case BondGeneration.v2 || BondGeneration.v4 || BondGeneration.mini:
        _handleV2Base(key, data);
    }
    notifyListeners(); // charging / firmware may have changed
  }

  void _didEnableNotifications(String key) {
    final gen = _gen;
    // Bond Touch 4 / mini: the encrypted ffa8 is on, so the phone has bonded with the
    // bracelet — the original writes its bonded settings at this point (D()).
    if (key == BondGATT.charBondNotify &&
        (gen == BondGeneration.v4 || gen == BondGeneration.mini)) {
      _enqueue(BondGATT.v2BondedSettings(gen!));
      return;
    }
    // Bond Touch More: FFB1 notifications are on — ask for the firmware version, as the
    // original does; ask once more after 3 s if it hasn't answered.
    if (gen != BondGeneration.v3 || key != BondGATT.ffb1) return;
    _enqueue([BondGATT.v3FirmwareRequest]);
    final session = _session;
    Timer(const Duration(seconds: 3), () {
      if (session != _session ||
          _gen != BondGeneration.v3 ||
          !_linkUp ||
          _v3FirmwareRead) {
        return;
      }
      _enqueue([BondGATT.v3FirmwareRequest]);
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _clearConnectWatchdog();
    _queueResumeTimer?.cancel();
    _v2QueueCheck?.cancel();
    _heartbeatTimer?.cancel();
    _heartbeatWatchdog?.cancel();
    _stateCtl.close();
    _touchCtl.close();
    _doubleTapCtl.close();
    _slotCtl.close();
    _playFailedCtl.close();
    super.dispose();
  }
}
