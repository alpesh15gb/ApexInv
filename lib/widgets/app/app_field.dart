import 'package:flutter/material.dart';

import 'package:apexbooks/common/constants.dart';

/// Standard form field: outlined, radius 10, dense. Read-only/disabled
/// styling comes from the framework; pass `filled: true` for readonly
/// display fields (uses surfaceContainerHighest, matching invoice editor).
class AppTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? labelText;
  final String? hintText;
  final String? helperText;
  final String? errorText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool obscureText;
  final bool filled;
  final bool enabled;
  final int? maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;
  final FocusNode? focusNode;
  final bool autofocus;

  const AppTextField({
    super.key,
    this.controller,
    this.labelText,
    this.hintText,
    this.helperText,
    this.errorText,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.filled = false,
    this.enabled = true,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.validator,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        helperText: helperText,
        errorText: errorText,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        isDense: true,
        filled: filled,
        fillColor: filled
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppBorderRadius.xsmall),
        ),
      ),
      obscureText: obscureText,
      enabled: enabled,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      validator: validator,
      focusNode: focusNode,
      autofocus: autofocus,
    );
  }
}

/// Standard search field: dense outlined field with a search prefix icon,
/// matching the dominant list-screen pattern.
class AppSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const AppSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return AppTextField(
      controller: controller,
      hintText: hintText,
      prefixIcon: const Icon(Icons.search_rounded, size: 20),
      suffixIcon: onClear == null
          ? null
          : IconButton(
              icon: const Icon(Icons.clear_rounded, size: 18),
              onPressed: onClear,
            ),
      onChanged: onChanged,
    );
  }
}
