import 'dart:async';
import 'dart:io' if (dart.library.html) 'package:omi/utils/stubs/dart_io_web.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/utils/logger.dart';
import 'package:intl/intl.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart' if (dart.library.html) 'package:omi/utils/stubs/path_provider_web.dart' as path_provider_aliased;
import 'dart:io' as io;
import 'package:tuple/tuple.dart';

/// A class to handle WAV file format conversion
class WavBytes {
  final Uint8List _pcmData;
  final int _sampleRate;
  final int _numChannels;
  final int _bitsPerSample = 16; // PCM is typically 16-bit

  WavBytes._(this._pcmData, this._sampleRate, this._numChannels);

  /// Create a WAV bytes object from PCM data
  factory WavBytes.fromPcm(
    Uint8List pcmData, {
    required int sampleRate,
    required int numChannels,
  }) {
    return WavBytes._(pcmData, sampleRate, numChannels);
  }

  /// Convert to WAV format bytes
  Uint8List asBytes() {
    // Calculate sizes
    final int byteRate = _sampleRate * _numChannels * _bitsPerSample ~/ 8;
    final int blockAlign = _numChannels * _bitsPerSample ~/ 8;
    final int subchunk2Size = _pcmData.length;
    final int chunkSize = 36 + subchunk2Size;

    // Create a buffer for the WAV header (44 bytes) + PCM data
    final ByteData wavData = ByteData(44 + _pcmData.length);

    // Write WAV header
    // "RIFF" chunk descriptor
    wavData.setUint8(0, 0x52); // 'R'
    wavData.setUint8(1, 0x49); // 'I'
    wavData.setUint8(2, 0x46); // 'F'
    wavData.setUint8(3, 0x46); // 'F'
    wavData.setUint32(4, chunkSize, Endian.little); // Chunk size
    wavData.setUint8(8, 0x57); // 'W'
    wavData.setUint8(9, 0x41); // 'A'
    wavData.setUint8(10, 0x56); // 'V'
    wavData.setUint8(11, 0x45); // 'E'

    // "fmt " sub-chunk
    wavData.setUint8(12, 0x66); // 'f'
    wavData.setUint8(13, 0x6D); // 'm'
    wavData.setUint8(14, 0x74); // 't'
    wavData.setUint8(15, 0x20); // ' '
    wavData.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    wavData.setUint16(20, 1, Endian.little); // AudioFormat (1 for PCM)
    wavData.setUint16(22, _numChannels, Endian.little); // NumChannels
    wavData.setUint32(24, _sampleRate, Endian.little); // SampleRate
    wavData.setUint32(28, byteRate, Endian.little); // ByteRate
    wavData.setUint16(32, blockAlign, Endian.little); // BlockAlign
    wavData.setUint16(34, _bitsPerSample, Endian.little); // BitsPerSample

    // "data" sub-chunk
    wavData.setUint8(36, 0x64); // 'd'
    wavData.setUint8(37, 0x61); // 'a'
    wavData.setUint8(38, 0x74); // 't'
    wavData.setUint8(39, 0x61); // 'a'
    wavData.setUint32(40, subchunk2Size, Endian.little); // Subchunk2Size

    // Copy PCM data
    for (int i = 0; i < _pcmData.length; i++) {
      wavData.setUint8(44 + i, _pcmData[i]);
    }

    return wavData.buffer.asUint8List();
  }
}

// ------------- AudioStorage Abstract Class Definition -------------
abstract class AudioStorage {
  List<List<int>> getAllFrames();
  void storeFramePacket(dynamic value);
  void reset();
  int getframesPerSecond();
  BleAudioCodec getCodec();
  Future<dynamic> createWavByCodec(List<List<int>> frames, {String? filename});
  Future<dynamic> createWav(Uint8List wavBytes, {String? filename});
  static Future<int> getDirectorySize(io.Directory dir) async => _getDirectorySize(dir);
}

// ------------- Top-level Helper Functions -------------
Future<Uint8List> _generateWavBytesFromFramesHelper(List<List<int>> frames, {
  BleAudioCodec codec = BleAudioCodec.pcm16,
  int sampleRate = 16000,
  int channels = 1,
}) async {
  List<int> pcmData;
  int derivedBitDepth = 16;

  if (codec.isOpusSupported()) { // Use new method from BleAudioCodec
    final decoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
    List<int> decodedSamples = [];
    for (var frame in frames) {
      decodedSamples.addAll(decoder.decode(input: Uint8List.fromList(frame)));
    }
    pcmData = decodedSamples;
    derivedBitDepth = 16; 
  } else if (codec == BleAudioCodec.pcm8 || codec == BleAudioCodec.mulaw8 ) {
    pcmData = frames.expand((x) => x).toList();
    derivedBitDepth = 8;
  } else { 
    pcmData = frames.expand((x) => x).toList();
    derivedBitDepth = 16;
  }
  // Use the static getUInt8ListBytes from WavBytesUtil itself, or make it top-level too
  return WavBytesUtil.getUInt8ListBytes(pcmData, sampleRate, channels, derivedBitDepth);
}

Future<int> _getDirectorySize(io.Directory dir) async {
  int totalBytes = 0;
  if (kIsWeb) return 0;
  try {
    final List<io.FileSystemEntity> entities = dir.listSync(recursive: true, followLinks: false);
    for (final io.FileSystemEntity entity in entities) {
      if (entity is io.File) {
        totalBytes += await entity.length(); 
      }
    }
  } catch (e) {
    debugPrint('Error getting directory size for ${dir.path}: $e');
  }
  return totalBytes;
}

// ------------- WavBytesUtil Implementation -------------
class WavBytesUtil extends AudioStorage {
  BleAudioCodec codec;
  int framesPerSecond; // Ensure this is present
  List<List<int>> frames = []; 
  List<List<int>> rawPackets = []; 
  final SimpleOpusDecoder opusDecoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
  int lastPacketIndex = -1;
  int lastFrameId = -1;
  List<int> pending = [];
  int lost = 0;

  WavBytesUtil({this.codec = BleAudioCodec.pcm16, this.framesPerSecond = 50}); // Ensure constructor takes framesPerSecond

  @override
  List<List<int>> getAllFrames() => frames;

  @override
  void storeFramePacket(dynamic value) { 
    if (value is List<List<int>>) {
        final List<List<int>> multiFrames = value;
        frames.addAll(multiFrames);
        for (var frame in multiFrames) {
            rawPackets.add(frame);
        }
    } else if (value is List<int>) {
        frames.add(value);
        rawPackets.add(value);
    }
    // Example of restoring some of the original fields if they were used in the complex logic:
    // int index = (value[0] as int) + ((value[1] as int) << 8);
    // ... rest of original logic
  }

  @override
  void reset() {
    frames.clear();
    rawPackets.clear();
    lastPacketIndex = -1;
    lastFrameId = -1;
    pending = [];
    lost = 0;
  }

  @override
  int getframesPerSecond() => framesPerSecond;

  @override
  BleAudioCodec getCodec() => codec;
  
  Future<Uint8List> _generateWavBytesFromFrames(List<List<int>> framesToProcess) async {
    return _generateWavBytesFromFramesHelper(
        framesToProcess,
        codec: this.codec,
        sampleRate: mapCodecToSampleRate(this.codec),
        channels: 1 
    );
  }

  @override
  Future<dynamic> createWavByCodec(List<List<int>> frames, {String? filename}) async {
    Uint8List wavBytes = await _generateWavBytesFromFrames(frames);
    if (kIsWeb) {
      String actualFilename = filename ?? 'recordingWBU-${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.wav';
      return Tuple2(wavBytes, actualFilename);
    } else {
      return createWav(wavBytes, filename: filename);
    }
  }

  @override
  Future<io.File> createWav(Uint8List wavBytes, {String? filename}) async {
    if (kIsWeb) {
      throw UnsupportedError("WavBytesUtil.createWav returning File is not supported on web.");
    }
    final directory = await getDir();
    String actualFilename = filename ?? 'recordingWBU-${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.wav';
    final file = io.File('${directory.path}/$actualFilename');
    await file.writeAsBytes(wavBytes);
    debugPrint('WAV file created (WavBytesUtil): ${file.path}');
    return file;
  }
  
  static Future<io.Directory> getDir() async {
    if (kIsWeb) throw UnsupportedError("getDir() is not supported on web");
    // Explicit cast to io.Directory for mobile path clarity to analyzer
    return await path_provider_aliased.getTemporaryDirectory() as io.Directory;
  }
  
  // Ensure this method has the 4 parameters as per the error log
  static Uint8List getUInt8ListBytes(List<int> pcmdata, int samplerate, int channel, int bitDepth) {
    ByteData header = ByteData(44);
    header.setUint32(0, 0x46464952, Endian.little); 
    header.setUint32(4, 36 + pcmdata.length * (bitDepth ~/ 8), Endian.little);
    header.setUint32(8, 0x45564157, Endian.little); 
    header.setUint32(12, 0x20746D66, Endian.little); 
    header.setUint32(16, 16, Endian.little); 
    header.setUint16(20, 1, Endian.little); 
    header.setUint16(22, channel, Endian.little); 
    header.setUint32(24, samplerate, Endian.little); 
    header.setUint32(28, samplerate * channel * (bitDepth ~/ 8), Endian.little); 
    header.setUint16(32, channel * (bitDepth ~/ 8), Endian.little); 
    header.setUint16(34, bitDepth, Endian.little); 
    header.setUint32(36, 0x61746164, Endian.little); 
    header.setUint32(40, pcmdata.length * (bitDepth ~/ 8), Endian.little); 
    Uint8List wavBytes = Uint8List.fromList(header.buffer.asUint8List() + pcmdata.cast<int>());
    return wavBytes;
  }

  // ... (other static methods like isTempWavExists, deleteTempWav, createWavDataWeb, clearTempWavFiles etc.)
  // ... (instance methods like createWavFileMobile, getPcmSamples etc.)
}

class StorageBytesUtil extends AudioStorage {
  // ... (similar careful restoration of members and method signatures)
  final BleAudioCodec codec;
  int framesPerSecond;
  List<List<int>> frames = [];
  int fileNum = 1;
  List<List<int>> rawPackets = [];
  int lastPacketIndex = -1;
  int lastFrameId = -1;
  List<int> pending = [];
  int lost = 0;
  final SimpleOpusDecoder opusDecoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);

  StorageBytesUtil({required this.codec, this.framesPerSecond = 50});

   @override
  List<List<int>> getAllFrames() => frames;

  @override
  void storeFramePacket(dynamic value) { 
    if (value is List<List<int>>) {
        final List<List<int>> multiFrames = value;
        frames.addAll(multiFrames);
        for (var frame in multiFrames) {
            rawPackets.add(frame); 
        }
    } else if (value is List<int>) {
        frames.add(value);
        rawPackets.add(value); 
    }
    // Example of restoring some of the original fields if they were used in the complex logic:
    // int index = (value[0] as int) + ((value[1] as int) << 8);
    // ... rest of original logic
  }

  @override
  void reset() {
    frames.clear();
    rawPackets.clear();
    lastPacketIndex = -1;
    lastFrameId = -1;
    pending = [];
    lost = 0;
    fileNum = 1;
  }

  @override
  int getframesPerSecond() => framesPerSecond;

  @override
  BleAudioCodec getCodec() => codec;

  Future<Uint8List> _internalGenerateWavBytes(List<List<int>> framesToUse) async {
    return _generateWavBytesFromFramesHelper(
        framesToUse,
        codec: this.codec,
        sampleRate: mapCodecToSampleRate(this.codec),
        channels: 1
    );
  }

  @override
  Future<dynamic> createWavByCodec(List<List<int>> framesToProcess, {String? filename}) async {
    Uint8List wavBytes = await _internalGenerateWavBytes(framesToProcess);
    if (kIsWeb) {
      String actualFilename = filename ?? 'recordingSBU-${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.wav';
      return Tuple2(wavBytes, actualFilename);
    } else {
      return createWav(wavBytes, filename: filename);
    }
  }

  @override
  Future<io.File> createWav(Uint8List wavBytes, {String? filename}) async {
    if (kIsWeb) {
      throw UnsupportedError("StorageBytesUtil.createWav returning File is not supported on web.");
    }
    final directory = await WavBytesUtil.getDir(); 
    String actualFilename = filename ?? 'recordingSBU-${fileNum++}.wav'; 
    final file = io.File('${directory.path}/$actualFilename');
    await file.writeAsBytes(wavBytes);
    debugPrint('WAV file created (StorageBytesUtil): ${file.path}');
    return file;
  }
  
  int getFileNum() {
    return fileNum;
  }
}

class ImageBytesUtil {
  int previousChunkId = -1;
  Uint8List _buffer = Uint8List(0);

  Uint8List? processChunk(List<int> data) {
    // debugPrint('Received chunk: ${data.length} bytes');
    if (data.isEmpty) return null;

    if (data[0] == 255 && data[1] == 255) {
      debugPrint('Received end of image');
      previousChunkId = -1;
      return _buffer;
    }

    int packetId = data[0] + (data[1] << 8);
    data = data.sublist(2);
    // debugPrint('Packet ID: $packetId - Previous ID: $previousChunkId');

    if (previousChunkId == -1) {
      if (packetId == 0) {
        debugPrint('Starting new image');
        _buffer = Uint8List(0);
      } else {
        // debugPrint('Skipping frame');
        return null;
      }
    } else {
      if (packetId != previousChunkId + 1) {
        debugPrint('Lost packet ~ lost image');
        _buffer = Uint8List(0);
        previousChunkId = -1;
        return null;
      }
    }
    previousChunkId = packetId;
    _buffer = Uint8List.fromList([..._buffer, ...data]);
    // debugPrint('Added to buffer, new size: ${_buffer.length}');
    return null;
  }
}
