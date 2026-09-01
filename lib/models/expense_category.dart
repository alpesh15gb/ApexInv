class ExpenseCategory {
  final String id;
  final String name;

  const ExpenseCategory({
    required this.id,
    required this.name,
  });

  factory ExpenseCategory.fromMap(Map<String, dynamic> map) {
    return ExpenseCategory(
      id: map['id']?.toString() ?? '',
      name: map['name'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
    };
  }

  static const List<ExpenseCategory> defaults = [
    ExpenseCategory(id: 'cat-rent', name: 'Rent'),
    ExpenseCategory(id: 'cat-salary', name: 'Salary'),
    ExpenseCategory(id: 'cat-transport', name: 'Transport'),
    ExpenseCategory(id: 'cat-utilities', name: 'Utilities'),
    ExpenseCategory(id: 'cat-office', name: 'Office Supplies'),
    ExpenseCategory(id: 'cat-marketing', name: 'Marketing'),
    ExpenseCategory(id: 'cat-maintenance', name: 'Maintenance'),
    ExpenseCategory(id: 'cat-other', name: 'Other'),
  ];

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ExpenseCategory && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
