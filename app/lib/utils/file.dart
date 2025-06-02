import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:omi/utils/audio/wav_bytes.dart';
import 'package:path_provider/path_provider.dart';

class FileUtils {
  static Future<File?> saveAudioBytesToTempFile(List<List<int>> chunk, int timerStart, int frameSize) async {
    if (kIsWeb) {
      // Saving to a "temp file path" is not a web concept.
      // Callers on web need to be refactored to work with bytes directly.
      throw UnsupportedError("saveAudioBytesToTempFile is not supported on web. Manage bytes in memory.");
    }
    // Mobile-specific logic
    final directory = await getTemporaryDirectory();
    String filePath = '${directory.path}/audio_fs${frameSize}_${timerStart}.bin';
    List<int> data = [];
    for (int i = 0; i < chunk.length; i++) {
      var frame = chunk[i];

      // Format: <length>|<data> ; bytes: 4 | n
      final byteFrame = ByteData(frame.length);
      for (int i = 0; i < frame.length; i++) {
        byteFrame.setUint8(i, frame[i]);
      }
      data.addAll(Uint32List.fromList([frame.length]).buffer.asUint8List());
      data.addAll(byteFrame.buffer.asUint8List());
    }
    final file = File(filePath);
    await file.writeAsBytes(data);

    return file;
  }

  static Future<Uint8List> convertPcmToWavFile(Uint8List pcmBytes, int sampleRate, int channels) async {
    try {
      // Convert PCM to WAV bytes
      final wavBytes = WavBytes.fromPcm(
        pcmBytes,
        sampleRate: sampleRate,
        numChannels: channels,
      ).asBytes();

      if (kIsWeb) {
        return wavBytes;
      } else {
        // Create a temporary file (for mobile, if legacy code still relies on a File object)
        // Consider if this File is strictly necessary for mobile callers.
        // If not, this can be removed and mobile can also just return wavBytes.
        final tempDir = await getTemporaryDirectory();
        final tempPath = '${tempDir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
        final file = File(tempPath);
        await file.writeAsBytes(wavBytes);
        // The function now returns Uint8List. Callers expecting a File path will need adjustment.
        // For now, to minimize immediate breakage on mobile, one might consider a wrapper
        // or have mobile-specific functions if File objects are truly needed downstream.
        // However, the goal is to move towards Uint8List.
        return wavBytes; // Mobile also returns bytes, File is just a side effect for now.
      }
    } catch (e) {
      debugPrint('Error converting PCM to WAV: $e');
      rethrow;
    }
  }
}
