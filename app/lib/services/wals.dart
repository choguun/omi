import 'package:collection/collection.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/audio/wav_bytes.dart';
import 'package:path_provider/path_provider.dart' if (dart.library.html) 'package:omi/utils/stubs/path_provider_web.dart' as path_provider_aliased;

class Pair<E, F> {
  E first;
  F last;
  Pair(this.first, this.last);
}

const chunkSizeInSeconds = 60;
const flushIntervalInSeconds = 90;

abstract class IWalSyncProgressListener {
  void onWalSyncedProgress(double percentage); // 0..1
}

abstract class IWalServiceListener extends IWalSyncListener {
  void onStatusChanged(WalServiceStatus status);
}

abstract class IWalSyncListener {
  void onMissingWalUpdated();
  void onWalSynced(Wal wal, {ServerConversation? conversation});
}

abstract class IWalSync {
  Future<List<Wal>> getMissingWals();
  Future deleteWal(Wal wal);
  Future<SyncLocalFilesResponse?> syncAll({IWalSyncProgressListener? progress});
  Future<SyncLocalFilesResponse?> syncWal({required Wal wal, IWalSyncProgressListener? progress});

  Future<void> start();
  Future<void> stop();
}

abstract class IWalService {
  void start();
  Future<void> stop();

  void subscribe(IWalServiceListener subscription, Object context);
  void unsubscribe(Object context);

  WalSyncs getSyncs();
}

enum WalServiceStatus {
  init,
  ready,
  stop,
}

enum WalStatus {
  inProgress,
  miss,
  synced,
  corrupted,
}

enum WalStorage {
  mem,
  disk,
  sdcard,
}

class Wal {
  int timerStart; // in seconds
  BleAudioCodec codec;
  int channel;
  int sampleRate;
  int seconds;
  String device;

  WalStatus status;
  WalStorage storage;

  String? filePath;
  List<List<int>> data = [];
  int storageOffset = 0;
  int storageTotalBytes = 0;
  int fileNum = 1;

  bool isSyncing = false;
  DateTime? syncStartedAt;
  int? syncEtaSeconds;

  int frameSize = 160;

  String get id => '${device}_$timerStart';

  Wal(
      {required this.timerStart,
      required this.codec,
      this.sampleRate = 16000,
      this.channel = 1,
      this.status = WalStatus.inProgress,
      this.storage = WalStorage.mem,
      this.filePath,
      this.seconds = chunkSizeInSeconds,
      this.device = "phone",
      this.storageOffset = 0,
      this.storageTotalBytes = 0,
      this.fileNum = 1,
      this.data = const []}) {
    frameSize = codec.getFrameSize();
  }

  factory Wal.fromJson(Map<String, dynamic> json) {
    return Wal(
      timerStart: json['timer_start'],
      codec: mapNameToCodec(json['codec']),
      channel: json['channel'],
      sampleRate: json['sample_rate'],
      status: WalStatus.values.asNameMap()[json['status']] ?? WalStatus.inProgress,
      storage: WalStorage.values.asNameMap()[json['storage']] ?? WalStorage.mem,
      filePath: json['file_path'],
      seconds: json['seconds'] ?? chunkSizeInSeconds,
      device: json['device'] ?? "phone",
      storageOffset: json['storage_offset'] ?? 0,
      storageTotalBytes: json['storage_total_bytes'] ?? 0,
      fileNum: json['file_num'] ?? 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timer_start': timerStart,
      'codec': codec.toString(),
      'channel': channel,
      'sample_rate': sampleRate,
      'status': status.name,
      'storage': storage.name,
      'file_path': filePath,
      'seconds': seconds,
      'device': device,
      'storage_offset': storageOffset,
      'storage_total_bytes': storageTotalBytes,
      'file_num': fileNum,
    };
  }

  static List<Wal> fromJsonList(List<dynamic> jsonList) => jsonList.map((e) => Wal.fromJson(e)).toList();

  getFileName() {
    return "audio_${device.replaceAll(RegExp(r'[^a-zA-Z0-9]'), "").toLowerCase()}_${codec}_${sampleRate}_${channel}_fs${frameSize}_${timerStart}.bin";
  }
}

class SDCardWalSync implements IWalSync {
  List<Wal> _wals = const [];
  BtDevice? _device;

  StreamSubscription? _storageStream;

  IWalSyncListener listener;

  SDCardWalSync(this.listener);

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return BleAudioCodec.pcm8;
    }
    return connection.getAudioCodec();
  }

  Future<List<int>> _getStorageList(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return [];
    }
    return connection.getStorageList();
  }

  @override
  Future deleteWal(Wal wal) async {
    _wals.removeWhere((w) => w.id == wal.id);

    if (_device != null) {
      await _writeToStorage(_device!.id, wal.fileNum, 1, 0);
    }

    listener.onMissingWalUpdated();
  }

  Future<List<Wal>> _getMissingWalsInternal() async {
    if (_device == null) {
      return [];
    }
    String deviceId = _device!.id;
    List<Wal> wals = [];
    var storageFiles = await _getStorageList(deviceId);
    if (storageFiles.isEmpty) {
      return [];
    }
    var totalBytes = storageFiles[0];
    if (totalBytes <= 0) {
      return [];
    }
    var storageOffset = storageFiles.length < 2 ? 0 : storageFiles[1];
    if (storageOffset > totalBytes) {
      debugPrint("SDCard bad state, offset > total");
      storageOffset = 0;
    }

    BleAudioCodec codec = await _getAudioCodec(deviceId);
    if (totalBytes - storageOffset > 10 * codec.getFramesLengthInBytes() * codec.getFramesPerSecond()) {
      var seconds = ((totalBytes - storageOffset) / codec.getFramesLengthInBytes()) ~/ codec.getFramesPerSecond();
      var timerStart = DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds;
      wals.add(Wal(
        codec: codec,
        timerStart: timerStart,
        status: WalStatus.miss,
        storage: WalStorage.sdcard,
        seconds: seconds,
        storageOffset: storageOffset,
        storageTotalBytes: totalBytes,
        fileNum: 1,
        device: _device!.id,
      ));
    }
    return wals;
  }

  @override
  Future<List<Wal>> getMissingWals() async {
    return _wals.where((w) => w.status == WalStatus.miss && w.storage == WalStorage.sdcard).toList();
  }
  
  @override
  Future<void> start() async {
    _wals = await _getMissingWalsInternal(); 
    listener.onMissingWalUpdated();
  }

  @override
  Future<void> stop() async {
    _wals = [];
    _storageStream?.cancel();
  }

  Future<bool> _writeToStorage(String deviceId, int numFile, int command, int offset) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return false;
    }
    return connection.writeToStorage(numFile, command, offset);
  }

  Future<StreamSubscription?> _getBleStorageBytesListener(
    String deviceId, {
    required void Function(List<int>) onStorageBytesReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleStorageBytesListener(onStorageBytesReceived: onStorageBytesReceived);
  }

  StreamSubscription? _syncStream;

  Future<SyncLocalFilesResponse?> syncAll({IWalSyncProgressListener? progress}) async {
    if (kIsWeb) return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
    List<Wal> walsToSync = await getMissingWals();
    if (walsToSync.isEmpty) return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);

    List<String> allNewIds = [];
    List<String> allUpdatedIds = [];

    for (Wal wal in walsToSync) {
      var response = await syncWal(wal: wal, progress: progress);
      if (response != null) {
        allNewIds.addAll(response.newConversationIds);
        allUpdatedIds.addAll(response.updatedConversationIds);
      }
    }
    return SyncLocalFilesResponse(newConversationIds: allNewIds, updatedConversationIds: allUpdatedIds);
  }

  Future<SyncLocalFilesResponse?> _syncWalMobile(Wal wal, {IWalSyncProgressListener? progress}) async {
    if (kIsWeb) return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
    if (wal.storage != WalStorage.sdcard) {
      return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
    }
    if (wal.filePath != null) {
        try {
            io.File fileToSync = io.File(wal.filePath!);
            if (await fileToSync.exists()) {
                return syncLocalFiles([fileToSync]);
            } else {
                 debugPrint('SD Card WAL file not found for sync: ${wal.filePath}');
                 return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
            }
        } catch (e) {
            debugPrint('Error syncing SD Card WAL mobile: $e');
            return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
        }
    } else {
        debugPrint('SD Card WAL filePath is null, cannot sync via _syncWalMobile.');
        return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
    }
  }

  @override
  Future<SyncLocalFilesResponse?> syncWal({required Wal wal, IWalSyncProgressListener? progress}) async {
    if (kIsWeb) {
      progress?.onWalSyncedProgress(1.0);
      wal.status = WalStatus.synced;
      listener.onWalSynced(wal);
      return SyncLocalFilesResponse(newConversationIds: [wal.id], updatedConversationIds: []);
    } else {
      return _syncWalMobile(wal, progress: progress);
    }
  }
}

class DiskWalSync implements IWalSync {
  List<Wal> _wals = [];
  Timer? _timer;
  final String _walsDir = 'wals';
  final IWalSyncListener listener;

  DiskWalSync(this.listener);

  Future<io.Directory?> _ensureWalsDir() async {
    if (kIsWeb) {
      debugPrint("DiskWalSync._ensureWalsDir: Not supported on web.");
      return null;
    }
    final io.Directory appDocDir = await path_provider_aliased.getApplicationDocumentsDirectory() as io.Directory;
    final io.Directory walsDirPath = io.Directory('${appDocDir.path}/$_walsDir');
    if (!await walsDirPath.exists()) {
      await walsDirPath.create(recursive: true);
    }
    return walsDirPath;
  }

  Future<List<Wal>> _readWalsFromDisk() async {
    if (kIsWeb) {
      debugPrint("DiskWalSync._readWalsFromDisk: Not supported on web. Returning empty list.");
      return [];
    }
    try {
      final io.Directory? dir = await _ensureWalsDir();
      if (dir == null) return [];
      final List<io.FileSystemEntity> entities = await dir.list().toList();
      final List<Wal> wals = [];
      for (io.FileSystemEntity entity in entities) {
        if (entity is io.File && entity.path.endsWith('.json')) {
          try {
            final String content = await entity.readAsString();
            final Map<String, dynamic> jsonMap = jsonDecode(content);
            wals.add(Wal.fromJson(jsonMap));
          } catch (e) {
            debugPrint("Error reading or parsing WAL json file: ${entity.path}, error: $e");
          }
        }
      }
      return wals;
    } catch (e) {
      debugPrint("Error listing WALs from disk: $e");
      return [];
    }
  }

  Future<void> _writeWalToDisk(Wal wal) async {
    if (kIsWeb) {
      debugPrint("DiskWalSync._writeWalToDisk: Not supported on web. No-op.");
      return;
    }
    try {
      final io.Directory? dir = await _ensureWalsDir();
      if (dir == null) return;
      final io.File file = io.File('${dir.path}/${wal.getFileName().replaceAll('.bin', '.json')}');
      await file.writeAsBytes(utf8.encode(jsonEncode(wal.toJson())));
    } catch (e) {
      debugPrint("Error writing WAL to disk: $e");
    }
  }

  Future<io.File?> _readWalFile(Wal wal) async {
    if (kIsWeb || wal.filePath == null) {
      debugPrint("DiskWalSync._readWalFile (audio): Not supported on web or filePath is null. Returning null.");
      return null;
    }
    try {
      final io.File file = io.File(wal.filePath!);
      if (await file.exists()) {
        return file;
      }
    } catch (e) {
      debugPrint("Error reading WAL audio file from disk: $e");
    }
    return null;
  }

  @override
  Future<void> deleteWal(Wal wal) async {
    if (kIsWeb) {
      debugPrint("DiskWalSync.deleteWal: Not supported on web. No-op.");
      _wals.removeWhere((w) => w.id == wal.id);
      listener.onMissingWalUpdated();
      return;
    }
    try {
      _wals.removeWhere((w) => w.id == wal.id);
      final io.Directory? dir = await _ensureWalsDir();
      if (dir == null) return;

      final io.File jsonFile = io.File('${dir.path}/${wal.getFileName().replaceAll('.bin', '.json')}');
      if (await jsonFile.exists()) {
        await jsonFile.delete();
      }
      if (wal.filePath != null) {
        final io.File audioFile = io.File(wal.filePath!);
        if (await audioFile.exists()) {
          await audioFile.delete();
        }
      }
      listener.onMissingWalUpdated();
    } catch (e) {
      debugPrint("Error deleting WAL from disk: $e");
    }
  }

  @override
  Future<List<Wal>> getMissingWals() async {
    if (kIsWeb) {
      debugPrint("DiskWalSync.getMissingWals: Not supported on web. Returning empty list.");
      return [];
    }
    if (_wals.where((w)=> w.storage == WalStorage.disk).isEmpty){
        await start();
    }
    return _wals.where((wal) => wal.status == WalStatus.miss && wal.storage == WalStorage.disk).toList();
  }

  @override
  Future<SyncLocalFilesResponse?> syncAll({IWalSyncProgressListener? progress}) async {
    if (kIsWeb) {
      debugPrint("DiskWalSync.syncAll: Not supported on web.");
      return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
    }
    var walsToSync = await getMissingWals();
    if (walsToSync.isEmpty) return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);

    List<io.File> filesToSync = [];
    for (var wal in walsToSync) {
      if (wal.filePath != null) {
        io.File file = io.File(wal.filePath!); 
        if (await file.exists()) {
          filesToSync.add(file);
        }
      } else {
        debugPrint("Wal missing filePath in syncAll: ${wal.id}");
      }
    }
    if (filesToSync.isEmpty) {
      debugPrint("No existing files found on disk to sync in syncAll.");
      return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
    }

    var response = await syncLocalFiles(filesToSync);

    if (response != null) {
      for (var wal in walsToSync) {
        if (filesToSync.any((f) => f.path == wal.filePath)) {
          wal.status = WalStatus.synced;
          await _writeWalToDisk(wal); 
          listener.onWalSynced(wal);
        }
      }
    }
    return response;
  }

  @override
  Future<SyncLocalFilesResponse?> syncWal({required Wal wal, IWalSyncProgressListener? progress}) async {
    if (kIsWeb) {
      debugPrint("DiskWalSync.syncWal: Not supported on web.");
      return null;
    }
    if (wal.storage != WalStorage.disk) {
      debugPrint("DiskWalSync.syncWal called for a non-disk WAL: ${wal.id}, storage: ${wal.storage}");
      return null;
    }
    if (wal.filePath == null) {
      debugPrint("Wal has no filePath to sync: ${wal.id}");
      wal.status = WalStatus.corrupted;
      await _writeWalToDisk(wal);
      listener.onMissingWalUpdated();
      return null;
    }

    io.File fileToSync = io.File(wal.filePath!); 
    if (!await fileToSync.exists()) {
      debugPrint("Wal file does not exist at path: ${wal.filePath}");
      wal.status = WalStatus.corrupted;
      await _writeWalToDisk(wal);
      listener.onMissingWalUpdated();
      return null;
    }

    var response = await syncLocalFiles([fileToSync]);

    if (response != null) {
      wal.status = WalStatus.synced;
      await _writeWalToDisk(wal);
      listener.onWalSynced(wal);
    }
    return response;
  }

  @override
  Future<void> start() async {
    if (kIsWeb) {
      debugPrint("DiskWalSync.start: Not supported on web. Wals will be empty.");
      _wals = [];
      listener.onMissingWalUpdated();
      return;
    }
    _wals = await _readWalsFromDisk();
    listener.onMissingWalUpdated();
  }

  @override
  Future<void> stop() async {
    _timer?.cancel(); 
  }

  Future<Wal?> saveWalData(String deviceId, BleAudioCodec codec, int timerStart, List<List<int>> data) async {
    if (kIsWeb) {
      debugPrint("DiskWalSync.saveWalData: Not supported on web. Returning null.");
      return null;
    }
    try {
      final io.Directory? dir = await _ensureWalsDir();
      if (dir == null) return null;

      final wal = Wal(
        timerStart: timerStart,
        codec: codec,
        storage: WalStorage.disk,
        device: deviceId,
        data: data,
      );
      wal.filePath = '${dir.path}/${wal.getFileName()}';

      final io.File audioFile = io.File(wal.filePath!);
      List<int> flatData = data.expand((x) => x).toList();
      await audioFile.writeAsBytes(Uint8List.fromList(flatData), flush: true);

      wal.status = WalStatus.miss;
      await _writeWalToDisk(wal);

      _wals.removeWhere((w) => w.id == wal.id);
      _wals.add(wal);
      listener.onMissingWalUpdated();
      return wal;
    } catch (e) {
      debugPrint("Error saving WAL data to disk: $e");
      return null;
    }
  }
}

class MemWalSync implements IWalSync {
  List<Wal> _wals = [];
  Timer? _timer;
  final IWalSyncListener listener;
  Map<String, List<List<int>>> pcmBuffers = {};
  final int flushInterval = flushIntervalInSeconds;

  MemWalSync(this.listener);

  @override
  Future deleteWal(Wal wal) async {
    _wals.removeWhere((w) => w.id == wal.id);
    pcmBuffers.remove(wal.id);
    listener.onMissingWalUpdated();
  }

  @override
  Future<List<Wal>> getMissingWals() async {
    return _wals.where((wal) => wal.status == WalStatus.miss && wal.storage == WalStorage.mem).toList();
  }

  @override
  Future<void> start() async {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: flushInterval), (timer) async {
      await flush();
    });
  }

  Future flush() async {
    var updated = false;
    for (var wal in _wals) {
      if (wal.status == WalStatus.inProgress && DateTime.now().millisecondsSinceEpoch ~/ 1000 - wal.timerStart > chunkSizeInSeconds) {
        wal.status = WalStatus.miss;
        updated = true;
      }
    }
    if (updated) {
      listener.onMissingWalUpdated();
    }
  }

  @override
  Future<void> stop() async {
    await flush();
    _timer?.cancel();
  }

  @override
  Future<SyncLocalFilesResponse?> syncAll({IWalSyncProgressListener? progress}) async {
    List<Wal> walsToSync = await getMissingWals();
    if (walsToSync.isEmpty) return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);

    List<String> allNewIds = [];
    List<String> allUpdatedIds = [];
    double currentProgress = 0;
    double step = walsToSync.isNotEmpty ? 1.0 / walsToSync.length : 0;

    for (Wal wal in walsToSync) {
      var response = await syncWal(wal: wal, progress: null);
      if (response != null) {
        allNewIds.addAll(response.newConversationIds);
        allUpdatedIds.addAll(response.updatedConversationIds);
      }
      currentProgress += step;
      progress?.onWalSyncedProgress(currentProgress.clamp(0,1));
    }
    return SyncLocalFilesResponse(newConversationIds: allNewIds, updatedConversationIds: allUpdatedIds);
  }

 @override
  Future<SyncLocalFilesResponse?> syncWal({required Wal wal, IWalSyncProgressListener? progress}) async {
    if (wal.data.isEmpty) {
      debugPrint("MemWalSync: Wal has no data to sync: ${wal.id}");
      return null;
    }

    Uint8List bytes;
    String filename = wal.getFileName().replaceAll('.bin', '.wav');
    io.File? tempFileForMobile;

    try {
      List<int> flatData = wal.data.expand((x) => x).toList();
      bytes = WavBytesUtil.getUInt8ListBytes(flatData, wal.sampleRate, 1, 16);

      SyncLocalFilesResponse? response;
      if (kIsWeb) {
        debugPrint("MemWalSync.syncWal (Web): Attempting to sync ${bytes.lengthInBytes} bytes for ${wal.id}.");
        response = SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
      } else {
        final tempDir = await path_provider_aliased.getTemporaryDirectory();
        tempFileForMobile = io.File('${tempDir.path}/$filename');
        await tempFileForMobile.writeAsBytes(bytes);
        
        response = await syncLocalFiles([tempFileForMobile]);
      }

      if (response != null) {
        wal.status = WalStatus.synced;
        listener.onWalSynced(wal);
      }
      return response;
    } catch (e) {
      debugPrint("Error in MemWalSync.syncWal for ${wal.id}: $e");
      wal.status = WalStatus.corrupted;
      listener.onMissingWalUpdated();
      return null;
    } finally {
      if (!kIsWeb && tempFileForMobile != null && await tempFileForMobile.exists()) {
        try {
          await tempFileForMobile.delete();
        } catch (e) {
          debugPrint("Error deleting temp file for MemWalSync: $e");
        }
      }
    }
  }


  Wal getInProgressWal(String deviceId, BleAudioCodec codec, int timerStart) {
    var wal = _wals.firstWhereOrNull((w) => w.timerStart == timerStart && w.device == deviceId);
    if (wal == null) {
      wal = Wal(timerStart: timerStart, codec: codec, device: deviceId, storage: WalStorage.mem);
      _wals.add(wal);
    }
    return wal;
  }

  List<List<int>> getPcmBuffer(String id) {
    if (!pcmBuffers.containsKey(id)) {
      pcmBuffers[id] = [];
    }
    return pcmBuffers[id]!;
  }

  void storeFramePacket(String deviceId, BleAudioCodec codec, int timerStart, List<int> frame) {
    Wal wal = getInProgressWal(deviceId, codec, timerStart);
    if (wal.status == WalStatus.synced) return;
    wal.data.add(frame);
  }
}

class SharedPreferencesWalStorage {
  static const _walsKey = 'wals_shared_preferences';

  Future<List<Wal>> loadWals() async {
    if (kIsWeb) {
      debugPrint("SharedPreferencesWalStorage.loadWals: Not supported on web. Returning empty list.");
      return [];
    }
    try {
      final String? walsJsonString = SharedPreferencesUtil().getString(_walsKey);
      if (walsJsonString != null) {
        final List<dynamic> decodedList = jsonDecode(walsJsonString);
        List<Wal> loadedWals = Wal.fromJsonList(decodedList);
        return loadedWals;
      } else {
        return [];
      }
    } catch (e) {
      debugPrint("Error loading WALs from SharedPreferences: $e");
      return [];
    }
  }

  Future<void> saveWals(List<Wal> wals) async {
    if (kIsWeb) {
      debugPrint("SharedPreferencesWalStorage.saveWals: Not supported on web. No-op.");
      return;
    }
    try {
      final String walsJsonString = jsonEncode(wals.map((wal) => wal.toJson()).toList());
      SharedPreferencesUtil().saveString(_walsKey, walsJsonString);
    } catch (e) {
      debugPrint("Error saving WALs to SharedPreferences: $e");
    }
  }

  Future<void> clearWals() async {
    if (kIsWeb) {
      debugPrint("SharedPreferencesWalStorage.clearWals: Not supported on web. No-op.");
      return;
    }
    SharedPreferencesUtil().remove(_walsKey);
  }
}

class WalSyncs {
  final MemWalSync mem;
  final DiskWalSync disk;
  final SDCardWalSync sdcard;

  WalSyncs(IWalSyncListener listener)
      : mem = MemWalSync(listener),
        disk = DiskWalSync(listener),
        sdcard = SDCardWalSync(listener);

  List<IWalSync> get all => [mem, disk, sdcard];
}

class WalService implements IWalService, IWalSyncListener {
  final List<Pair<IWalServiceListener, Object>> _subscriptions = [];
  WalServiceStatus _status = WalServiceStatus.init;
  final SharedPreferencesWalStorage _storage = SharedPreferencesWalStorage();
  late WalSyncs _syncs;
  List<Wal> _wals = [];

  WalService() {
    _syncs = WalSyncs(this);
  }

  WalServiceStatus get status => _status;

  @override
  void onMissingWalUpdated() async {
    _wals = await _storage.loadWals();
    await _updateWals();
    for (var sub in _subscriptions) {
      sub.first.onMissingWalUpdated();
    }
  }

  @override
  void onWalSynced(Wal wal, {ServerConversation? conversation}) async {
    _updateWalStatus(wal, WalStatus.synced);
    await _storage.saveWals(_wals);
    for (var sub in _subscriptions) {
      sub.first.onWalSynced(wal, conversation: conversation);
    }
  }

  @override
  Future<void> start() async {
    _wals = await _storage.loadWals();
    for (final IWalSync syncService in _syncs.all) {
      await syncService.start();
    }
    _updateWals();
    _status = WalServiceStatus.ready;
    for (var sub in _subscriptions) {
      sub.first.onStatusChanged(_status);
    }
  }

  @override
  Future<void> stop() async {
    for (var sync in _syncs.all) {
      await sync.stop();
    }
    _status = WalServiceStatus.stop;
    for (var sub in _subscriptions) {
      sub.first.onStatusChanged(_status);
    }
  }

  @override
  void subscribe(IWalServiceListener subscription, Object context) {
    _subscriptions.add(Pair(subscription, context));
  }

  @override
  void unsubscribe(Object context) {
    _subscriptions.removeWhere((pair) => pair.last == context);
  }

  Future<void> _updateWals() async {
    for (var sync in _syncs.all) {
      var missingWals = await sync.getMissingWals();
      for (var missingWal in missingWals) {
        if (_wals.firstWhereOrNull((w) => w.id == missingWal.id) == null) {
          _wals.add(missingWal);
        }
      }
    }
    await _storage.saveWals(_wals);
  }

  void _updateWalStatus(Wal wal, WalStatus status) {
    var existingWal = _wals.firstWhereOrNull((w) => w.id == wal.id);
    if (existingWal != null) {
      existingWal.status = status;
    }
  }

  @override
  WalSyncs getSyncs() => _syncs;
}
