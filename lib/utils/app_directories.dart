import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resilient app-documents lookup. Some Windows setups (OneDrive-redirected
/// or missing Documents shell library) make path_provider throw
/// MissingPlatformDirectoryException from getApplicationDocumentsDirectory —
/// fall back to the per-app support directory, which is always available on
/// desktop and correctly sandboxed on mobile.
Future<Directory> appDocumentsDirectorySafe() async {
  try {
    return await getApplicationDocumentsDirectory();
  } catch (_) {
    return getApplicationSupportDirectory();
  }
}
