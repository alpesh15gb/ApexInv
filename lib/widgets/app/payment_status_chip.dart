import 'package:flutter/material.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/widgets/adaptive/status_chip.dart';

/// Shared payment-status presentation for accounting lists and dashboards.
///
/// The widget keeps status meaning in text plus a semantic tone, so screens
/// no longer need local green/orange/red mappings.
class PaymentStatusChip extends StatelessWidget {
  final PaymentStatus status;

  const PaymentStatusChip({super.key, required this.status});

  static StatusTone toneFor(PaymentStatus status) {
    return switch (status) {
      PaymentStatus.paid => StatusTone.success,
      PaymentStatus.partial => StatusTone.warning,
      PaymentStatus.unpaid => StatusTone.danger,
    };
  }

  static String labelFor(BuildContext context, PaymentStatus status) {
    final l10n = AppLocalizations.of(context)!;
    return switch (status) {
      PaymentStatus.paid => l10n.paymentStatusPaid,
      PaymentStatus.partial => l10n.paymentStatusPartial,
      PaymentStatus.unpaid => l10n.paymentStatusUnpaid,
    };
  }

  @override
  Widget build(BuildContext context) {
    return StatusChip(
      label: labelFor(context, status),
      tone: toneFor(status),
    );
  }
}
