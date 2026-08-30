class Expense {
  final String id;
  final String description;
  final double amount;
  final DateTime date;
  final String categoryId;
  final String? categoryName;
  final String? paymentMethod;
  final String? notes;

  const Expense({
    required this.id,
    required this.description,
    required this.amount,
    required this.date,
    required this.categoryId,
    this.categoryName,
    this.paymentMethod,
    this.notes,
  });

  factory Expense.fromMap(Map<String, dynamic> map) {
    return Expense(
      id: map['id']?.toString() ?? '',
      description: map['description'] ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      date: map['date'] != null ? DateTime.parse(map['date']) : DateTime.now(),
      categoryId: map['category_id']?.toString() ?? '',
      categoryName: map['category_name'] as String?,
      paymentMethod: map['payment_method'] as String?,
      notes: map['notes'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'description': description,
      'amount': amount,
      'date': date.toIso8601String(),
      'category_id': categoryId,
      'payment_method': paymentMethod,
      'notes': notes,
    };
  }

  Expense copyWith({
    String? id,
    String? description,
    double? amount,
    DateTime? date,
    String? categoryId,
    String? categoryName,
    String? paymentMethod,
    String? notes,
  }) {
    return Expense(
      id: id ?? this.id,
      description: description ?? this.description,
      amount: amount ?? this.amount,
      date: date ?? this.date,
      categoryId: categoryId ?? this.categoryId,
      categoryName: categoryName ?? this.categoryName,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      notes: notes ?? this.notes,
    );
  }
}
