// Stub for path_provider for web environments

//ignore_for_file: unused_element

import 'dart:async';
// Use the more general stub path if Directory is defined there
import 'package:omi/utils/stubs/dart_io_web.dart'; 

Future<Directory> getTemporaryDirectory() async {
  // Web doesn't have a direct equivalent. Return a dummy/root-like path or throw.
  print('[path_provider_web] getTemporaryDirectory called');
  return Directory('web_temp');
}

Future<Directory> getApplicationDocumentsDirectory() async {
  // Web doesn't have a direct equivalent. Return a dummy/root-like path or throw.
  // For compatibility, returning a dummy Directory object.
  print('[path_provider_web] getApplicationDocumentsDirectory called');
  return Directory('web_documents');
}

Future<Directory?> getExternalStorageDirectory() async {
  throw UnsupportedError("getExternalStorageDirectory() is not supported on web.");
}

// Add other path_provider functions if they are used and need stubbing. 

// Add stubs for any other path_provider functions your app uses on mobile.
// For example:
// Future<Directory?> getExternalStorageDirectory() async => null;
// Future<List<Directory>?> getExternalCacheDirectories() async => [];
// Future<String?> getDownloadsPath() async => null; 