/// GSTIN validation (warn-only helper).
///
/// Format: 15 chars — 2-digit state code (01-38) + 10-char PAN
/// ([A-Z]{5}[0-9]{4}[A-Z]) + 1-char entity code ([0-9A-Z]) + 'Z' +
/// 1-char checksum ([0-9A-Z]). Checksum uses the standard GSTIN
/// Luhn-like mod-36 algorithm over the first 14 characters.
bool isValidGstin(String? input) {
  if (input == null) return false;
  final gstin = input.trim().toUpperCase();
  if (gstin.length != 15) return false;
  if (!RegExp(r'^[0-9A-Z]{15}$').hasMatch(gstin)) return false;

  // State code 01-38.
  final stateCode = int.tryParse(gstin.substring(0, 2));
  if (stateCode == null || stateCode < 1 || stateCode > 38) return false;

  // PAN pattern.
  if (!RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$').hasMatch(gstin.substring(2, 12))) {
    return false;
  }

  // Entity code + constant 'Z'.
  if (!RegExp(r'^[0-9A-Z]$').hasMatch(gstin[12])) return false;
  if (gstin[13] != 'Z') return false;

  return _verifyChecksum(gstin);
}

const _charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

bool _verifyChecksum(String gstin) {
  var factor = 2;
  var sum = 0;
  // Standard GSTIN checksum: first 14 chars left-to-right, alternating
  // factors 2,1,2,1...; digit = (p ~/ 36) + (p % 36); check digit makes
  // the total mod 36 == 0.
  for (var i = 0; i < 14; i++) {
    final codePoint = _charset.indexOf(gstin[i]);
    if (codePoint < 0) return false;
    var digit = factor * codePoint;
    factor = factor == 2 ? 1 : 2;
    digit = (digit ~/ 36) + (digit % 36);
    sum += digit;
  }
  final checkCodePoint = (36 - (sum % 36)) % 36;
  return _charset[checkCodePoint] == gstin[14];
}
