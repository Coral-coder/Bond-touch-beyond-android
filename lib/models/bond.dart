/// A pairing with one partner, named by its secret invite code (never stored online).
/// `isOwner`: this phone created the invite (role A); the partner joined it (role B).
class Bond {
  Bond({
    required this.code,
    required this.partnerName,
    required this.isOwner,
    this.pending = false,
  });

  final String code;
  String partnerName;
  final bool isOwner;

  /// An invite we created that nobody has joined yet.
  bool pending;

  String get id => code;
  String get myRole => isOwner ? 'A' : 'B';
  String get theirRole => isOwner ? 'B' : 'A';

  Map<String, Object?> toJson() => {
    'code': code,
    'name': partnerName,
    'owner': isOwner,
    'pending': pending,
  };
  factory Bond.fromJson(Map<String, Object?> j) => Bond(
    code: j['code'] as String,
    partnerName: j['name'] as String? ?? 'Partner',
    isOwner: j['owner'] as bool? ?? false,
    pending: j['pending'] as bool? ?? false,
  );

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no O/0/I/1

  static String newCode(int Function(int max) random) =>
      List.generate(8, (_) => _alphabet[random(_alphabet.length)]).join();

  static String normalize(String code) =>
      code.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

  /// Same link format as the iPhone app.
  static String inviteLink(String code) =>
      'bondtouchbeyond://join?code=$code&via=fb';

  static String? codeFromLink(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'bondtouchbeyond' || uri.host != 'join') {
      return null;
    }
    final code = uri.queryParameters['code'];
    return code == null || code.isEmpty ? null : normalize(code);
  }
}
