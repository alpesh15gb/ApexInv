class FinancialAccount {
  final String id;
  final String name;
  final String type; // cash | bank
  final String institution;
  final String accountNumberMasked;
  final String ifsc;
  final String currencyCode;
  final String currencySymbol;
  final double openingBalance;
  final DateTime openingDate;
  final bool active;
  final String notes;

  const FinancialAccount({
    required this.id,
    required this.name,
    required this.type,
    this.institution = '',
    this.accountNumberMasked = '',
    this.ifsc = '',
    this.currencyCode = 'INR',
    this.currencySymbol = '₹',
    this.openingBalance = 0,
    required this.openingDate,
    this.active = true,
    this.notes = '',
  });

  factory FinancialAccount.fromMap(Map<String, dynamic> map) =>
      FinancialAccount(
        id: map['id'] as String,
        name: map['name'] as String? ?? '',
        type: map['type'] as String? ?? 'cash',
        institution: map['institution'] as String? ?? '',
        accountNumberMasked: map['account_number_masked'] as String? ?? '',
        ifsc: map['ifsc'] as String? ?? '',
        currencyCode: map['currency_code'] as String? ?? 'INR',
        currencySymbol: map['currency_symbol'] as String? ?? '₹',
        openingBalance:
            (map['opening_balance'] as num?)?.toDouble() ?? 0,
        openingDate: DateTime.tryParse(map['opening_date'] as String? ?? '') ??
            DateTime.now(),
        active: (map['active'] as int? ?? 1) == 1,
        notes: map['notes'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'type': type,
        'institution': institution,
        'account_number_masked': accountNumberMasked,
        'ifsc': ifsc,
        'currency_code': currencyCode,
        'currency_symbol': currencySymbol,
        'opening_balance': openingBalance,
        'opening_date': openingDate.toIso8601String(),
        'active': active ? 1 : 0,
        'notes': notes,
      };

  FinancialAccount copyWith({
    String? name,
    String? institution,
    String? accountNumberMasked,
    String? ifsc,
    bool? active,
    String? notes,
  }) =>
      FinancialAccount(
        id: id,
        name: name ?? this.name,
        type: type,
        institution: institution ?? this.institution,
        accountNumberMasked: accountNumberMasked ?? this.accountNumberMasked,
        ifsc: ifsc ?? this.ifsc,
        currencyCode: currencyCode,
        currencySymbol: currencySymbol,
        openingBalance: openingBalance,
        openingDate: openingDate,
        active: active ?? this.active,
        notes: notes ?? this.notes,
      );
}

class FinancialTransaction {
  final String id;
  final String accountId;
  final String? transferAccountId;
  final String kind;
  final double amount; // signed: receipts positive, payments negative
  final DateTime date;
  final String sourceType;
  final String sourceId;
  final String reference;
  final String notes;
  final String? reversalOf;
  final DateTime? voidedAt;

  const FinancialTransaction({
    required this.id,
    required this.accountId,
    this.transferAccountId,
    required this.kind,
    required this.amount,
    required this.date,
    required this.sourceType,
    required this.sourceId,
    this.reference = '',
    this.notes = '',
    this.reversalOf,
    this.voidedAt,
  });

  factory FinancialTransaction.fromMap(Map<String, dynamic> map) =>
      FinancialTransaction(
        id: map['id'] as String,
        accountId: map['account_id'] as String,
        transferAccountId: map['transfer_account_id'] as String?,
        kind: map['kind'] as String? ?? 'adjustment',
        amount: (map['amount'] as num?)?.toDouble() ?? 0,
        date: DateTime.parse(map['date'] as String),
        sourceType: map['source_type'] as String? ?? '',
        sourceId: map['source_id'] as String? ?? '',
        reference: map['reference'] as String? ?? '',
        notes: map['notes'] as String? ?? '',
        reversalOf: map['reversal_of'] as String?,
        voidedAt: DateTime.tryParse(map['voided_at'] as String? ?? ''),
      );
}

class ChequeRecord {
  final String id;
  final String direction; // received | issued
  final String partyName;
  final double amount;
  final String currencyCode;
  final String currencySymbol;
  final String chequeNumber;
  final DateTime chequeDate;
  final String status; // pending | deposited | cleared | bounced | cancelled
  final String sourceType;
  final String sourceId;
  final String? bankAccountId;
  final DateTime? depositedAt;
  final DateTime? clearedAt;
  final String notes;

  const ChequeRecord({
    required this.id,
    required this.direction,
    required this.partyName,
    required this.amount,
    this.currencyCode = 'INR',
    this.currencySymbol = '₹',
    required this.chequeNumber,
    required this.chequeDate,
    this.status = 'pending',
    required this.sourceType,
    required this.sourceId,
    this.bankAccountId,
    this.depositedAt,
    this.clearedAt,
    this.notes = '',
  });

  factory ChequeRecord.fromMap(Map<String, dynamic> map) => ChequeRecord(
        id: map['id'] as String,
        direction: map['direction'] as String,
        partyName: map['party_name'] as String? ?? '',
        amount: (map['amount'] as num?)?.toDouble() ?? 0,
        currencyCode: map['currency_code'] as String? ?? 'INR',
        currencySymbol: map['currency_symbol'] as String? ?? '₹',
        chequeNumber: map['cheque_number'] as String? ?? '',
        chequeDate: DateTime.parse(map['cheque_date'] as String),
        status: map['status'] as String? ?? 'pending',
        sourceType: map['source_type'] as String? ?? '',
        sourceId: map['source_id'] as String? ?? '',
        bankAccountId: map['bank_account_id'] as String?,
        depositedAt:
            DateTime.tryParse(map['deposited_at'] as String? ?? ''),
        clearedAt: DateTime.tryParse(map['cleared_at'] as String? ?? ''),
        notes: map['notes'] as String? ?? '',
      );
}

class LoanAccount {
  final String id;
  final String name;
  final String lender;
  final double originalPrincipal;
  final double annualInterestRate;
  final DateTime startDate;
  final DateTime? maturityDate;
  final String? disbursementAccountId;
  final String currencyCode;
  final String currencySymbol;
  final String status;
  final String notes;

  const LoanAccount({
    required this.id,
    required this.name,
    required this.lender,
    required this.originalPrincipal,
    this.annualInterestRate = 0,
    required this.startDate,
    this.maturityDate,
    this.disbursementAccountId,
    this.currencyCode = 'INR',
    this.currencySymbol = '₹',
    this.status = 'active',
    this.notes = '',
  });

  factory LoanAccount.fromMap(Map<String, dynamic> map) => LoanAccount(
        id: map['id'] as String,
        name: map['name'] as String? ?? '',
        lender: map['lender'] as String? ?? '',
        originalPrincipal:
            (map['original_principal'] as num?)?.toDouble() ?? 0,
        annualInterestRate:
            (map['annual_interest_rate'] as num?)?.toDouble() ?? 0,
        startDate: DateTime.parse(map['start_date'] as String),
        maturityDate:
            DateTime.tryParse(map['maturity_date'] as String? ?? ''),
        disbursementAccountId: map['disbursement_account_id'] as String?,
        currencyCode: map['currency_code'] as String? ?? 'INR',
        currencySymbol: map['currency_symbol'] as String? ?? '₹',
        status: map['status'] as String? ?? 'active',
        notes: map['notes'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'lender': lender,
        'original_principal': originalPrincipal,
        'annual_interest_rate': annualInterestRate,
        'start_date': startDate.toIso8601String(),
        'maturity_date': maturityDate?.toIso8601String(),
        'disbursement_account_id': disbursementAccountId,
        'currency_code': currencyCode,
        'currency_symbol': currencySymbol,
        'status': status,
        'notes': notes,
      };
}

class LoanMovement {
  final String id;
  final String loanId;
  final DateTime date;
  final String type; // drawdown | repayment | adjustment
  final double principalAmount;
  final double interestAmount;
  final double feeAmount;
  final String accountId;
  final String reference;
  final String notes;
  final DateTime? voidedAt;

  const LoanMovement({
    required this.id,
    required this.loanId,
    required this.date,
    required this.type,
    required this.principalAmount,
    this.interestAmount = 0,
    this.feeAmount = 0,
    required this.accountId,
    this.reference = '',
    this.notes = '',
    this.voidedAt,
  });

  factory LoanMovement.fromMap(Map<String, dynamic> map) => LoanMovement(
        id: map['id'] as String,
        loanId: map['loan_id'] as String,
        date: DateTime.parse(map['date'] as String),
        type: map['type'] as String,
        principalAmount:
            (map['principal_amount'] as num?)?.toDouble() ?? 0,
        interestAmount:
            (map['interest_amount'] as num?)?.toDouble() ?? 0,
        feeAmount: (map['fee_amount'] as num?)?.toDouble() ?? 0,
        accountId: map['account_id'] as String,
        reference: map['reference'] as String? ?? '',
        notes: map['notes'] as String? ?? '',
        voidedAt: DateTime.tryParse(map['voided_at'] as String? ?? ''),
      );
}
