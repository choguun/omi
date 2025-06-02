import 'dart:async';
import 'dart:typed_data' show Uint8List; // Ensure Uint8List is properly typed

// Basic Stubs for dart:io elements commonly used with files
// These are minimal and may need expansion based on actual usage by other packages

class FileSystemDeleteEvent {
  final String path;
  final bool isDirectory;
  FileSystemDeleteEvent(this.path, this.isDirectory);
}

class FileSystemCreateEvent {
  final String path;
  final bool isDirectory;
  FileSystemCreateEvent(this.path, this.isDirectory);
}

class FileSystemModifyEvent {
  final String path;
  final bool isDirectory;
  final bool contentChanged;
  FileSystemModifyEvent(this.path, this.isDirectory, this.contentChanged);
}

class FileSystemMoveEvent {
  final String path;
  final bool isDirectory;
  final String? destination;
  FileSystemMoveEvent(this.path, this.isDirectory, this.destination);
}

abstract class FileSystemEvent {
  static const int create = 1;
  static const int modify = 2;
  static const int delete = 4;
  static const int move = 8;
  static const int all = 15;

  final int type;
  final String path;
  final bool isDirectory;

  FileSystemEvent(this.type, this.path, this.isDirectory);
}


class FileStat {
  final DateTime changed;
  final DateTime modified;
  final DateTime accessed;
  final FileSystemEntityType type;
  final int mode;
  final int size;

  FileStat(this.changed, this.modified, this.accessed, this.type, this.mode, this.size);

  static FileStat statSync(String path) {
    return FileStat(DateTime(0), DateTime(0), DateTime(0), FileSystemEntityType.notFound, 0, -1);
  }
  static Future<FileStat> stat(String path) async {
    return FileStat(DateTime(0), DateTime(0), DateTime(0), FileSystemEntityType.notFound, 0, -1);
  }
}

enum FileSystemEntityType {
  file, directory, link, notFound,
  // ignore: constant_identifier_names
  unixDomainSocket, 
  // ignore: constant_identifier_names
  pipe,
  // ignore: constant_identifier_names
  eventfd,
  // ignore: constant_identifier_names
  signalfd,
  // ignore: constant_identifier_names
  timerfd,
  // ignore: constant_identifier_names
  inotifyfd,
  // ignore: constant_identifier_names
  pidfd,
  // ignore: constant_identifier_names
  dev,
  // ignore: constant_identifier_names
  charDevice,
  // ignore: constant_identifier_names
  blockDevice,
  // ignore: constant_identifier_names
  fifo,
  // ignore: constant_identifier_names
  socket,
  // ignore: constant_identifier_names
  mount,
  // ignore: constant_identifier_names
  overlay,
  // ignore: constant_identifier_names
  proc,
  // ignore: constant_identifier_names
  sys,
  // ignore: constant_identifier_names
  tmp,
  // ignore: constant_identifier_names
  unknown,
}


abstract class FileSystemEntity {
  String get path;
  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<FileSystemEntity> delete({bool recursive = false}) async => this;
  void deleteSync({bool recursive = false}) {}
  Future<String> resolveSymbolicLinks() async => path;
  String resolveSymbolicLinksSync() => path;
  Future<FileStat> stat() async => FileStat.statSync(path); // Provide a default future
  FileStat statSync() => FileStat.statSync(path);

  Uri get uri => Uri.file(path);
  bool get isAbsolute => path.startsWith('/'); // Simplified
  FileSystemEntity get parent => Directory(path.substring(0, path.lastIndexOf('/'))); // Simplified

  static Future<bool> identical(String path1, String path2) async => false;
  static bool identicalSync(String path1, String path2) => false;
  static Future<FileSystemEntityType> type(String path, {bool followLinks = true}) async => FileSystemEntityType.notFound;
  static FileSystemEntityType typeSync(String path, {bool followLinks = true}) => FileSystemEntityType.notFound;
  static Future<bool> isLink(String path) async => false;
  static Future<bool> isFile(String path) async => false;
  static Future<bool> isDirectory(String path) async => false;
  static bool isLinkSync(String path) => false;
  static bool isFileSync(String path) => false;
  static bool isDirectorySync(String path) => false;
   Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) => Stream.empty();
}

class File extends FileSystemEntity {
  @override
  final String path;
  File(this.path);

  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async => this;
  Future<Uint8List> readAsBytes() async => Uint8List(0);
  @override
  Future<bool> exists() async => false; // Explicit override
  @override
  bool existsSync() => false; // Explicit override
  
  Future<int> length() async => 0;
  int lengthSync() => 0;

  Stream<List<int>> openRead([int? start, int? end]) => Stream.empty();
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) => _DummyIOSink();
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async => _DummyRandomAccessFile(path);
  Future<DateTime> lastModified() async => DateTime(0);
  DateTime lastModifiedSync() => DateTime(0);
  Future<File> copy(String newPath) async => File(newPath);
  File copySync(String newPath) => File(newPath);
  Future<File> create({bool recursive = false, bool exclusive = false}) async => this;
  void createSync({bool recursive = false, bool exclusive = false}) {}
  Future<File> rename(String newPath) async => File(newPath);
  File renameSync(String newPath) => File(newPath);
  String readAsStringSync({Encoding encoding = utf8}) => '';
  Future<String> readAsString({Encoding encoding = utf8}) async => '';
  List<String> readAsLinesSync({Encoding encoding = utf8}) => [];
  Future<List<String>> readAsLines({Encoding encoding = utf8}) async => [];
  Future<File> writeAsString(String contents, {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false}) async => this;
  void writeAsStringSync(String contents, {FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false}) {}
  void writeAsBytesSync(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) {}

  @override
  Future<File> delete({bool recursive = false}) async => this; // Ensure File type
  @override
  void deleteSync({bool recursive = false}) {} // Ensure File type
}

class Directory extends FileSystemEntity {
  @override
  final String path;
  Directory(this.path);

  @override
  Future<bool> exists() async => false; // Explicit override
  @override
  bool existsSync() => false; // Explicit override

  Future<Directory> create({bool recursive = false}) async => this;
  void createSync({bool recursive = false}) {}

  @override
  Future<Directory> delete({bool recursive = false}) async => this; // Ensure Directory type
  @override
  void deleteSync({bool recursive = false}) {} // Ensure Directory type
  
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) => Stream.empty();
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) => [];

  Future<Directory> rename(String newPath) async => Directory(newPath);
  Directory renameSync(String newPath) => Directory(newPath);
  Future<Directory> createTemp([String? prefix]) async => Directory('${path}/${prefix ?? ""}temp');
  Directory createTempSync([String? prefix]) => Directory('${path}/${prefix ?? ""}temp');

  String get absolute => path; // Simplified
}

// --- Stubs for related classes often used with dart:io file operations ---

// FileMode enum (already defined in dart:io, ensure it's available if not importing full dart:io)
enum FileMode { read, write, append, writeOnly, writeOnlyAppend }

// Encoding and utf8 (placeholders, real dart:convert is usually available)
abstract class Encoding {
  const Encoding();
  // Minimal methods needed by stubs or common usage
  List<int> encode(String input);
  String decode(List<int> encoded);
}

class Utf8Codec extends Encoding {
  const Utf8Codec();
  @override
  List<int> encode(String input) => input.codeUnits; // Simplified
  @override
  String decode(List<int> encoded) => String.fromCharCodes(encoded); // Simplified
}
const utf8 = Utf8Codec();


// IOSink and related (minimal stubs)
abstract class IOSink implements StreamSink<List<int>> {
  Encoding encoding = utf8;
  void write(Object? obj);
  void writeAll(Iterable objects, [String separator = ""]);
  void writeln([Object? obj = ""]);
  void writeCharCode(int charCode);

  // From StreamSink
  @override
  void add(List<int> data);
  @override
  void addError(Object error, [StackTrace? stackTrace]);
  @override
  Future addStream(Stream<List<int>> stream);
  @override
  Future flush();
  @override
  Future close();
  @override
  Future get done;
}

class _DummyIOSink implements IOSink {
  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable objects, [String separator = ""]) {}
  @override
  void writeln([Object? object = ""]) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void addError(error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<List<int>> stream) => Future.value();
  @override
  Future flush() => Future.value();
  @override
  Future close() => Future.value();
  @override
  Future get done => Future.value();
}

// RandomAccessFile (minimal stub)
enum FileLock { shared, exclusive, blockingShared, blockingExclusive }

abstract class RandomAccessFile {
  Future<RandomAccessFile> close();
  Future<int> readByte();
  Future<Uint8List> read(int bytes);
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]);
  Future<RandomAccessFile> writeByte(int value);
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]);
  Future<RandomAccessFile> writeString(String string, {Encoding encoding = utf8});
  Future<int> position();
  Future<RandomAccessFile> setPosition(int position);
  Future<RandomAccessFile> truncate(int length);
  Future<int> length();
  Future<RandomAccessFile> flush();
  Future<RandomAccessFile> lock([FileLock mode = FileLock.exclusive, int start = 0, int end = -1]);
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]);
  String get path;

  // Sync methods
  int readByteSync();
  int readSync(int bytes); // Note: dart:io returns Uint8List, this is simplified
  int readIntoSync(List<int> buffer, [int start = 0, int? end]);
  void writeByteSync(int value);
  void writeFromSync(List<int> buffer, [int start = 0, int? end]);
  void writeStringSync(String string, {Encoding encoding = utf8});
  int positionSync();
  void setPositionSync(int position);
  void truncateSync(int length);
  int lengthSync();
  void flushSync();
  void lockSync([FileLock mode = FileLock.exclusive, int start = 0, int end = -1]);
  void unlockSync([int start = 0, int end = -1]);
  void closeSync();
}

class _DummyRandomAccessFile implements RandomAccessFile {
  @override
  final String path;
  _DummyRandomAccessFile(this.path);

  @override
  Future<RandomAccessFile> close() async => this;
  @override
  Future<int> readByte() async => -1;
  @override
  Future<Uint8List> read(int bytes) async => Uint8List(0);
  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async => 0;
  @override
  Future<RandomAccessFile> writeByte(int value) async => this;
  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) async => this;
  @override
  Future<RandomAccessFile> writeString(String string, {Encoding encoding = utf8}) async => this;
  @override
  Future<int> position() async => 0;
  @override
  Future<RandomAccessFile> setPosition(int position) async => this;
  @override
  Future<RandomAccessFile> truncate(int length) async => this;
  @override
  Future<int> length() async => 0;
  @override
  Future<RandomAccessFile> flush() async => this;
  @override
  Future<RandomAccessFile> lock([FileLock mode = FileLock.exclusive, int start = 0, int end = -1]) async => this;
  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async => this;

  @override
  int readByteSync() => -1;
  @override
  int readSync(int bytes) => 0; // Simplified
  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) => 0;
  @override
  void writeByteSync(int value) {}
  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {}
  @override
  void writeStringSync(String string, {Encoding encoding = utf8}) {}
  @override
  int positionSync() => 0;
  @override
  void setPositionSync(int position) {}
  @override
  void truncateSync(int length) {}
  @override
  int lengthSync() => 0;
  @override
  void flushSync() {}
  @override
  void lockSync([FileLock mode = FileLock.exclusive, int start = 0, int end = -1]) {}
  @override
  void unlockSync([int start = 0, int end = -1]) {}
  @override
  void closeSync() {}
}

// Link class (stub)
class Link extends FileSystemEntity {
  @override
  final String path;
  Link(this.path);

  Future<Link> create(String target, {bool recursive = false}) async => this;
  void createSync(String target, {bool recursive = false}) {}
  Future<Link> update(String target) async => this;
  void updateSync(String target) {}
  Future<String> target() async => '';
  String targetSync() => '';
  
  @override
  Future<Link> rename(String newPath) async => Link(newPath);
  @override
  Link renameSync(String newPath) => Link(newPath);
  
  @override
  Future<Link> delete({bool recursive = false}) async => this;
  @override
  void deleteSync({bool recursive = false}) {}
} 