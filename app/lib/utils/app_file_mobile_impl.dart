import 'dart:io' as io;
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:image_picker/image_picker.dart'; // For XFile, to ensure consistency if an XFile needs to be wrapped on mobile
import 'package:file_picker/file_picker.dart'; // For PlatformFile
import 'package:path_provider/path_provider.dart'; // Import path_provider
import 'package:mime/mime.dart'; // For guessing mime type from path

import 'app_file.dart'; // Import the abstract class

// Mobile implementation using dart:io.File.
class MobileAppFile implements AppFile {
  final io.File _file;
  final Uint8List? _bytes; // Used if created from bytes and path isn't primary
  String? _nameOverride;
  int? _length; // Cache length if known (e.g., from bytes or after first read)
  String? _mimeType; // Added mimeType

  MobileAppFile._internalFromFile(this._file, {String? nameOverride, int? length, String? mimeType})
      : _bytes = null,
        _nameOverride = nameOverride,
        _length = length,
        _mimeType = mimeType ?? lookupMimeType(_file.path);

  // Constructor for when bytes are primary, but a temp file is created for path compatibility
  MobileAppFile._internalFromBytesAndTempFile(this._bytes, this._file, String name, {int? length, String? mimeType})
      : _nameOverride = name,
        _length = length ?? _bytes?.lengthInBytes,
        _mimeType = mimeType ?? lookupMimeType(_file.path, headerBytes: _bytes?.sublist(0, min(_bytes.length, 16)));

  @override
  String get name => _nameOverride ?? p.basename(_file.path);

  @override
  String get path => _file.path;

  // Implementation for the new mimeType getter
  String? get mimeType => _mimeType;

  @override
  Future<Uint8List> readAsBytes() async {
    if (_bytes != null) return _bytes!;
    return await _file.readAsBytes();
  }

  @override
  Future<int?> getLength() async {
    if (_length != null) return _length;
    if (_bytes != null) return _bytes!.lengthInBytes;
    if (await _file.exists()) {
      _length = await _file.length();
      return _length;
    }
    return null;
  }
}

// Top-level factory functions for mobile
AppFile createAppFileFromXFile(XFile xFile, {String? nameOverride}) {
  return MobileAppFile._internalFromFile(io.File(xFile.path), nameOverride: nameOverride ?? xFile.name, mimeType: xFile.mimeType);
}

Future<AppFile> createAppFileFromBytes(Uint8List bytes, String name, {String? mimeType, int? length}) async {
  final tempDir = await getTemporaryDirectory();
  final fileName = p.basename(name); 
  final tempFile = io.File('${tempDir.path}/$fileName');
  await tempFile.writeAsBytes(bytes, flush: true);
  return MobileAppFile._internalFromBytesAndTempFile(bytes, tempFile, name, length: length ?? bytes.lengthInBytes, mimeType: mimeType);
}

Future<AppFile> createAppFileFromPlatformFile(PlatformFile platformFile) async {
  if (platformFile.path != null) {
    // If path is available (typical for mobile), use it.
    return MobileAppFile._internalFromFile(io.File(platformFile.path!), nameOverride: platformFile.name, length: platformFile.size, mimeType: lookupMimeType(platformFile.path!));
  } else if (platformFile.bytes != null) {
    // If only bytes are available, create a temporary file.
    return await createAppFileFromBytes(platformFile.bytes!, platformFile.name, length: platformFile.size, mimeType: lookupMimeType(platformFile.name, headerBytes: platformFile.bytes!.sublist(0, min(platformFile.bytes!.length, 16)) ) );
  } else {
    throw Exception("PlatformFile on mobile must have either a path or bytes.");
  }
}

Future<AppFile> createAppFileFromPath(String filePath, {String? nameOverride}) async {
  return MobileAppFile._internalFromFile(io.File(filePath), nameOverride: nameOverride);
}

// Helper to get min of two integers, as math.min is for num
int min(int a, int b) => a < b ? a : b; 