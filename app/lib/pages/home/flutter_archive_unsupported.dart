// Stub for flutter_archive when not on a supported platform (e.g., web)
// This is to satisfy conditional imports.

// Assuming 'File' and 'Directory' might come from 'dart:html' in this context,
// but flutter_archive's interface uses dart:io like types.
// For a stub, we might not need to perfectly match types if the code path is avoided by kIsWeb.

class ZipFile {
  static Future<void> extractToDirectory({
    required dynamic zipFile, // dart:io.File on mobile
    required dynamic destinationDir, // dart:io.Directory on mobile
    Function(dynamic zipEntry, double progress)? onExtracting,
  }) async {
    throw UnimplementedError('flutter_archive: ZipFile.extractToDirectory is not supported on this platform.');
  }
}

// Add any other classes/methods from flutter_archive that might be referenced
// in the conditionally excluded code paths. 