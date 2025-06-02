import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';

// Conditional import for platform-specific implementations
// The 'impl' will provide top-level functions like createAppFileFromXFile, etc.
import 'app_file_mobile_impl.dart' if (dart.library.html) 'app_file_web_impl.dart' as impl;

abstract class AppFile {
  String get name;
  Future<Uint8List> readAsBytes();
  String? get path; // May be null, especially on web
  Future<int?> getLength(); // Asynchronously get length
  String? get mimeType; // Added mimeType getter to the interface

  // Factory constructors
  factory AppFile.fromXFile(XFile xFile) {
    // 'impl' refers to the conditionally imported file's namespace.
    // Functions like createAppFileFromXFile should be top-level in those impl files.
    return impl.createAppFileFromXFile(xFile);
  }

  static Future<AppFile> fromPlatformFile(PlatformFile platformFile) async {
    // On web, PlatformFile might have bytes directly or need conversion (e.g., if it's a path to a blob URL)
    // The web implementation (app_file_web_impl.dart) of createAppFileFromPlatformFile
    // will need to handle this, potentially by creating an XFile internally if necessary or reading bytes.
    if (kIsWeb) {
       // WebAppFile's constructor or a specific factory in app_file_web_impl.dart
       // should handle PlatformFile correctly.
       // Let's assume 'createAppFileFromPlatformFile' exists in both impls.
       return await impl.createAppFileFromPlatformFile(platformFile);
    } else {
      // MobileAppFile's constructor or a specific factory in app_file_mobile_impl.dart
      return await impl.createAppFileFromPlatformFile(platformFile);
    }
  }

  static Future<AppFile> fromPath(String path) async {
    // This will call the platform-specific 'createAppFileFromPath'
    return await impl.createAppFileFromPath(path);
  }

  static Future<AppFile> fromBytes(Uint8List bytes, String name, {String? mimeType, int? length}) async {
    // This will call the platform-specific 'createAppFileFromBytes'
    return await impl.createAppFileFromBytes(bytes, name, mimeType: mimeType, length: length);
  }
} 