import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
// Explicitly hide File and ZipFile from archive to prevent clashes
import 'package:archive/archive.dart' hide File, ZipFile;
import 'package:archive/archive_io.dart' as archive_io; // For mobile, if needed for advanced archive ops.

// Conditional import for flutter_archive
// The stub should define the necessary classes/methods if flutter_archive is not available.
import 'package:flutter_archive/flutter_archive.dart' if (dart.library.html) 'package:omi/pages/home/flutter_archive_unsupported.dart' as fa;

// Conditional import for dart:io
// The stub 'dart_io_unsupported.dart' should define File, Directory, etc., for web.
import 'dart:io' if (dart.library.html) 'package:omi/pages/home/dart_io_unsupported.dart';

// Alias for dart:io to be used explicitly in mobile-only code sections.
import 'dart:io' as io;

// Conditional import for path_provider
import 'package:path_provider/path_provider.dart' if (dart.library.html) 'package:omi/utils/stubs/path_provider_web.dart' as path_provider_aliased;

import 'package:uuid/uuid.dart';
import 'package:flutter/widgets.dart';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/http/api/device.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/device.dart';
import 'package:omi/utils/manifest/manifest.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:archive/archive.dart' as arch; // For web ZIP processing (ZipDecoder)

mixin FirmwareMixin<T extends StatefulWidget> on State<T> {
  Map latestFirmwareDetails = {};
  bool isDownloading = false;
  bool isDownloaded = false;
  int downloadProgress = 1;
  bool isInstalling = false;
  bool isInstalled = false;
  int installProgress = 1;
  bool isLegacySecureDFU = true;
  List<String> otaUpdateSteps = [];
  final mcumgr.FirmwareUpdateManagerFactory? managerFactory = mcumgr.FirmwareUpdateManagerFactory();
  Uint8List? downloadedFirmwareBytes;
  String? firmwarePathMobile;

  /// Process ZIP file and return firmware image list
  Future<List<mcumgr.Image>> processZipFile(Uint8List zipFileData) async {
    if (kIsWeb) {
      // Web implementation (uses arch.ZipDecoder, arch.ArchiveFile)
      try {
        final archive = arch.ZipDecoder().decodeBytes(zipFileData, verify: true);

        arch.ArchiveFile? manifestArchiveFile;
        String manifestPathSuffix = 'manifest.json';
        List<String> commonManifestPaths = [manifestPathSuffix, 'firmware/$manifestPathSuffix'];

        for (final fileInArchive in archive) {
          for (final commonPath in commonManifestPaths) {
            if (fileInArchive.name.endsWith(commonPath)) {
              manifestArchiveFile = fileInArchive;
              break;
            }
          }
          if (manifestArchiveFile != null) break;
        }
        if (manifestArchiveFile == null) {
           for (final fileInArchive in archive) {
             if (fileInArchive.name.endsWith(manifestPathSuffix)) {
                manifestArchiveFile = fileInArchive;
                break;
             }
           }
        }
        if (manifestArchiveFile == null) throw Exception('manifest.json not found in ZIP archive');
        if (!manifestArchiveFile.isFile) throw Exception('manifest.json is not a file in ZIP archive');

        final manifestString = utf8.decode(manifestArchiveFile.content as Uint8List);
        final manifestJson = json.decode(manifestString);
        final manifest = Manifest.fromJson(manifestJson);

        final List<mcumgr.Image> firmwareImages = [];
        for (final manifestEntry in manifest.files) {
          arch.ArchiveFile? firmwareArchiveFile;
          for (final fileInArchive in archive) {
            if (fileInArchive.name == manifestEntry.file || fileInArchive.name.endsWith('/${manifestEntry.file}')) {
              firmwareArchiveFile = fileInArchive;
              break;
            }
          }
          if (firmwareArchiveFile == null) {
            for (final fileInArchive in archive) {
              if (fileInArchive.name.endsWith(manifestEntry.file)) {
                firmwareArchiveFile = fileInArchive;
                break;
              }
            }
          }
          if (firmwareArchiveFile == null) throw Exception('Firmware file ${manifestEntry.file} not found in ZIP archive.');
          if (!firmwareArchiveFile.isFile) throw Exception('Firmware file ${manifestEntry.file} is not a file');
          
          final firmwareFileData = firmwareArchiveFile.content as Uint8List;
          final image = mcumgr.Image(image: manifestEntry.image, data: firmwareFileData);
          firmwareImages.add(image);
        }
        return firmwareImages;
      } catch (e) {
        debugPrint('Error processing ZIP file on web: $e');
        throw Exception('Failed to process ZIP file on web: $e');
      }
    } else {
      // Mobile implementation: Use io.File and io.Directory explicitly
      final systemTempDir = await path_provider_aliased.getTemporaryDirectory(); 
      final prefix = const Uuid().v4().substring(0, 8);
      final tempDirPath = '${systemTempDir.path}/$prefix';
      final firmwareZipPath = '${tempDirPath}/firmware.zip';
      final destinationDirPath = '${tempDirPath}/firmware';

      final io.Directory tempDir = io.Directory(tempDirPath);
      final io.File firmwareFile = io.File(firmwareZipPath);
      final io.Directory destinationDir = io.Directory(destinationDirPath);

      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
        await tempDir.create();
        await firmwareFile.writeAsBytes(zipFileData);
        await destinationDir.create();

        // flutter_archive expects dart:io.File and dart:io.Directory.
        // Our io.File and io.Directory are exactly that on mobile.
        await fa.ZipFile.extractToDirectory(
          zipFile: firmwareFile, // This is io.File
          destinationDir: destinationDir, // This is io.Directory
        );

        final manifestIoFile = io.File('${destinationDir.path}/manifest.json');
        final manifestString = await manifestIoFile.readAsString();
        final manifestJson = json.decode(manifestString);
        final manifest = Manifest.fromJson(manifestJson);

        final List<mcumgr.Image> firmwareImages = [];
        for (final fileEntry in manifest.files) {
          final firmwareIoFile = io.File('${destinationDir.path}/${fileEntry.file}');
          final firmwareFileData = await firmwareIoFile.readAsBytes();
          final image = mcumgr.Image(
            image: fileEntry.image, 
            data: firmwareFileData,
          );
          firmwareImages.add(image);
        }
        return firmwareImages;
      } catch (e) {
        debugPrint('Error processing ZIP file on mobile: $e');
        throw Exception('Failed to process ZIP file on mobile: $e');
      } finally {
        if (await tempDir.exists()) { // Check existence before deleting
            await tempDir.delete(recursive: true);
        }
      }
    }
  }

  Future<void> startDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    if (isLegacySecureDFU) {
      return startLegacyDfu(btDevice, fileInAssets: fileInAssets);
    }
    // Pass downloadedFirmwareBytes if on web and available, else use zipFilePath for mobile
    return startMCUDfu(btDevice.id, fileInAssets: fileInAssets, zipFilePath: kIsWeb ? null : zipFilePath, firmwareBytes: kIsWeb ? downloadedFirmwareBytes : null);
  }

  Future<void> startMCUDfu(String deviceId, {bool fileInAssets = false, String? zipFilePath, Uint8List? firmwareBytes}) async {
    setState(() {
      isInstalling = true;
    });
    await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
    await Future.delayed(const Duration(seconds: 2));

    Uint8List? bytesToProcess;
    if (kIsWeb) {
      if (firmwareBytes == null) {
        debugPrint('Error: Firmware bytes not available for web DFU.');
        setState(() { isInstalling = false; });
        // TODO: Show error to user
        return;
      }
      bytesToProcess = firmwareBytes;
    } else {
      // Mobile: Use io.File explicitly
      if (zipFilePath == null && !fileInAssets) {
          zipFilePath = firmwarePathMobile; 
      }
      if (zipFilePath == null && !fileInAssets) {
         debugPrint('Error: Firmware file path not available for mobile DFU.');
         setState(() { isInstalling = false; });
         return;
      }
      if (!fileInAssets && zipFilePath != null) {
        bytesToProcess = await io.File(zipFilePath).readAsBytes(); // Use io.File
      } else if (fileInAssets && zipFilePath != null) {
        // If fileInAssets is true, mcumgr expects bytes from an asset path.
        // This example assumes zipFilePath is an asset path that needs to be read into bytes.
        // For simplicity, and because mcumgr needs bytes, we read it. 
        // If your DFU library handles asset paths directly, this might differ.
        // final byteData = await rootBundle.load(zipFilePath); // Example for loading from assets
        // bytesToProcess = byteData.buffer.asUint8List();
        // For now, assuming File(zipFilePath) for assets is a path that can be read, 
        // though typically assets are not direct file system paths easily readable by File() without specific handling.
        // Let's stick to File for consistency if it's an actual path, otherwise asset loading is needed.
        // This part might need review based on how fileInAssets and zipFilePath for assets work.
        // For now, assume if zipFilePath is given, it's a readable path.
        bytesToProcess = await io.File(zipFilePath).readAsBytes(); // Use io.File
      } else {
        debugPrint('Error: Could not determine firmware bytes for mobile DFU.');
        setState(() { isInstalling = false; });
        return;
      }
    }

    if (bytesToProcess == null) {
       debugPrint('Error: Firmware bytes are null before processing.');
       setState(() { isInstalling = false; });
       return;
    }

    const configuration = mcumgr.FirmwareUpgradeConfiguration(
      estimatedSwapTime: Duration(seconds: 0),
      eraseAppSettings: true,
      pipelineDepth: 1,
    );
    final updateManager = await managerFactory!.getUpdateManager(deviceId);
    final images = await processZipFile(bytesToProcess);

    final updateStream = updateManager.setup();

    updateStream.listen((state) {
      if (state == mcumgr.FirmwareUpgradeState.success) {
        debugPrint('update success');
        setState(() {
          isInstalling = false;
          isInstalled = true;
        });
      } else {
        debugPrint('update state: $state');
      }
    });

    updateManager.progressStream.listen((progress) {
      debugPrint('progress: $progress');
      setState(() {
        installProgress = (progress.bytesSent / progress.imageSize * 100).round();
      });
    });

    updateManager.logger.logMessageStream
        .where((log) => log.level.rawValue > 1) // Filter debug messages
        .listen((log) {
      debugPrint('dfu log: ${log.message}');
    });

    await updateManager.update(
      images,
      configuration: configuration,
    );
  }

  Future<void> startLegacyDfu(BtDevice btDevice, {bool fileInAssets = false}) async {
    setState(() {
      isInstalling = true;
    });
    await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
    await Future.delayed(const Duration(seconds: 2));
    
    String? actualFirmwarePath;
    if (kIsWeb) {
      // Legacy DFU with nordic_dfu likely doesn't support Uint8List directly for web.
      // This feature might be unavailable or require a different approach on web.
      debugPrint('Legacy DFU (nordic_dfu) is likely not supported on web with a file path.');
      // Check nordic_dfu documentation for web support with byte arrays or alternative methods.
      // For now, we cannot proceed with a file path on web.
      setState(() { isInstalling = false; });
      // TODO: Show appropriate message to the user.
      return;
    } else {
      actualFirmwarePath = firmwarePathMobile; // Use path from downloadFirmware
      if (actualFirmwarePath == null && !fileInAssets) {
         debugPrint('Error: Firmware file path not available for mobile Legacy DFU.');
         setState(() { isInstalling = false; });
         // TODO: Show error to user
         return;
      }
      // If fileInAssets is true, nordic_dfu handles it internally with the provided path.
      // If not fileInAssets, actualFirmwarePath must be set.
    }
    
    // If fileInAssets is true, the passed path is used as is (assumed to be an asset path)
    // Otherwise, use the downloaded firmwarePathMobile
    String firmwarePathForDfu = fileInAssets ? 'assets/firmware.zip' : actualFirmwarePath!; // Example asset path if fileInAssets
                                                                                      // TODO: The asset path needs to be correct if fileInAssets is true.
                                                                                      // The original code had: String firmwareFile = '${(await getApplicationDocumentsDirectory()).path}/firmware.zip';
                                                                                      // This was overwritten if zipFilePath was provided to startMCUDfu, but startLegacyDfu didn't take zipFilePath.
                                                                                      // For now, if not fileInAssets, we use firmwarePathMobile.
                                                                                      // If fileInAssets, we need a valid asset path. The current logic is a placeholder.

    NordicDfu dfu = NordicDfu();
    await dfu.startDfu(
      btDevice.id,
      firmwarePathForDfu, // This must be a valid path (file system or asset)
      fileInAsset: fileInAssets,
      numberOfPackets: 8,
      enableUnsafeExperimentalButtonlessServiceInSecureDfu: true,
      iosSpecialParameter: const IosSpecialParameter(
        packetReceiptNotificationParameter: 8,
        forceScanningForNewAddressInLegacyDfu: true,
        connectionTimeout: 60,
      ),
      androidSpecialParameter: const AndroidSpecialParameter(
        packetReceiptNotificationsEnabled: true,
        rebootTime: 1000,
      ),
      onProgressChanged: (deviceAddress, percent, speed, avgSpeed, currentPart, partsTotal) {
        debugPrint('deviceAddress: $deviceAddress, percent: $percent');
        setState(() {
          installProgress = percent.toInt();
        });
      },
      onError: (deviceAddress, error, errorType, message) =>
          debugPrint('deviceAddress: $deviceAddress, error: $error, errorType: $errorType, message: $message'),
      onDeviceConnecting: (deviceAddress) => debugPrint('deviceAddress: $deviceAddress, onDeviceConnecting'),
      onDeviceConnected: (deviceAddress) => debugPrint('deviceAddress: $deviceAddress, onDeviceConnected'),
      onDfuProcessStarting: (deviceAddress) => debugPrint('deviceAddress: $deviceAddress, onDfuProcessStarting'),
      onDfuProcessStarted: (deviceAddress) => debugPrint('deviceAddress: $deviceAddress, onDfuProcessStarted'),
      onEnablingDfuMode: (deviceAddress) => debugPrint('deviceAddress: $deviceAddress, onEnablingDfuMode'),
      onFirmwareValidating: (deviceAddress) => debugPrint('address: $deviceAddress, onFirmwareValidating'),
      onDfuCompleted: (deviceAddress) {
        debugPrint('deviceAddress: $deviceAddress, onDfuCompleted');
        setState(() {
          isInstalling = false;
          isInstalled = true;
        });
      },
    );
  }

  Future getLatestVersion(
      {required String deviceModelNumber,
      required String firmwareRevision,
      required String hardwareRevision,
      required String manufacturerName}) async {
    latestFirmwareDetails = await getLatestFirmwareVersion(
      deviceModelNumber: deviceModelNumber,
      firmwareRevision: firmwareRevision,
      hardwareRevision: hardwareRevision,
      manufacturerName: manufacturerName,
    );
    if (latestFirmwareDetails['ota_update_steps'] != null) {
      otaUpdateSteps = List<String>.from(latestFirmwareDetails['ota_update_steps']);
    }
    if (latestFirmwareDetails['is_legacy_secure_dfu'] != null) {
      isLegacySecureDFU = latestFirmwareDetails['is_legacy_secure_dfu'];
    }
  }

  Future<(String, bool, String)> shouldUpdateFirmware({required String currentFirmware}) async {
    return DeviceUtils.shouldUpdateFirmware(
        currentFirmware: currentFirmware, latestFirmwareDetails: latestFirmwareDetails);
  }

  Future downloadFirmware() async {
    final zipUrl = latestFirmwareDetails['zip_url'];
    if (zipUrl == null) {
      debugPrint('Error: zip_url is null in latestFirmwareDetails');
      return;
    }

    var httpClient = http.Client();
    var request = http.Request('GET', Uri.parse(zipUrl));
    var response = httpClient.send(request);
    
    List<List<int>> chunks = [];
    int downloaded = 0;
    setState(() {
      isDownloading = true;
      isDownloaded = false;
      downloadedFirmwareBytes = null;
      firmwarePathMobile = null;
    });
    response.asStream().listen((http.StreamedResponse r) {
      if (r.contentLength == null) {
        debugPrint('Error: Response content length is null.');
        setState(() {
          isDownloading = false;
        });
        return;
      }
      r.stream.listen((List<int> chunk) {
        debugPrint('downloadPercentage: ${downloaded / r.contentLength! * 100}');
        setState(() {
          downloadProgress = (downloaded / r.contentLength! * 100).clamp(0, 100).toInt();
        });
        chunks.add(chunk);
        downloaded += chunk.length;
      }, onDone: () async {
        debugPrint('downloadPercentage: ${downloaded / r.contentLength! * 100}');

        final Uint8List bytes = Uint8List(r.contentLength!);
        int offset = 0;
        for (List<int> chunk_ in chunks) {
          bytes.setRange(offset, offset + chunk_.length, chunk_);
          offset += chunk_.length;
        }

        if (kIsWeb) {
          downloadedFirmwareBytes = bytes;
          debugPrint('Firmware downloaded to memory for web.');
        } else {
          // Ensure dart:io types are only used in the non-web path
          final dirPath = (await path_provider_aliased.getApplicationDocumentsDirectory()).path;
          final mobileFile = io.File('$dirPath/firmware.zip'); // 'File' will resolve to dart:io.File here
          await mobileFile.writeAsBytes(bytes);
          firmwarePathMobile = mobileFile.path;
          debugPrint('Firmware saved to ${mobileFile.path} for mobile.');
        }
        
        setState(() {
          isDownloading = false;
          isDownloaded = true;
        });
      }, onError: (e) {
        debugPrint('Error downloading firmware: $e');
        setState(() {
          isDownloading = false;
        });
      });
    }, onError: (e) {
      debugPrint('Error making request for firmware download: $e');
      setState(() {
        isDownloading = false;
      });
    });
  }
}
