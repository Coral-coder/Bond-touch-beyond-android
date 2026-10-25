import 'package:uuid/uuid.dart';

/// A chat message (text, touch or photo) — the iPhone app's `ChatMessage`.
class ChatMessage {
  ChatMessage({
    String? id,
    required this.bondID,
    required this.senderID,
    this.kind = 'text',
    this.text = '',
    this.colorRGB = 0xFF4081,
    DateTime? sentAt,
    this.ringSeq,
  }) : id = id ?? const Uuid().v4().toUpperCase(),
       sentAt = sentAt ?? DateTime.now();

  final String id;
  final String bondID;
  final String senderID;
  final String kind;
  final String text;
  final int colorRGB;
  final DateTime sentAt;
  int? ringSeq;

  static const me = 'me';
  bool get mine => senderID == me;

  Map<String, Object?> toJson() => {
    'id': id,
    'bond': bondID,
    'sender': senderID,
    'kind': kind,
    'text': text,
    'color': colorRGB,
    'at': sentAt.millisecondsSinceEpoch,
    'seq': ringSeq,
  };
  factory ChatMessage.fromJson(Map<String, Object?> j) => ChatMessage(
    id: j['id'] as String,
    bondID: j['bond'] as String,
    senderID: j['sender'] as String,
    kind: j['kind'] as String? ?? 'text',
    text: j['text'] as String? ?? '',
    colorRGB: (j['color'] as num?)?.toInt() ?? 0xFF4081,
    sentAt: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
    ringSeq: (j['seq'] as num?)?.toInt(),
  );
}
