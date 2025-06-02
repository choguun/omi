import 'dart:typed_data';
import 'package:image_picker/image_picker.dart'; // For XFile type, though we primarily use its data
import 'package:file_picker/file_picker.dart'; // For PlatformFile
import 'package:path/path.dart' as p; // For basename, if needed from XFile.path (though path is often fake on web)

import 'app_file.dart'; // Import the abstract class

// Web implementation using XFile or Uint8List directly.
class WebAppFile implements AppFile {
  final Uint8List? _bytes;
  final XFile? _xFile; // Keep XFile if it provides an easier way to get bytes or already has them.
  @override
  final String name;
  final int? _length;
  final String? _mimeType; // Added mimeType

  WebAppFile._internalFromXFile(this._xFile, {String? nameOverride, String? mimeType})
      : _bytes = null,
        name = nameOverride ?? _xFile!.name, 
        _length = null, // Length from XFile might need async read, so handle in getLength
        _mimeType = mimeType ?? _xFile?.mimeType;

  WebAppFile._internalFromBytes(this._bytes, this.name, {int? length, String? mimeType})
      : _xFile = null,
        _length = length,
        _mimeType = mimeType;

  WebAppFile._internalFromPlatformFile(PlatformFile platformFile)
      : _bytes = platformFile.bytes, 
        _xFile = null, // We'll prioritize bytes from PlatformFile for web if available
        name = platformFile.name,
        _length = platformFile.size,
        _mimeType = null; // PlatformFile doesn't directly expose mimeType in a consistent way for web XFile might be needed

  @override
  String? get path => _xFile?.path; // XFile path on web is often a blob URL or not a real fs path.

  // Implementation for the new mimeType getter
  String? get mimeType => _mimeType ?? _xFile?.mimeType;

  @override
  Future<Uint8List> readAsBytes() async {
    if (_bytes != null) return _bytes!;
    if (_xFile != null) return await _xFile!.readAsBytes();
    throw Exception("No data source (bytes or XFile) for WebAppFile");
  }

  @override
  Future<int?> getLength() async {
    if (_length != null) return _length; // If length was provided upfront
    if (_bytes != null) return _bytes!.lengthInBytes;
    if (_xFile != null) {
      // XFile.length() is async, so we await it here.
      try {
        return await _xFile!.length();
      } catch (e) {
        // If XFile.length() fails (e.g., for some XFile sources on web),
        // we might fall back to reading bytes and getting length, but that's less efficient.
        // For now, return null or rethrow.
        print("Error getting length from XFile on web: $e");
        return null;
      }
    }
    return null;
  }
}

// Top-level factory functions for web
AppFile createAppFileFromXFile(XFile xFile, {String? nameOverride}) {
  return WebAppFile._internalFromXFile(xFile, nameOverride: nameOverride, mimeType: xFile.mimeType);
}

Future<AppFile> createAppFileFromBytes(Uint8List bytes, String name, {String? mimeType, int? length}) async {
  return WebAppFile._internalFromBytes(bytes, name, length: length, mimeType: mimeType);
}

Future<AppFile> createAppFileFromPlatformFile(PlatformFile platformFile) async {
  // For web, PlatformFile often has bytes directly. If not, it might have a path (blob URL).
  // If bytes are available, use them. Otherwise, an XFile might be needed if path is the only option.
  if (platformFile.bytes != null) {
    return WebAppFile._internalFromBytes(platformFile.bytes!, platformFile.name, length: platformFile.size);
  } else if (platformFile.path != null) {
    // If only path is available, create an XFile from it. This is common for drag-and-drop.
    // Note: XFile.mimeType might not be reliable from a blob URL path alone.
    final xFile = XFile(platformFile.path!, name: platformFile.name, length: platformFile.size);
    return WebAppFile._internalFromXFile(xFile, mimeType: await xFile.mimeType); 
  } else {
    throw Exception("PlatformFile on web must have either bytes or a path.");
  }
}

Future<AppFile> createAppFileFromPath(String path, {String? nameOverride}) async {
  // Direct file system access by path is not typical/reliable on web.
  // This might represent a URL. If so, data should be fetched.
  // For simplicity, assuming this means creating an XFile from a (potentially blob) path.
  final xFile = XFile(path, name: nameOverride);
  return WebAppFile._internalFromXFile(xFile, nameOverride: nameOverride, mimeType: await xFile.mimeType);
}

// This is not typically used on web as direct path access is limited.
// If needed, it would imply fetching content from a URL or similar, not direct file system access. 