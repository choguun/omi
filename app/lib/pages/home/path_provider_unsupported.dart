// Stub for path_provider when not on a supported platform (e.g., web)

Future<dynamic> getTemporaryDirectory() async {
  throw UnimplementedError('path_provider: getTemporaryDirectory is not supported on this platform.');
}

Future<dynamic> getApplicationDocumentsDirectory() async {
  throw UnimplementedError('path_provider: getApplicationDocumentsDirectory is not supported on this platform.');
}

// Add any other functions/classes from path_provider that might be referenced. 