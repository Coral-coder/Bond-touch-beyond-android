/// A bond on the original Bond Touch backend: a partner, an invite you sent, or one you
/// received (`status` BONDED / REQUESTED / RECEIVED).
class Bond {
  Bond({
    required this.id,
    required this.partnerName,
    required this.email,
    required this.status,
    this.firebaseId = '',
  });

  final String id;
  String partnerName;
  final String email;
  final String status;
  final String firebaseId;

  bool get bonded => status == 'BONDED';
  bool get sent => status == 'REQUESTED';
  bool get received => status == 'RECEIVED';

  Map<String, Object?> toJson() => {
    'id': id,
    'name': partnerName,
    'email': email,
    'status': status,
    'uid': firebaseId,
  };

  factory Bond.fromJson(Map<String, Object?> j) => Bond(
    id: j['id'] as String,
    partnerName: j['name'] as String? ?? 'Partner',
    email: j['email'] as String? ?? '',
    status: j['status'] as String? ?? 'BONDED',
    firebaseId: j['uid'] as String? ?? '',
  );
}
