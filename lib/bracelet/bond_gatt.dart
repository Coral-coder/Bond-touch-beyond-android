// Bond Touch bracelet GATT layout and wire format — a byte-for-byte port of the iOS
// app's BondGATT.swift. See docs/BLE_PROTOCOL.md and docs/BTM_TOUCH_FORMAT.md.
//
// Pure Dart (no Flutter / BLE imports) so it can be unit-tested on its own. UUIDs are
// lowercase 128-bit strings, the form flutter_blue_plus's `Guid.str128` produces.

import 'dart:math' as math;
import 'dart:typed_data';

import '../models/touch_message.dart';

/// Bond Touch bracelet generations. The original app supports five, selected at runtime
/// from the advertised service / API-version byte.
enum BondGeneration {
  /// classic "BOND" (legacy sequenced FF06-style frames on d3c0ffa6)
  v1,

  /// "BOND" / "Bond More" (API 0x42)
  v2,

  /// "BOND 4" (API 0x44)
  v4,

  /// "BOND MINI" (API 0x45)
  mini,

  /// "BTM" — devices exposing the d3c00003 service
  v3;

  /// v4 and mini share the v2 app service / characteristics and frame format.
  bool get usesV2Base => this == v2 || this == v4 || this == mini;

  /// The newest firmware the original app ships for this generation and the bundled file
  /// that holds it. Both classic v1 and v2 restart as BOND_DFU; the v1's image is the
  /// older-hardware one ("2.60" = 1.2.96).
  ({BraceletModel model, BondFirmwareVersion version, String file})
  get latestFirmware {
    switch (this) {
      case v1:
        return (
          model: BraceletModel.bondTouch,
          version: const BondFirmwareVersion(1, 2, 96),
          file: 'bondTouch-hw203',
        );
      case v2:
        return (
          model: BraceletModel.bondTouch,
          version: const BondFirmwareVersion(2, 7, 9),
          file: 'bondTouch',
        );
      case v3:
        return (
          model: BraceletModel.bondTouchMore,
          version: const BondFirmwareVersion(3, 1, 1),
          file: 'bondTouchMore',
        );
      case v4:
        return (
          model: BraceletModel.bondTouch4,
          version: const BondFirmwareVersion(2, 0, 3),
          file: 'bondTouch4',
        );
      case mini:
        return (
          model: BraceletModel.bondMini,
          version: const BondFirmwareVersion(1, 2, 0),
          file: 'bondMini',
        );
    }
  }
}

/// One GATT write: the characteristic (lowercase 128-bit UUID) and the bytes. The Dart
/// counterpart of Swift's `(CBUUID, Data)` tuple.
class GattWrite {
  GattWrite(this.char, List<int> data) : data = Uint8List.fromList(data);
  final String char;
  final Uint8List data;

  @override
  bool operator ==(Object other) =>
      other is GattWrite &&
      other.char == char &&
      other.data.length == data.length &&
      _listEq(other.data, data);

  @override
  int get hashCode => Object.hash(char, Object.hashAll(data));

  @override
  String toString() =>
      'GattWrite($char, ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')})';
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Bond Touch bracelet GATT layout and wire format, reverse-engineered from the official
/// app for interoperability. Vendor UUID base `d3c0XXXX-add3-1d4b-NODE-0000b5006bb1`
/// (NODE is `0000` except the app-service characteristics, which use `0001`).
abstract final class BondGATT {
  // MARK: Services
  static const serviceV3 = 'd3c00003-add3-1d4b-0000-0000b5006bb1';
  static const serviceOTA = 'd3c00001-add3-1d4b-0000-0000b5006bb1';
  static const serviceApp = 'd3c00002-add3-1d4b-0001-0000b5006bb1';
  static const batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
  static const disService = '0000180a-0000-1000-8000-00805f9b34fb';
  static const firmwareChar = '00002a26-0000-1000-8000-00805f9b34fb';
  static const modelChar = '00002a24-0000-1000-8000-00805f9b34fb';
  static const cccd = '00002902-0000-1000-8000-00805f9b34fb';

  // MARK: v1 / v2 / v4 / mini characteristics (app service, node 0001)
  /// token write
  static const charToken = 'd3c0ffa1-add3-1d4b-0001-0000b5006bb1';

  /// AUID write
  static const charAuid = 'd3c0ffa2-add3-1d4b-0001-0000b5006bb1';

  /// state notify
  static const charState = 'd3c0ffa4-add3-1d4b-0001-0000b5006bb1';

  /// touch/event notify
  static const charEvent = 'd3c0ffa5-add3-1d4b-0001-0000b5006bb1';

  /// app command write (all non-v3)
  static const charAppCmd = 'd3c0ffa6-add3-1d4b-0001-0000b5006bb1';

  /// v1 command-result notify
  static const v1Ack = 'd3c0ffa7-add3-1d4b-0001-0000b5006bb1';

  /// v4/mini: an encrypted characteristic — subscribing to it makes the phone bond.
  static const charBondNotify = 'd3c0ffa8-add3-1d4b-0001-0000b5006bb1';

  // MARK: Service d3c00001 (node 0000)
  /// API-version read
  static const charApiVer = 'd3c0ffb3-add3-1d4b-0000-0000b5006bb1';

  /// Battery: v2/v4/mini `[level %, reserved]`; v1 `[millivolts u16LE]`. Read + notify.
  static const charFF06 = 'd3c0ff06-add3-1d4b-0000-0000b5006bb1';

  /// v1 `[patch, minor]`
  static const v1Firmware = 'd3c0ff03-add3-1d4b-0000-0000b5006bb1';

  // MARK: v3 characteristics (service d3c00003, node 0000)
  static const v3ApiVer = 'd3c0ff10-add3-1d4b-0000-0000b5006bb1';

  /// app cmds + notify
  static const ffb1 = 'd3c0ffb1-add3-1d4b-0000-0000b5006bb1';

  /// touch pattern write
  static const ffb2 = 'd3c0ffb2-add3-1d4b-0000-0000b5006bb1';

  /// Fixed app-layer pairing token used by the shipping firmware: ASCII "12345678".
  static const List<int> token = [
    0x31,
    0x32,
    0x33,
    0x34,
    0x35,
    0x36,
    0x37,
    0x38,
  ];

  /// Vibration strengths the bracelets accept (VibrationHelper); balance is 0…4, 2 = centre.
  static const List<int> vibrationLevels = [
    28,
    33,
    40,
    58,
    60,
    73,
    80,
    88,
    100,
  ];

  // MARK: Names
  static const deviceNames = ['BOND', 'Bond More', 'BOND 4', 'BOND MINI'];
  static const dfuNames = [
    'BOND_DFU',
    'BOND_M_DFU',
    'BOND_4_DFU',
    'BOND_MINI_DFU',
  ];

  /// A normal (running) bracelet: the name starts with "BOND" (any case). Excludes
  /// bracelets in firmware-update (DFU) mode, and the Bond Heart pendant ("BondHeart" /
  /// "BOND_H_DFU").
  static bool isBondName(String? name) {
    if (name == null) return false;
    final upper = name.toUpperCase();
    if (upper.startsWith('BONDHEART') || upper.startsWith('BOND_H_')) {
      return false;
    }
    return upper.startsWith('BOND') && dfuModel(name) == null;
  }

  /// The bracelet model of a bracelet stuck in firmware-update (DFU) mode, from the name
  /// its bootloader advertises. Null for anything else.
  static BraceletModel? dfuModel(String? name) {
    switch (name?.toUpperCase()) {
      case 'BOND_DFU':
        return BraceletModel.bondTouch;
      case 'BOND_M_DFU':
        return BraceletModel.bondTouchMore;
      case 'BOND_4_DFU':
        return BraceletModel.bondTouch4;
      case 'BOND_MINI_DFU':
        return BraceletModel.bondMini;
      default:
        return null;
    }
  }

  /// Generation from the API-version byte (non-v3) or the presence of the v3 service.
  static BondGeneration generation({
    required bool hasV3Service,
    int? apiVersion,
  }) {
    if (hasV3Service) return BondGeneration.v3;
    switch (apiVersion) {
      case 0x42:
        return BondGeneration.v2;
      case 0x44:
        return BondGeneration.v4;
      case 0x45:
        return BondGeneration.mini;
      default:
        return BondGeneration.v1;
    }
  }

  /// Services to discover (null → discover all, so we can detect the generation).
  static const List<String>? discoverServices = null;

  // MARK: - Pairing handshake

  /// Token write(s) for a generation: ASCII "12345678".
  static List<GattWrite> tokenWrites(BondGeneration gen) {
    switch (gen) {
      case BondGeneration.v3:
        // Exactly as the original app: [3] + "12345678", unpadded, and only when the
        // bracelet reports it is waiting for the token.
        return [
          GattWrite(ffb1, [3, ...token]),
        ];
      default:
        // v1 (WriteStringCommand) and v2-base: the bare 8 ASCII bytes on ffa1.
        return [GattWrite(charToken, token)];
    }
  }

  /// AUID write(s): the persisted per-install device/user id, little-endian u32.
  static List<GattWrite> auidWrites(BondGeneration gen, int auid) {
    switch (gen) {
      case BondGeneration.v3:
        // The Bond Touch More takes a single-byte AUID: [7, id], unpadded.
        final id = auid & 0xFF;
        return [
          GattWrite(ffb1, [7, id == 0 ? 1 : id]),
        ];
      default:
        return [GattWrite(charAuid, u32le(auid))];
    }
  }

  // MARK: - LED + motor (notification buzz + glow)

  /// A buzz + glow in [rgb] (used for heartbeat pulses; not part of the original app).
  /// v2-base uses the 0x26 LED+motor frame; v3 the FFB1 colour + vibration commands. v1
  /// has its own sequenced frames ([V1Commands]).
  static List<GattWrite> ledMotor(
    BondGeneration gen,
    int rgb, {
    int strength = 88,
    int vibMs = 400,
    int brightness = 100,
    int holdMs = 600,
  }) {
    switch (gen) {
      case BondGeneration.v3:
        // FFB1 commands are written at their exact length, as the original app does.
        final c = rgbBytes(rgb);
        return [
          GattWrite(ffb1, [1, 0x4B, 0x00, 0x00, c.r, c.g, c.b]),
          v3VibrationPreview(
            level: nearestVibrationLevel(_u8c(strength)),
            balance: 2,
          ),
        ];
      case BondGeneration.v1:
        return [];
      default:
        return [
          ledAndMotor(
            strength: strength,
            vibMs: vibMs,
            ledMode: 1,
            rgb: ledColor(rgb),
            brightness: brightness,
            transitionMs: 80,
            holdMs: holdMs,
            sleepMs: 80,
            executeMs: holdMs,
          ),
        ];
    }
  }

  // MARK: - Light only (no motor) and the LED test queue — docs/FIRMWARE_LED_VIBE.md

  /// The band lit in [rgb] for [ms] without vibrating. v2/v4/Mini: a 0x26 frame with motor
  /// strength 0. Bond Touch More: FFB1 0x4B, which never touches the motors (clear it with
  /// [v3LightOff]). Classic: not supported.
  static List<GattWrite> lightOnly(
    BondGeneration gen,
    int rgb, {
    int brightness = 80,
    int ms = 1000,
  }) {
    switch (gen) {
      case BondGeneration.v3:
        return [v3Color(rgb)];
      case BondGeneration.v1:
        return [];
      default:
        return [
          ledAndMotor(
            strength: 0,
            vibMs: 0,
            ledMode: 1,
            rgb: rgb,
            brightness: math.max(1, _u8c(brightness)),
            transitionMs: 0,
            holdMs: ms,
            sleepMs: 0,
            executeMs: ms,
          ),
        ];
    }
  }

  /// Bond Touch More: `[01 4B 01]` clears the colour set by 0x4B.
  static final GattWrite v3LightOff = GattWrite(ffb1, [1, 0x4B, 0x01]);

  /// One step of the firmware-timed LED test queue (0x33), silent (motor strength 0): three
  /// LEDs, each its own colour (0 = dark), for [ms] (at least 5 — shorter reboots a Bond
  /// Touch). A step with every LED dark switches the LEDs off for its time.
  static GattWrite lightStep(
    List<int> colors, {
    required int brightness,
    required int ms,
  }) {
    final c = [...colors, 0, 0, 0].take(3).map((x) => x & 0xFFFFFF).toList();
    final level = c.every((x) => x == 0)
        ? 0
        : math.max(1, safeBrightness(_u8c(brightness)));
    final f = <int>[0x33, 0x00, 0x00, level, level, level];
    for (final rgb in c) {
      f.addAll(be3(rgb));
    }
    f.addAll(u16le(math.max(5, _u16c(ms))));
    return _app(f);
  }

  /// Plays the queued 0x33 steps (up to 256).
  static final GattWrite lightQueueStart = _app([0x32, 0x00, 0x22]);

  /// Touch 4 / Mini: several app frames in one write, `[0x88, len, frame…, len, frame…]`
  /// (each frame's first 17 bytes). **Hypothesis** — whether FFA6 takes writes this long.
  static List<GattWrite> batched(List<GattWrite> frames, {int perWrite = 9}) {
    final out = <GattWrite>[];
    for (var i = 0; i < frames.length; i += perWrite) {
      final bytes = <int>[0x88];
      for (final f in frames.sublist(
        i,
        math.min(frames.length, i + perWrite),
      )) {
        bytes
          ..add(17)
          ..addAll(f.data.take(17));
      }
      out.add(GattWrite(charAppCmd, bytes));
    }
    return out;
  }

  /// One heartbeat pulse: a short firm buzz + glow.
  static List<GattWrite> heartbeatPulse(BondGeneration gen, int rgb) =>
      ledMotor(
        gen,
        rgb,
        strength: 100,
        vibMs: 130,
        brightness: 100,
        holdMs: 130,
      );

  /// The closest strength the bracelets accept.
  static int nearestVibrationLevel(int x) {
    var best = vibrationLevels.first;
    for (final v in vibrationLevels.skip(1)) {
      if ((v - x).abs() < (best - x).abs()) best = v;
    }
    return best;
  }

  // MARK: - v2 / v4 / mini app commands (BleBondManagerV2Base, BleAppCommandHelper)

  /// v2-base frames are `Arrays.copyOf(frame, 20)`: zero-padded to 20 bytes, on ffa6.
  static GattWrite _app(List<int> bytes) {
    final b = bytes.take(20).toList();
    while (b.length < 20) {
      b.add(0);
    }
    return GattWrite(charAppCmd, b);
  }

  /// 0x26 LedAndMotorCommand: `[0x26, 0, queue, strength, vibMs LE, ledMode, R, G, B,
  /// brightness, transition LE, hold LE, sleep LE, execute LE]`. ledMode 1 = solid,
  /// 2 = queued pattern step, 4 = off.
  static GattWrite ledAndMotor({
    int queue = 0,
    required int strength,
    required int vibMs,
    required int ledMode,
    int rgb = 0,
    int brightness = 0,
    int transitionMs = 0,
    int holdMs = 0,
    int sleepMs = 0,
    int executeMs = 0,
  }) {
    final c = rgbBytes(rgb);
    final f = <int>[0x26, 0x00, queue & 0xFF, strength & 0xFF];
    f.addAll(u16le(safeMs(_u16c(vibMs))));
    f.addAll([ledMode & 0xFF, c.r, c.g, c.b, safeBrightness(_u8c(brightness))]);
    f.addAll(u16le(safeMs(_u16c(transitionMs))));
    f.addAll(u16le(safeMs(_u16c(holdMs))));
    f.addAll(u16le(safeMs(_u16c(sleepMs))));
    f.addAll(u16le(safeMs(_u16c(executeMs))));
    return _app(f);
  }

  /// 0x33 "send message" step (BleAppCommandHelper.a): `[0x33, 0, strength, brightness ×3,
  /// RGB1, RGB2, RGB3, ms LE16]`.
  static GattWrite _messageStep(
    int rgb, {
    required int strength,
    required int brightness,
    required int ms,
  }) {
    final level = safeBrightness(brightness);
    final f = <int>[0x33, 0x00, strength & 0xFF, level, level, level];
    f
      ..addAll(be3(rgb))
      ..addAll(be3(rgb))
      ..addAll(be3(rgb));
    f.addAll(u16le(safeMs(_u16c(ms))));
    return _app(f);
  }

  /// The firmware lights the LEDs only at brightness 1…100; 0 is off, and anything above
  /// 100 is also off — so cap at 100.
  static int safeBrightness(int b) => math.min(b, 100);

  /// A duration the Bond Touch's timer can start: 1–4 ms fails to start it and the bracelet
  /// reboots, so those become 5 ms. 0 (none) stays 0.
  static int safeMs(int ms) => (ms >= 1 && ms <= 4) ? 5 : ms;

  /// 0x32 (BleAppCommandHelper.b): ends a queued message — 0x22 after 0x33 steps, 0x11
  /// after queued 0x26 frames. The original pauses its write queue 5 s once it's written.
  static GattWrite queueMarker({required bool gradient}) =>
      _app([0x32, 0x00, gradient ? 0x22 : 0x11]);

  /// 0x27 configuration write (BleAppCommandHelper.d): `[0x27, 0, property, 1, value…]`.
  static GattWrite _config(int property, List<int> value) =>
      _app([0x27, 0x00, property, 0x01, ...value]);

  /// A colour as the config commands carry it: the mapped ARGB int, big-endian (alpha 0xFF).
  static List<int> _configColor(int rgb) =>
      be32(0xFF000000 | (ledColor(rgb) & 0xFFFFFF));

  /// A touch to play (BleBondManagerV2Base.g). One colour: queued 0x26 frames (queue 1),
  /// one per on/off pair, then `[0x32,0,0x11]`. A gradient: one 0x33 frame per 200 ms of
  /// each on segment (the original's `0..n` loop, so n+1 frames) shading start→end, a
  /// zero-colour 0x33 frame for each gap, then `[0x32,0,0x22]`. The mini always plays its
  /// fixed pattern (BleBondManagerMini.g); an empty pattern falls back to it too.
  static List<GattWrite> v2TouchFrames(
    BondGeneration gen, {
    required List<int> onOff,
    required int startRGB,
    required int endRGB,
    required int strength,
  }) {
    final list = gen == BondGeneration.mini || onOff.isEmpty
        ? miniPattern
        : onOff.map((x) => math.max(0, x)).toList();
    if (startRGB == endRGB) {
      final rgb = ledColor(startRGB);
      final on = <int>[], off = <int>[];
      for (var i = 0; i < list.length; i++) {
        if (i.isEven) {
          on.add(list[i]);
        } else {
          off.add(list[i]);
        }
      }
      if (on.length > off.length) off.add(0);
      final out = <GattWrite>[];
      for (var i = 0; i < on.length; i++) {
        final o = on[i], f = off[i];
        // Int(Float(o) * 0.25), in Float32 as the Swift code.
        final t = _f32(_f32(o.toDouble()) * 0.25).truncate();
        out.add(
          ledAndMotor(
            queue: 1,
            strength: strength,
            vibMs: _u16c(o),
            ledMode: 2,
            rgb: rgb,
            brightness: 80,
            transitionMs: _u16c(t),
            holdMs: _u16c(o - t * 2),
            sleepMs: _u16c(f),
            executeMs: _u16c(o + f),
          ),
        );
      }
      out.add(queueMarker(gradient: false));
      return out;
    }
    final from = ledColor(startRGB), to = ledColor(endRGB);
    final total = _f32(list.fold<int>(0, (a, b) => a + b).toDouble());
    var elapsed = 0.0; // Float32
    final out = <GattWrite>[];
    for (var i = 0; i < list.length; i++) {
      final ms = list[i];
      if (i.isEven) {
        final steps = math.max(1, _f32(_f32(ms.toDouble()) / 200).truncate());
        for (var s = 0; s <= steps; s++) {
          final t = total > 0 ? math.min(1.0, _f32(elapsed / total)) : 0.0;
          final rgb = _blend(from, to, t);
          out.add(
            _messageStep(rgb, strength: strength, brightness: 80, ms: 200),
          );
          elapsed = _f32(elapsed + 200);
        }
      } else {
        out.add(_messageStep(0, strength: 0, brightness: 0, ms: ms));
        elapsed = _f32(elapsed + _f32(ms.toDouble()));
      }
    }
    out.add(queueMarker(gradient: true));
    return out;
  }

  /// What the mini plays and reports for every touch (BleBondManagerMiniKt.b).
  static const List<int> miniPattern = [500, 250, 500, 250, 500];

  /// Written once the bracelet is bonded (BleBondManagerV2Base.D): low-battery alert at
  /// 10 %, blinking red 1000/500 ms; minimum touch 50 ms; "disconnected" params all zero.
  /// v2 also turns ANCS off (BleBondManagerV2.D).
  static List<GattWrite> v2BondedSettings(BondGeneration gen) {
    final lowBattery = <int>[
      1,
      ...be16(1000),
      ...be16(500),
      ...be32(1171),
      ...be32(0x00FF0000),
    ];
    final disconnected = <int>[
      0,
      ...be16(0),
      ...be16(0),
      ...be16(0),
      ...be32(0),
    ];
    final out = <GattWrite>[
      _config(0x17, [10]), // LOW_BAT_THRESHOLD 10 %
      _config(0x21, lowBattery), // LOW_BAT_COLOR: on, 1000 / 500 ms, 1171, red
      _config(0x14, u32le(50)), // MIN_TOUCH_DURATION 50 ms (u32 little-endian)
      _config(0x31, disconnected), // DISCONNECTED_PARAM
    ];
    if (gen == BondGeneration.v2) out.add(v2Ancs(false));
    return out;
  }

  /// ANCS_PARAM (0x33): whether the bracelet shows the phone's notifications.
  static GattWrite v2Ancs(bool on) => _config(0x33, [on ? 1 : 0]);

  /// MOTOR_STRENGTH (0x18) — BleBondManagerV2Base.B (balance isn't used on these models).
  static GattWrite v2MotorStrength(int level) => _config(0x18, [_u8c(level)]);

  /// The user's own colour (f()): TOUCH_COLOR, then on v2 DOUBLE_TAP_COLOR and on v4/mini
  /// the user's menu entry (UserMenu(colour, 0x80), also property 0x24).
  static List<GattWrite> v2UserColor(BondGeneration gen, int rgb) {
    final color = _configColor(rgb);
    return [
      _config(0x25, color),
      gen == BondGeneration.v2
          ? _config(0x24, color)
          : _config(0x24, [...color, ...be32(0x80)]),
    ];
  }

  /// One v4 partner-menu entry (BleBondManagerV4.W): UserMenu(colour, slot | 0x80) when
  /// active, UserMenu(0xFF000000, slot & 0x7F) when not.
  static GattWrite v2MenuEntry({required int slot, int? rgb}) {
    if (rgb != null) {
      return _config(0x24, [..._configColor(rgb), ...be32(slot | 0x80)]);
    }
    return _config(0x24, [...be32(0xFF000000), ...be32(slot & 0x7F)]);
  }

  /// SELECTED_USER (0x37): which partner slot (1…3) the v4 sends to.
  static GattWrite v2SelectedUser(int slot) => _config(0x37, [_u8c(slot)]);

  /// The answer to the PAIRED_SIGNAL event (0x13).
  static final GattWrite v2PairedReply = _app([
    0x31,
    0x00,
    0x11,
    0x22,
    0x33,
    0x44,
  ]);

  /// Vibration preview (BleBondManagerV2Base.z): motor only, 2 s.
  static GattWrite v2VibrationPreview(int level) =>
      ledAndMotor(strength: _u8c(level), vibMs: 2000, ledMode: 4);

  /// Colour preview (y()): hold [rgb] until told otherwise (execute 0xFFFF).
  static GattWrite v2HoldColor(int rgb) => ledAndMotor(
    strength: 0,
    vibMs: 0,
    ledMode: 1,
    rgb: ledColor(rgb),
    brightness: 80,
    executeMs: 0xFFFF,
  );

  /// LEDs off (h()).
  static final GattWrite v2LedsOff = ledAndMotor(
    strength: 0,
    vibMs: 0,
    ledMode: 4,
  );

  /// Restarts a v2 / v4 / mini in its update (DFU) bootloader (BleBondManagerV2Base.C,
  /// "startDfuMode"): `[0x25, 0x00, 0x11, 0x22, 0x33, 0x44]`, zero-padded to 20, on ffa6.
  static final GattWrite v2EnterUpdateMode = _app([
    0x25,
    0x00,
    0x11,
    0x22,
    0x33,
    0x44,
  ]);

  /// Parses a v2-base AppEvent `[eventId, counter, touchMs u32LE, releaseMs u32LE,
  /// stop u32LE, (v4) slot]` from the event characteristic (ffa5).
  static V2Event v2Event(List<int> b) {
    // A 0x19 blob of length >= 14 is a ship-mode / BLE-params report, not an event.
    if (b.length < 14 || b[0] == 0x19) return const V2Ignored();
    final counter = b[1];
    final slot = b.length > 14 ? b[14] : 0;
    switch (b[0]) {
      case 0x12:
        return const V2AuidError();
      case 0x13:
        return const V2PairedSignal();
      case 0x14:
        return V2Segment(
          touchMs: _u32leAt(b, 2),
          releaseMs: _u32leAt(b, 6),
          counter: counter,
          stop: _u32leAt(b, 10) == 0xFFFFFFFF,
          slot: slot,
        );
      case 0x15:
        return V2Timeout(counter: counter, slot: slot);
      case 0x16:
        return const V2Tap();
      case 0x17:
        return const V2DoubleTap();
      default:
        return const V2Ignored();
    }
  }

  // MARK: - v1 commands (BleBondManagerV1, v1.BleAppCommandHelper, WriteFF06Command)

  /// The answer to the v1 PAIRED_SIGNAL event (19): a single byte 0x31 on ffa6.
  static final GattWrite v1PairedReply = GattWrite(charAppCmd, [0x31]);

  /// v1 battery (ff06): millivolts → % over 3.7…4.1 V.
  static int? v1BatteryPercent(List<int> b) {
    if (b.length < 2) return null;
    final mv = b[0] | b[1] << 8;
    return (mv - 3700).clamp(0, 400) * 100 ~/ 400;
  }

  /// The v1 LED for a colour: ColorMapperHelper.a snaps it to the base palette, then the
  /// palette colour's LED id and step length (default LED 1, 100).
  static ({int id, int steps}) v1Led(int rgb) {
    final base = _v1BaseColor[rgb & 0xFFFFFF] ?? 0x23E0E8;
    return _v1LedIDs[base] ?? (id: 1, steps: 100);
  }

  /// BleColorTable: the ARGB colour of each v1 LED id (‑1 for an unknown id).
  static int v1Palette(int id) {
    const table = [
      0xFF0000, 0x00EEF9, 0x000FF9, 0xBA00F9, 0xF9002D, 0x07F900, //
      0x61F900, 0xF9F500, 0xF94300, 0xFFFFFF, 0x000000,
    ];
    return id < table.length ? 0xFF000000 | table[id] : 0xFFFFFFFF;
  }

  static const Map<int, ({int id, int steps})> _v1LedIDs = {
    0xFF0000: (id: 0, steps: 30),
    0x23E0E8: (id: 1, steps: 100),
    0x106DED: (id: 2, steps: 100),
    0xBE5BFF: (id: 3, steps: 100),
    0xA502C0: (id: 3, steps: 100),
    0xFF44A6: (id: 4, steps: 100),
    0x03AB55: (id: 5, steps: 100),
    0x7BBE2F: (id: 6, steps: 100),
    0xE8D726: (id: 7, steps: 100),
    0xFF7931: (id: 8, steps: 100),
    0xFFFFFF: (id: 9, steps: 100),
    0x000000: (id: 10, steps: 100),
  };

  /// ColorMapperHelper.a: app colour → base palette colour (v1).
  static const Map<int, int> _v1BaseColor = {
    0x23E0E8: 0x23E0E8,
    0x106DED: 0x106DED,
    0xBE5BFF: 0xBE5BFF,
    0xFF44A6: 0xFF44A6,
    0x03AB55: 0x03AB55, //
    0x7BBE2F: 0x7BBE2F,
    0xE8D726: 0xE8D726,
    0xFF7931: 0xFF7931,
    0xA502C0: 0xA502C0,
    0xD3007A: 0xFF44A6, //
    0xD33901: 0xFF7931,
    0xFF7C00: 0xFF7931,
    0xEFAE1D: 0xFF7931,
    0xFFE700: 0xE8D726,
    0xE4FF02: 0xE8D726, //
    0xAFFF00: 0xE8D726,
    0x79FF03: 0x7BBE2F,
    0x00D600: 0x7BBE2F,
    0x00B560: 0x03AB55,
    0x01D3B1: 0x03AB55, //
    0x28E4EB: 0x23E0E8,
    0x00A4D3: 0x23E0E8,
    0x006BD3: 0x106DED,
    0x0045D2: 0x106DED,
    0x1800C8: 0x106DED, //
    0x6D3DC9: 0xBE5BFF,
    0x9D03DD: 0xBE5BFF,
    0xC300D3: 0xBE5BFF,
    0xD301AA: 0xFF44A6,
    0xFA3A96: 0xFF44A6, //
    0xFF5338: 0xFF7931,
    0xFF7701: 0xFF7931,
    0xFFA910: 0xFF7931,
    0xFFCD00: 0xE8D726,
    0xFFE804: 0xE8D726, //
    0xEDFF04: 0xE8D726,
    0xB6FF01: 0x7BBE2F,
    0x5FF540: 0x7BBE2F,
    0x05EB79: 0x03AB55,
    0x2EF3BC: 0x03AB55, //
    0x51FBF3: 0x23E0E8,
    0x22E7FF: 0x23E0E8,
    0x00C8FF: 0x106DED,
    0x009FFF: 0x106DED,
    0x1875FF: 0x106DED, //
    0x8E59FF: 0xBE5BFF,
    0xB659FF: 0xBE5BFF,
    0xF25BFF: 0xBE5BFF,
    0xF44CCE: 0xFF44A6,
  };

  /// ColorMapperHelper.b: the app's palette colours → the LED colours v2/v4/mini show
  /// (anything else is sent as is).
  static int ledColor(int rgb) =>
      _ledColorMap[rgb & 0xFFFFFF] ?? (rgb & 0xFFFFFF);

  static const Map<int, int> _ledColorMap = {
    0xFA3A96: 0xD30013,
    0xFF5338: 0xFF0C00,
    0xFF7701: 0xFF2200,
    0xFFA910: 0xF83C00,
    0xFFCD00: 0xF85000, //
    0xFFE804: 0xF89200,
    0xEDFF04: 0xDDC500,
    0xB6FF01: 0x9FC500,
    0x5FF540: 0x58B800,
    0x05EB79: 0x087100, //
    0x2EF3BC: 0x08FB35,
    0x51FBF3: 0x6DF7E3,
    0x22E7FF: 0x00B7D3,
    0x00C8FF: 0x006BD3,
    0x009FFF: 0x0032D3, //
    0x1875FF: 0x000078,
    0x8E59FF: 0x6500D3,
    0xB659FF: 0xB100D3,
    0xF25BFF: 0xD30072,
    0xF44CCE: 0xD30039, //
    0xD3007A: 0xD30013,
    0xD33901: 0xFF0C00,
    0xFF7C00: 0xFF2200,
    0xEFAE1D: 0xF83C00,
    0xFFE700: 0xF85000, //
    0xE4FF02: 0xF89200,
    0xAFFF00: 0xDDC500,
    0x79FF03: 0x9FC500,
    0x00D600: 0x58B800,
    0x00B560: 0x087100, //
    0x01D3B1: 0x08FB35,
    0x28E4EB: 0x6DF7E3,
    0x00A4D3: 0x00B7D3,
    0x006BD3: 0x006BD3,
    0x0045D2: 0x0032D3, //
    0x1800C8: 0x000078,
    0x6D3DC9: 0x6500D3,
    0x9D03DD: 0xB100D3,
    0xC300D3: 0xD30072,
    0xD301AA: 0xD30039,
  };

  /// Linear blend per channel, truncated (the original's ArgbEvaluator-style sb1.b), in
  /// Float32 as the Swift code.
  static int _blend(int a, int b, double t) {
    final oneMinus = _f32(1 - t);
    int ch(int shift) {
      final p1 = _f32(((b >> shift) & 0xFF) * t);
      final p2 = _f32(((a >> shift) & 0xFF) * oneMinus);
      return _f32(p1 + p2).truncate();
    }

    return (ch(16) << 16) | (ch(8) << 8) | ch(0);
  }

  /// What the original app sends once a Bond Touch More reports CONNECTED: enables its
  /// touch and event features (0x19, 0x1B, 0x41, 0x42, [0x49, 1], 0x1C).
  static final List<GattWrite> v3ConnectedWrites = [
    [1, 0x19],
    [1, 0x1B],
    [1, 0x41],
    [1, 0x42],
    [1, 0x49, 0x01],
    [1, 0x1C],
  ].map((b) => GattWrite(ffb1, b)).toList();

  // MARK: - Bond Touch More session commands (from the original app's BleBondManagerV3)

  /// Asks for the firmware version (answered with an 0xAC notification). The original
  /// sends it right after enabling FFB1 notifications; the answer is what marks the
  /// bracelet as paired, after which settings go out.
  static final GattWrite v3FirmwareRequest = GattWrite(ffb1, [1, 0x30]);

  /// "Paired" confirmation — the answer to WAIT_FOR_ACT_PAIRED (state 138) and to the
  /// PAIRED signal (event 19). Without it the bracelet sits flashing white and drops the link.
  static final GattWrite v3PairedConfirm = GattWrite(ffb1, [1, 0x31]);

  /// Asks for the three partner slots currently on the bracelet (answered with an ack
  /// `[0x0A, 0x45, 3 × (state, R, G, B)]`).
  static final GattWrite v3ReadUserColors = GattWrite(ffb1, [1, 0x45, 0x01]);

  /// Writes the three partner slots: `[1, 0x45, 0x00, slot1, slot2, slot3]`, each slot
  /// `[state, R, G, B]` (state 2 = leave that slot as it is).
  static GattWrite v3WriteUserColors(List<V3Slot> slots) {
    final three = [
      ...slots,
      V3Slot.inactive,
      V3Slot.inactive,
      V3Slot.inactive,
    ].take(3);
    return GattWrite(ffb1, [1, 0x45, 0x00, for (final s in three) ...s.bytes]);
  }

  /// Parses the slots from a user-colour ack `[0x0A, 0x45, s, r, g, b, s, r, g, b, s, r, g, b]`.
  static List<V3Slot>? v3UserColors(List<int> b) {
    if (b.length < 14 || b[0] != 0x0A || b[1] != 0x45) return null;
    return List.generate(3, (i) {
      final o = 2 + i * 4;
      return V3Slot(
        V3SlotState.fromRaw(b[o]) ?? V3SlotState.ignore,
        (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3],
      );
    });
  }

  /// Vibration strength and left/right balance: `[1, 0x48, 0x02, level, balance, 0x03]`
  /// (BleBondManagerV3.F). Valid levels 28, 33, 40, 58, 60, 73, 80, 88, 100; balance 0…4
  /// (2 = centred).
  static GattWrite v3Vibration({required int level, required int balance}) =>
      GattWrite(ffb1, [1, 0x48, 0x02, level & 0xFF, balance & 0xFF, 0x03]);

  /// Plays a vibration once without saving it: `[1, 0x48, 0x00, level, balance, 0x03]` (z()).
  static GattWrite v3VibrationPreview({
    required int level,
    required int balance,
  }) => GattWrite(ffb1, [1, 0x48, 0x00, level & 0xFF, balance & 0xFF, 0x03]);

  /// Lights the whole bar in a colour: `[1, 0x4B, 0x00, 0x00 (all LEDs), R, G, B]` (y()).
  static GattWrite v3Color(int rgb) =>
      GattWrite(ffb1, [1, 0x4B, 0x00, 0x00, ...be3(rgb)]);

  /// One heartbeat on a Bond Touch More bar: a 200 ms spike — up to the top of the bar and
  /// down to the bottom (the EKG's R and S) — the only part that vibrates; between beats
  /// the band just glows ([v3Color]).
  static List<GattWrite> v3HeartbeatSpike(int rgb) => _v3TouchFrames(
    [6, 8, 0, 2].map((p) => TouchPattern.sample([p])).toList(),
    startRGB: rgb,
    endRGB: rgb,
  );

  /// LEDs off: `[1, 0x4B, 0x01]` (h()).
  static final GattWrite v3LedsOff = GattWrite(ffb1, [1, 0x4B, 0x01]);

  /// Restarts a Bond Touch More in its update bootloader, as the original's C(): the
  /// firmware request `[1, 0x30]` (J()), then `[1, 0x2A]`, both at their exact length.
  static final List<GattWrite> v3EnterUpdateMode = [
    v3FirmwareRequest,
    GattWrite(ffb1, [1, 0x2A]),
  ];

  /// A whole heartbeat for a Bond Touch More as ONE touch message, shaped like a real
  /// heart: each beat is a big "lub" (the whole bar lights and both motors buzz, 150 ms)
  /// then, ~150 ms later, a smaller "dub" (just the centre, 100 ms), then a rest to the
  /// next beat. At most 10 s (200 samples); light and vibration render in sync.
  static List<GattWrite> v3Heartbeat({
    required int bpm,
    required double seconds,
    required int rgb,
  }) {
    final period = math.max(
      3,
      ((60.0 / math.max(bpm, 30)) * 1000).truncate() ~/ TouchPattern.sampleMs,
    );
    final total = math.min(
      TouchPattern.maxSamples,
      (seconds * 1000).truncate() ~/ TouchPattern.sampleMs,
    );
    const fullBar =
        (8 << 4) | 0; // two "fingers" at 0 and 8: the whole bar (the big lub)
    const centre = 0xF0 | 4; // one finger at the centre: the small dub
    const lub = 3, gap = 3, dub = 2;
    final samples = <int>[];
    while (samples.length < total) {
      if (period >= lub + gap + dub + 1) {
        samples
          ..addAll(List.filled(lub, fullBar))
          ..addAll(List.filled(gap, TouchPattern.none))
          ..addAll(List.filled(dub, centre))
          ..addAll(List.filled(period - lub - gap - dub, TouchPattern.none));
      } else {
        // Too fast to fit a lub-dub; one beat per period.
        samples
          ..addAll(List.filled(math.min(lub, period), fullBar))
          ..addAll(List.filled(math.max(0, period - lub), TouchPattern.none));
      }
    }
    return _v3TouchFrames(
      samples.take(math.max(0, total)).toList(),
      startRGB: rgb,
      endRGB: rgb,
    );
  }

  // MARK: - Sending a touch (replay the tap rhythm)

  /// Plays a touch on the bracelet.
  /// v3 (Bond Touch More): the 50 ms position samples on FFB2 — the bar lights and the
  /// vibration pans along the positions. v2-base: [v2TouchFrames] at the user's vibration
  /// strength. v1 frames are sequenced, so [V1Commands.touch] builds them instead.
  static List<GattWrite> touchSend(
    BondGeneration gen,
    TouchMessage touch, {
    int slot = 1,
    int strength = 80,
  }) {
    switch (gen) {
      case BondGeneration.v3:
        return _v3TouchFrames(
          touch.samples,
          startRGB: touch.colorRGB,
          endRGB: touch.endColorRGB,
          slot: slot,
        );
      case BondGeneration.v1:
        return [];
      default:
        return v2TouchFrames(
          gen,
          onOff: touch.onOffMs,
          startRGB: touch.colorRGB,
          endRGB: touch.endColorRGB,
          strength: _u8c(strength),
        );
    }
  }

  // MARK: - Rainbow

  /// A colour around the rainbow: 0 red → 1/6 yellow → 1/3 green → 1/2 cyan → 2/3 blue →
  /// 5/6 magenta → 1 red, at full saturation.
  static int rainbow(double x) {
    final h = (x - x.floorToDouble()) * 6;
    final i = h.truncate();
    final f = h - i;
    double r, g, b;
    switch (i) {
      case 0:
        (r, g, b) = (1, f, 0);
      case 1:
        (r, g, b) = (1 - f, 1, 0);
      case 2:
        (r, g, b) = (0, 1, f);
      case 3:
        (r, g, b) = (0, 1 - f, 1);
      case 4:
        (r, g, b) = (f, 0, 1);
      default:
        (r, g, b) = (1, 0, 1 - f);
    }
    return (r * 255).truncate() << 16 |
        (g * 255).truncate() << 8 |
        (b * 255).truncate();
  }

  /// Bond Touch More: the bracelet blends only two colours across a touch, so a rainbow is
  /// the touch cut into short pieces ([piece] samples, 50 ms each), each blending to the
  /// next hue — played one after another, each starting as the last ends. `at` is the
  /// piece's start in seconds.
  static List<({double at, List<GattWrite> writes})> v3RainbowPieces(
    List<int> raw, {
    int slot = 1,
    int piece = 9,
  }) {
    final samples = TouchPattern.trimmed(raw);
    if (samples.isEmpty) return [];
    final count = (samples.length + piece - 1) ~/ piece;
    return List.generate(count, (k) {
      final part = samples.sublist(
        k * piece,
        math.min(samples.length, (k + 1) * piece),
      );
      final from = rainbow(k / count * 0.85),
          to = rainbow((k + 1) / count * 0.85);
      return (
        at: (k * piece) * TouchPattern.sampleMs / 1000,
        writes: _v3TouchFrames(part, startRGB: from, endRGB: to, slot: slot),
      );
    });
  }

  /// Bond Touch / Touch 4 / Mini: the rhythm as 0x33 steps — every 50 ms of a press its own
  /// hue, sweeping the rainbow over the touch (all three LEDs), the motor at [strength];
  /// gaps dark and still. Then `[32 00 22]` plays it (up to 256 steps).
  static List<GattWrite> v2RainbowSteps({
    required List<int> onOff,
    required int strength,
  }) {
    final list = onOff.map((x) => math.max(0, x)).toList();
    final total = math.max(1, list.fold<int>(0, (a, b) => a + b)).toDouble();
    var elapsed = 0.0;
    final out = <GattWrite>[];
    for (var i = 0; i < list.length; i++) {
      if (out.length >= 255) continue;
      final ms = list[i];
      if (i.isEven) {
        var left = ms;
        while (left > 0 && out.length < 255) {
          final step = math.min(50, left);
          out.add(
            _messageStep(
              rainbow(elapsed / total * 0.85),
              strength: strength,
              brightness: 80,
              ms: math.max(5, step),
            ),
          );
          elapsed += step;
          left -= step;
        }
      } else if (ms > 0) {
        out.add(_messageStep(0, strength: 0, brightness: 0, ms: ms));
        elapsed += ms;
      }
    }
    return [...out, queueMarker(gradient: true)];
  }

  /// Bond Touch More: raw samples as a one-colour touch (no trimming — a POV message's
  /// blank columns are kept, except at the very ends).
  static List<GattWrite> v3Samples(
    List<int> samples,
    int rgb, {
    int slot = 1,
  }) => _v3TouchFrames(samples, startRGB: rgb, endRGB: rgb, slot: slot);

  /// FFB2 playback (BleBondManagerV3.g): header `[partner slot 1…3, n, ceil(n/20), colour1
  /// RGB, colour2 RGB, reply 0]` padded with 0xFF, then the sample bytes 20 per packet,
  /// padded with 0xFF. Colours go as is (no colour mapping on v3); the reply flag is 0 for
  /// a received touch. The firmware accepts 1…10 packets, so at most 200 samples.
  static List<GattWrite> _v3TouchFrames(
    List<int> raw, {
    required int startRGB,
    required int endRGB,
    int slot = 1,
  }) {
    var samples = TouchPattern.trimmed(raw).map(_u8c).toList();
    if (samples.isEmpty) {
      samples = [0xF4, 0xF4, 0xF4, 0xF4]; // a short centre tap
    }
    final chunks = (samples.length + 19) ~/ 20;
    final header = <int>[
      slot.clamp(1, 3),
      samples.length & 0xFF,
      chunks,
      ...be3(startRGB),
      ...be3(endRGB),
      0x00,
    ];
    final frames = <GattWrite>[GattWrite(ffb2, _padFF(header))];
    for (var idx = 0; idx < samples.length; idx += 20) {
      frames.add(
        GattWrite(
          ffb2,
          _padFF(samples.sublist(idx, math.min(idx + 20, samples.length))),
        ),
      );
    }
    return frames;
  }

  static List<int> _padFF(List<int> bytes) => [
    ...bytes,
    for (var i = bytes.length; i < 20; i++) 0xFF,
  ];

  // MARK: - Byte helpers
  static List<int> u16le(int x) => [x & 0xFF, (x >> 8) & 0xFF];
  static List<int> u32le(int x) => [
    x & 0xFF,
    (x >> 8) & 0xFF,
    (x >> 16) & 0xFF,
    (x >> 24) & 0xFF,
  ];
  static List<int> be16(int x) => [(x >> 8) & 0xFF, x & 0xFF];
  static List<int> be32(int x) => [
    (x >> 24) & 0xFF,
    (x >> 16) & 0xFF,
    (x >> 8) & 0xFF,
    x & 0xFF,
  ];
  static List<int> be3(int rgb) => [
    (rgb >> 16) & 0xFF,
    (rgb >> 8) & 0xFF,
    rgb & 0xFF,
  ];
  static ({int r, int g, int b}) rgbBytes(int rgb) =>
      (r: (rgb >> 16) & 0xFF, g: (rgb >> 8) & 0xFF, b: rgb & 0xFF);
  static int _u32leAt(List<int> b, int i) {
    if (b.length < i + 4) return 0;
    return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
  }
}

/// `UInt8(clamping:)`.
int _u8c(int x) => x.clamp(0, 0xFF);

/// `UInt16(clamping:)`.
int _u16c(int x) => x.clamp(0, 0xFFFF);

final Float32List _f32buf = Float32List(1);

/// Rounds to Float32, to reproduce the Swift `Float` arithmetic exactly.
double _f32(double x) {
  _f32buf[0] = x;
  return _f32buf[0];
}

/// The state characteristic (ffa4): `[bondState, chargingState, ledBusy, motorBusy, touchBusy]`.
/// Bond states 0x82 WAITING_TOKEN, 0x83 WAITING_AUID, 0x84 OOBE (setup), 0x85 CONNECTED,
/// 0x86 MSG, 0x87 FACTORY, 0x88 QUEUE_EXECUTING; charging 0 no, 1 charging, 2 full, 0xFF error.
class V2State {
  const V2State._(this.bond, this.charging);
  final int bond;
  final int charging;

  static V2State? parse(List<int> b) {
    if (b.length < 5) return null;
    return V2State._(b[0], b[1]);
  }
}

/// A v2-base AppEvent from the event characteristic (ffa5).
sealed class V2Event {
  const V2Event();
}

class V2AuidError extends V2Event {
  const V2AuidError();
}

class V2PairedSignal extends V2Event {
  const V2PairedSignal();
}

/// A recorded touch segment; [slot] is the v4 partner slot it's for (byte 14).
class V2Segment extends V2Event {
  const V2Segment({
    required this.touchMs,
    required this.releaseMs,
    required this.counter,
    required this.stop,
    required this.slot,
  });
  final int touchMs;
  final int releaseMs;
  final int counter;
  final bool stop;
  final int slot;
}

class V2Timeout extends V2Event {
  const V2Timeout({required this.counter, required this.slot});
  final int counter;
  final int slot;
}

class V2Tap extends V2Event {
  const V2Tap();
}

class V2DoubleTap extends V2Event {
  const V2DoubleTap();
}

class V2Ignored extends V2Event {
  const V2Ignored();
}

/// v1 frames on d3c0ffa6: `[opcode u16LE, seq u16LE, …]`, 16 bytes (8 for the short ones),
/// zero-filled, numbered with a running sequence that wraps after 65535.
class V1Commands {
  int _seq = 0;

  List<int> _next() {
    _seq += 1;
    if (_seq > 65535) _seq = 0;
    return BondGATT.u16le(_seq);
  }

  static GattWrite _frame(List<int> b, int length) => GattWrite(
    BondGATT.charAppCmd,
    [...b, for (var i = b.length; i < length; i++) 0],
  );

  /// 0x26 LgtVibCommand: `[ledId, mode, kind, 1, (100, steps u16LE)]`.
  GattWrite _lgtVib(
    int led, {
    required int mode,
    required int kind,
    (int, int)? timing,
  }) {
    final b = [...BondGATT.u16le(38), ..._next(), led, mode, kind, 1];
    if (timing != null) {
      b
        ..addAll(BondGATT.u16le(timing.$1))
        ..addAll(BondGATT.u16le(timing.$2));
    }
    return _frame(b, 16);
  }

  /// A touch (g()): one LgtVib per on/off entry — modes alternating 2, 1, … — then a
  /// closing frame (mode 2, kind 2, no timing).
  List<GattWrite> touch(List<int> onOff, int rgb) {
    final led = BondGATT.v1Led(rgb);
    final out = <GattWrite>[];
    var second = false;
    for (final ms in onOff) {
      final steps = (math.max(100, ms) * 10) ~/ led.steps;
      out.add(
        _lgtVib(
          led.id,
          mode: second ? 1 : 2,
          kind: 1,
          timing: (100, steps & 0xFFFF),
        ),
      );
      second = !second;
    }
    out.add(_lgtVib(led.id, mode: 2, kind: 2));
    return out;
  }

  /// 0x27 ActConfigCommand `[param u32LE, value u32LE]`.
  GattWrite _actConfig(int param, int value) => _frame([
    ...BondGATT.u16le(39),
    ..._next(),
    ...BondGATT.u32le(param),
    ...BondGATT.u32le(value),
  ], 16);

  /// The user's colour (f()): colour 1003, LED id 1006, then save (0x27, 1000, 8 bytes).
  List<GattWrite> userColor(int rgb) {
    final led = BondGATT.v1Led(rgb);
    final color = _actConfig(1003, BondGATT.v1Palette(led.id));
    final id = _actConfig(1006, led.id);
    final save = _frame([
      ...BondGATT.u16le(39),
      ..._next(),
      ...BondGATT.u32le(1000),
    ], 8);
    return [color, id, save];
  }

  /// 0x21 ColorCommand `[colour u32LE, with byte 7 = 100]`.
  GattWrite _color(int argb) {
    final b = [...BondGATT.u16le(33), ..._next(), ...BondGATT.u32le(argb)];
    b[7] = 100;
    return _frame(b, 16);
  }

  /// Shows a colour (y()).
  GattWrite previewColor(int rgb) =>
      _color(BondGATT.v1Palette(BondGATT.v1Led(rgb).id));

  /// LEDs off (h()).
  GattWrite colorOff() => _color(0);

  /// 0x25 DfuCommand (C()): `[0x25, 0, seq, 0xFFFFFFFF]`, 8 bytes — restarts the
  /// bracelet in its update bootloader.
  GattWrite enterUpdateMode() =>
      _frame([...BondGATT.u16le(37), ..._next(), 0xFF, 0xFF, 0xFF, 0xFF], 8);
}

/// v1 state (ffa4): `[bondEvent, pairedEvent, charging]` — paired 244 = waiting for the
/// AUID, 246 = connected, 247 = busy (message).
class V1State {
  const V1State._(this.paired, this.charging);
  final int paired;
  final int charging;

  static V1State? parse(List<int> b) {
    if (b.length < 3) return null;
    return V1State._(b[1], b[2]);
  }
}

/// v1 event (ffa5): `[id, counter, count u16LE, touchMs u16LE]` — 18 AUID error,
/// 19 paired signal, 20 touch (count 1 = first, 0xFFFE timeout, 0xFFFF end).
class V1Event {
  const V1Event._(this.id, this.count, this.touchMs);
  final int id;
  final int count;
  final int touchMs;

  static V1Event? parse(List<int> b) {
    if (b.length < 6) return null;
    return V1Event._(b[0], b[2] | b[3] << 8, b[4] | b[5] << 8);
  }
}

enum V3SlotState {
  inactive(0),
  active(1),
  ignore(2);

  const V3SlotState(this.raw);
  final int raw;

  static V3SlotState? fromRaw(int raw) {
    for (final s in values) {
      if (s.raw == raw) return s;
    }
    return null;
  }
}

/// One partner slot in the bracelet's menu: its colour lights the bar and marks which
/// partner a touch is from or to. A bracelet with no active slot shows no colours and
/// won't record a touch.
class V3Slot {
  const V3Slot(this.state, this.rgb);
  final V3SlotState state;
  final int rgb;

  static const inactive = V3Slot(V3SlotState.inactive, 0x000000);

  List<int> get bytes => [
    state.raw,
    (rgb >> 16) & 0xFF,
    (rgb >> 8) & 0xFF,
    rgb & 0xFF,
  ];

  @override
  bool operator ==(Object other) =>
      other is V3Slot && other.state == state && other.rgb == rgb;

  @override
  int get hashCode => Object.hash(state, rgb);
}

/// The bracelet's battery-alert settings, from the ack `[0x0A, 0x49, low %, R, G, B,
/// critical %, R, G, B]` (asked for by the `[1, 0x49, 1]` sent on CONNECTED).
class BatteryAlertSettings {
  const BatteryAlertSettings._(
    this.lowPercent,
    this.lowRGB,
    this.criticalPercent,
    this.criticalRGB,
  );
  final int lowPercent;
  final int lowRGB;
  final int criticalPercent;
  final int criticalRGB;

  static BatteryAlertSettings? fromV3Ack(List<int> b) {
    if (b.length < 10 || b[0] != 0x0A || b[1] != 0x49) return null;
    return BatteryAlertSettings._(
      b[2],
      (b[3] << 16) | (b[4] << 8) | b[5],
      b[6],
      (b[7] << 16) | (b[8] << 8) | b[9],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BatteryAlertSettings &&
      other.lowPercent == lowPercent &&
      other.lowRGB == lowRGB &&
      other.criticalPercent == criticalPercent &&
      other.criticalRGB == criticalRGB;

  @override
  int get hashCode =>
      Object.hash(lowPercent, lowRGB, criticalPercent, criticalRGB);
}

/// Reassembles a touch recorded on the Bond Touch More bar from FFB2 notifications:
/// a header `[slot 1…3, n, packets, …]` then `packets` × 20 sample bytes.
class V3Recording {
  int _expected = 0;
  int _slot = 1;
  List<int> _bytes = [];

  /// Feeds one FFB2 notification; when complete, returns the partner slot (1…3) the
  /// touch is for and its trimmed samples.
  ({int slot, List<int> samples})? feed(List<int> b) {
    if (_expected == 0) {
      if (b.length < 3 || b[0] < 1 || b[0] > 3 || b[2] < 1 || b[2] > 10) {
        return null;
      }
      _slot = b[0];
      _expected = b[2];
      _bytes = [];
      return null;
    }
    if (b.length < 20) {
      _expected = 0;
      _bytes = [];
      return null;
    }
    _bytes.addAll(b.take(20));
    _expected -= 1;
    if (_expected != 0) return null;
    final out = TouchPattern.trimmed(_bytes);
    _bytes = [];
    return out.isEmpty ? null : (slot: _slot, samples: out);
  }
}

/// A firmware version as the original compares them (FirmwareVersion): three numbers,
/// compared in order. A two-part string is a classic v1's "minor.patch" in hex ("2.60" =
/// 1.2.96); anything else is 0.0.0 — unknown, never offered an update.
class BondFirmwareVersion implements Comparable<BondFirmwareVersion> {
  const BondFirmwareVersion(this.major, this.minor, this.patch);
  final int major, minor, patch;

  factory BondFirmwareVersion.parse(String string) {
    // Swift's split(separator:) drops empty pieces.
    final parts = string.split('.').where((s) => s.isNotEmpty).toList();
    if (parts.length == 3) {
      final a = _int(parts[0], 10),
          b = _int(parts[1], 10),
          c = _int(parts[2], 10);
      if (a != null && b != null && c != null) {
        return BondFirmwareVersion(a, b, c);
      }
    } else if (parts.length == 2) {
      final b = _int(parts[0], 16), c = _int(parts[1], 16);
      if (b != null && c != null) return BondFirmwareVersion(1, b, c);
    }
    return const BondFirmwareVersion(0, 0, 0);
  }

  /// Swift `Int(_:radix:)`: an optional sign then digits only (no whitespace).
  static int? _int(String s, int radix) {
    final ok = radix == 16
        ? RegExp(r'^[+-]?[0-9a-fA-F]+$')
        : RegExp(r'^[+-]?[0-9]+$');
    return ok.hasMatch(s) ? int.tryParse(s, radix: radix) : null;
  }

  bool get isUnknown => major == 0 && minor == 0 && patch == 0;

  @override
  String toString() => '$major.$minor.$patch';

  @override
  int compareTo(BondFirmwareVersion o) {
    if (major != o.major) return major.compareTo(o.major);
    if (minor != o.minor) return minor.compareTo(o.minor);
    return patch.compareTo(o.patch);
  }

  bool operator <(BondFirmwareVersion o) => compareTo(o) < 0;
  bool operator >(BondFirmwareVersion o) => compareTo(o) > 0;
  bool operator <=(BondFirmwareVersion o) => compareTo(o) <= 0;
  bool operator >=(BondFirmwareVersion o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) =>
      other is BondFirmwareVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}

/// Bracelet models, as far as firmware recovery is concerned (one firmware per model).
enum BraceletModel {
  bondTouchMore,
  bondTouch,
  bondTouch4,
  bondMini;

  String get id => name;

  String get title {
    switch (this) {
      case bondTouchMore:
        return 'Bond Touch More';
      case bondTouch:
        return 'Bond Touch';
      case bondTouch4:
        return 'Bond Touch 4';
      case bondMini:
        return 'Bond Mini';
    }
  }

  /// The name the bracelet advertises when stuck in update mode.
  String get dfuName {
    switch (this) {
      case bondTouchMore:
        return 'BOND_M_DFU';
      case bondTouch:
        return 'BOND_DFU';
      case bondTouch4:
        return 'BOND_4_DFU';
      case bondMini:
        return 'BOND_MINI_DFU';
    }
  }

  /// A best guess from a firmware file's name (the official files are named after the
  /// model, e.g. `dfu_v3.1.1.zip` for the Bond Touch More).
  static BraceletModel? guess(String fileName) {
    final n = fileName.toUpperCase();
    if (n.contains('M_DFU') ||
        n.contains('MORE') ||
        n.contains('V3.1') ||
        n.contains('HW3G') ||
        n.contains('V311')) {
      return bondTouchMore;
    }
    if (n.contains('MINI')) return bondMini;
    if (n.contains('BOND_4') ||
        n.contains('DFU_4') ||
        n.contains('TOUCH 4') ||
        n.contains('HW4G')) {
      return bondTouch4;
    }
    if (n.contains('2G') ||
        n.contains('V279') ||
        n.contains('V260') ||
        n.contains('HW203') ||
        n.contains('BOND_DFU')) {
      return bondTouch;
    }
    return null;
  }
}
