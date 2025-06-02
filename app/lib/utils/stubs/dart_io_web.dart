// Stub for dart:io types when targeting web.
// These classes and methods throw UnimplementedError because dart:io is not available on the web.
// This file is used via conditional import to allow code that uses dart:io types (guarded by !kIsWeb)
// to compile for the web target.

import 'dart:typed_data'; // For Uint8List

class File {
  final String path;

  File(this.path) {
    // Allow instantiation, but operations will throw.
  }

  Future<Uint8List> readAsBytes() async {
    throw UnimplementedError('File.readAsBytes is not supported on web.');
  }

  Future<String> readAsString() async {
    throw UnimplementedError('File.readAsString is not supported on web.');
  }

  Future<File> writeAsBytes(List<int> bytes, {bool flush = false}) async {
    throw UnsupportedError('File.writeAsBytes is not supported on web.');
  }

  Future<bool> exists() async {
    throw UnsupportedError('File.exists is not supported on web.');
  }

  Future<File> create({bool recursive = false}) async {
    throw UnsupportedError('File.create is not supported on web.');
  }

  Future<FileSystemEntity> delete({bool recursive = false}) async {
    throw UnsupportedError('File.delete is not supported on web.');
  }

  bool existsSync() {
    throw UnsupportedError('File.existsSync is not supported on web.');
  }

  void deleteSync({bool recursive = false}) {
    throw UnsupportedError('File.deleteSync is not supported on web.');
  }

  Future<int> length() async {
    throw UnsupportedError('File.length is not supported on web.');
  }

  Stream<List<int>> openRead([int? start, int? end]) {
    throw UnsupportedError('File.openRead is not supported on web.');
  }

  // Add other frequently used File members as needed, all throwing UnimplementedError.
}

class Directory {
  final String path;

  Directory(this.path) {
    // Allow instantiation.
  }

  Future<Directory> create({bool recursive = false}) async {
    throw UnimplementedError('Directory.create is not supported on web.');
  }

  Future<bool> exists() async {
    throw UnimplementedError('Directory.exists is not supported on web.');
  }

  bool existsSync() {
    throw UnimplementedError('Directory.existsSync is not supported on web.');
  }

  Future<FileSystemEntity> delete({bool recursive = false}) async {
    throw UnimplementedError('Directory.delete is not supported on web.');
  }

  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) {
    throw UnimplementedError('Directory.list is not supported on web.');
  }

  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) {
    throw UnimplementedError('Directory.listSync is not supported on web.');
  }

  // Add other frequently used Directory members as needed.
}

class FileMode {
  static const FileMode read = FileMode._internal('read');
  static const FileMode write = FileMode._internal('write');
  static const FileMode append = FileMode._internal('append');
  static const FileMode writeOnly = FileMode._internal('writeOnly');
  static const FileMode writeOnlyAppend = FileMode._internal('writeOnlyAppend');
  
  final String _name;
  const FileMode._internal(this._name);

  @override
  String toString() => 'FileMode.$_name';
}

// Generic FileSystemEntity stub if needed by method signatures
abstract class FileSystemEntity {
  String get path;
  Future<bool> exists();
  bool existsSync();
  Future<FileSystemEntity> delete({bool recursive = false});
  // Add other common methods/properties if compilation errors point to them.
}

// Define Platform for web stub
class Platform {
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isLinux => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isFuchsia => false;

  static String get operatingSystem {
    // This should not be called on web due to kIsWeb guards, 
    // but returning a default helps avoid analysis errors if direct calls exist.
    // However, the primary use (isIOS, isAndroid etc.) is what needs to be stubbed.
    // For code like `if (!kIsWeb && Platform.isIOS)`, this getter won't be hit on web.
    // If someone *only* wrote `Platform.operatingSystem` without a `kIsWeb` guard,
    // that would be an issue, but we are fixing specific guarded call sites.
    // To be absolutely safe for direct calls (which is bad practice without kIsWeb):
    throw UnsupportedError('Platform.operatingSystem is not supported on web. Use kIsWeb.');
  }
  // Add other Platform members if other errors appear
}

// Helper function if needed, e.g. for HttpStatus
// class HttpStatus {
//   static const int ok = 200;
//   // Add other status codes as needed
// }

// Minimal Uint8List if not already available via dart:typed_data
// (It should be, but as an example if a core type was missing)
// typedef Uint8List = List<int>; 