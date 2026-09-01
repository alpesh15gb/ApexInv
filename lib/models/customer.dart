// Data Models
class Customer {
  String id;
  String name;
  String email;
  String phone;
  String address;
  String gstin;
  String businessName;
  double creditLimit;
  bool creditLimitEnabled;
  String paymentTermId;

  Customer({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    required this.address,
    required this.gstin,
    this.businessName = '',
    this.creditLimit = 0,
    this.creditLimitEnabled = false,
    this.paymentTermId = '',
  });

  // Convert a Map into a Customer object
  factory Customer.fromMap(Map<String, dynamic> map) {
    return Customer(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      phone: map['phone'] ?? '',
      address: map['address'] ?? '',
      gstin: map['gstin'] ?? '',
      businessName: map['business_name'] ?? '',
      creditLimit: (map['credit_limit'] as num?)?.toDouble() ?? 0,
      creditLimitEnabled: (map['credit_limit_enabled'] ?? 0) == 1,
      paymentTermId: map['payment_term_id'] ?? '',
    );
  }

  // Convert a Customer object into a Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'phone': phone,
      'address': address,
      'gstin': gstin,
      'business_name': businessName,
      'credit_limit': creditLimit,
      'credit_limit_enabled': creditLimitEnabled ? 1 : 0,
      'payment_term_id': paymentTermId,
    };
  }
}
