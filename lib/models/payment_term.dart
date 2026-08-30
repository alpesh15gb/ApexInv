class PaymentTerm {
  final String id;
  final String name;
  final int days;
  final bool isDefault;

  const PaymentTerm({
    required this.id,
    required this.name,
    required this.days,
    this.isDefault = false,
  });

  factory PaymentTerm.fromMap(Map<String, dynamic> map) {
    return PaymentTerm(
      id: map['id']?.toString() ?? '',
      name: map['name'] ?? '',
      days: map['days'] ?? 0,
      isDefault: (map['is_default'] ?? 0) == 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'days': days,
      'is_default': isDefault ? 1 : 0,
    };
  }

  PaymentTerm copyWith({
    String? id,
    String? name,
    int? days,
    bool? isDefault,
  }) {
    return PaymentTerm(
      id: id ?? this.id,
      name: name ?? this.name,
      days: days ?? this.days,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  @override
  String toString() => '$name ($days days)';
}
