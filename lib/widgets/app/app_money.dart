import 'package:flutter/material.dart';

import 'package:apexbooks/utils/formatters.dart';

/// Standard money display. Single formatting path (grouped, 2 decimals)
/// fed by the owning model's currency symbol — replaces the hand-rolled
/// `'\$sym ${v.toStringAsFixed(2)}'` strings scattered across screens.
/// Display-only; never used in calculations.
class AppMoney extends StatelessWidget {
  final double amount;
  final String currencySymbol;
  final TextStyle? style;
  final bool bold;

  const AppMoney(
    this.amount, {
    super.key,
    required this.currencySymbol,
    this.style,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      AppFormatters.formatAmount(amount, currencySymbol),
      style: bold
          ? (style ?? const TextStyle()).copyWith(
              fontWeight: FontWeight.bold,
            )
          : style,
    );
  }
}
