import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// ApexBooks brand lockup: neutral bill-check mark + wordmark text.
/// Adapts to light/dark via theme (no light/dark PNG ternary needed).
class AppBrandLogo extends StatelessWidget {
  final double height;
  final bool showWordmark;

  const AppBrandLogo({super.key, this.height = 72, this.showWordmark = true});

  @override
  Widget build(BuildContext context) {
    final double iconSize = showWordmark ? height * 0.72 : height;
    final double fontSize = height * 0.32;
    final double radius = iconSize * 0.22;
    final Widget icon = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SvgPicture.asset(
        'assets/images/logo_b.svg',
        width: iconSize,
        height: iconSize,
        fit: BoxFit.cover,
      ),
    );
    if (!showWordmark) return icon;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        icon,
        SizedBox(width: height * 0.16),
        Flexible(
          child: Text(
            'ApexBooks',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}
