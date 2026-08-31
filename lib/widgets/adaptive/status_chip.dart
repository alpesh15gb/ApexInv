import 'package:flutter/material.dart';

enum StatusTone { success, warning, danger, info, neutral }

/// Small tonal status chip (Paid / Overdue / Draft / Partial ...) matching the
/// mobile design system: soft container background with a strong label color.
class StatusChip extends StatelessWidget {
  final String label;
  final StatusTone tone;

  const StatusChip({
    super.key,
    required this.label,
    this.tone = StatusTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = _colors(Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }

  (Color, Color) _colors(Brightness brightness) {
    const light = <StatusTone, (Color, Color)>{
      StatusTone.success: (Color(0xFFE3F3E8), Color(0xFF0F7B3B)),
      StatusTone.warning: (Color(0xFFFDF0DC), Color(0xFF9A6200)),
      StatusTone.danger: (Color(0xFFFCE8E8), Color(0xFFB3261E)),
      StatusTone.info: (Color(0xFFE3EDFB), Color(0xFF1A5CB8)),
      StatusTone.neutral: (Color(0xFFEEF1F4), Color(0xFF5A6572)),
    };
    const dark = <StatusTone, (Color, Color)>{
      StatusTone.success: (Color(0xFF103B22), Color(0xFF7BD89A)),
      StatusTone.warning: (Color(0xFF4A3305), Color(0xFFF2C879)),
      StatusTone.danger: (Color(0xFF4A1D1B), Color(0xFFF2B8B5)),
      StatusTone.info: (Color(0xFF173254), Color(0xFF9FC4F8)),
      StatusTone.neutral: (Color(0xFF2A2D31), Color(0xFFB4BAC2)),
    };
    return (brightness == Brightness.dark ? dark : light)[tone]!;
  }
}
