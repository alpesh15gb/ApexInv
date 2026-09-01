class CustomField {
  final String id;
  final String displayName;
  final String type; // 'text', 'number', 'date'
  final bool enabled;

  const CustomField({
    required this.id,
    required this.displayName,
    this.type = 'text',
    this.enabled = true,
  });

  factory CustomField.fromMap(Map<String, dynamic> map) {
    return CustomField(
      id: map['id']?.toString() ?? '',
      displayName: map['display_name'] ?? '',
      type: map['type'] ?? 'text',
      enabled: (map['enabled'] ?? 1) == 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'display_name': displayName,
      'type': type,
      'enabled': enabled ? 1 : 0,
    };
  }

  CustomField copyWith({
    String? id,
    String? displayName,
    String? type,
    bool? enabled,
  }) {
    return CustomField(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      type: type ?? this.type,
      enabled: enabled ?? this.enabled,
    );
  }

  @override
  String toString() => displayName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CustomField && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Stores custom field values attached to a specific transaction (invoice).
class CustomFieldValue {
  final String fieldId;
  final String value;

  const CustomFieldValue({
    required this.fieldId,
    required this.value,
  });

  factory CustomFieldValue.fromMap(Map<String, dynamic> map) {
    return CustomFieldValue(
      fieldId: map['field_id'] ?? '',
      value: map['value'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'field_id': fieldId,
      'value': value,
    };
  }
}
