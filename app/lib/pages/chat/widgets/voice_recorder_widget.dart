import 'dart:async';
import 'dart:math' as Math;
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:omi/backend/http/api/messages.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/file.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shimmer/shimmer.dart';
import 'package:path_provider/path_provider.dart' if (dart.library.html) 'package:omi/pages/home/path_provider_unsupported.dart'; // Conditional import for path_provider
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:omi/utils/app_file.dart'; // Import AppFile

enum RecordingState {
  notRecording,
  recording,
  transcribing,
  transcribeSuccess,
  transcribeFailed,
}

class VoiceRecorderWidget extends StatefulWidget {
  final Function(String, AppFile?) onTranscriptReady;
  final VoidCallback onClose;

  const VoiceRecorderWidget({
    super.key,
    required this.onTranscriptReady,
    required this.onClose,
  });

  @override
  State<VoiceRecorderWidget> createState() => _VoiceRecorderWidgetState();
}

class _VoiceRecorderWidgetState extends State<VoiceRecorderWidget> with SingleTickerProviderStateMixin {
  RecordingState _state = RecordingState.recording;
  List<List<int>> _audioChunks = [];
  String _transcript = '';
  bool _isProcessing = false;
  AppFile? _recordedAudioAppFile; // To store the AppFile once created

  // Audio visualization
  final List<double> _audioLevels = List.generate(20, (_) => 0.1);
  late AnimationController _animationController;
  Timer? _waveformTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    // Setup timer to update the wave visualization every second
    _waveformTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_state == RecordingState.recording && mounted) {
        setState(() {
          // Just trigger a repaint
        });
      }
    });

    _startRecording();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _waveformTimer?.cancel();

    // Make sure to stop recording when widget is disposed
    if (_state == RecordingState.recording) {
      // Use a synchronous call to stop recording to avoid any async issues
      ServiceManager.instance().mic.stop();
    }

    super.dispose();
  }

  Future<void> _startRecording() async {
    await Permission.microphone.request();

    await ServiceManager.instance().mic.start(onByteReceived: (bytes) {
      debugPrint('[VoiceRecorderWidget] onByteReceived, length: \${bytes.lengthInBytes}');
      if (_state == RecordingState.recording && mounted) {
        if (mounted) {
          setState(() {
            _audioChunks.add(bytes.toList()); // bytes are now framed Opus packets

            // Temporarily disable/remove PCM-based audio visualization
            // as 'bytes' are no longer PCM.
            // A new visualization method would be needed for Opus packet energy.
            // For now, let's just keep the last level to show some activity.
            if (_audioLevels.isNotEmpty) {
                for (int i = 0; i < _audioLevels.length - 1; i++) {
                    _audioLevels[i] = _audioLevels[i + 1];
                }
                _audioLevels[_audioLevels.length - 1] = 0.5; // Static placeholder
            }
          });
        }
      }
    }, onRecording: () {
      debugPrint('Recording started');
      setState(() {
        _state = RecordingState.recording;
        _audioChunks = [];
        _recordedAudioAppFile = null; // Clear previous recording
        // Reset audio levels
        for (int i = 0; i < _audioLevels.length; i++) {
          _audioLevels[i] = 0.1;
        }
      });
    }, onStop: () {
      debugPrint('Recording stopped');
    }, onInitializing: () {
      debugPrint('Initializing');
    });
  }

  Future<void> _stopRecording() async {
    _waveformTimer?.cancel();
    ServiceManager.instance().mic.stop();
  }

  Future<void> _processRecording() async {
    if (_audioChunks.isEmpty) {
      widget.onClose();
      return;
    }

    setState(() {
      _state = RecordingState.transcribing;
      _isProcessing = true;
    });

    await _stopRecording();

    // Flatten audio chunks (framed Opus packets) into a single list
    List<int> framedOpusBytesList = [];
    for (var chunk in _audioChunks) {
      framedOpusBytesList.addAll(chunk);
    }
    final Uint8List allFramedOpusData = Uint8List.fromList(framedOpusBytesList);

    // Determine Opus frame size (samples per frame)
    // Web uses 32000 Hz, 20ms frames for Opus encoding in MicRecorderService
    // Frame size = 0.020s * 32000 samples/s = 640 samples
    // final int opusFrameSizeInSamples = 640;
    final int actualSampleRate = ServiceManager.instance().mic.actualSampleRate ?? 16000; // Fallback if null, though it shouldn't be
    final int opusFrameSizeInSamples = (actualSampleRate * 0.020).round();

    // Use current time in seconds since epoch, as expected by the backend.
    // ENSURE THE CLIENT SYSTEM CLOCK IS ACCURATE FOR THIS TO WORK.
    // Subtract 30 seconds to ensure the timestamp is not slightly in the future.
    final int currentMilliseconds = DateTime.now().millisecondsSinceEpoch;
    final String timestamp = (currentMilliseconds ~/ 1000).toString();
    final String fileName = "voice_recording_${timestamp}_fs${opusFrameSizeInSamples}_sr${actualSampleRate}.bin";
    // --- END TEMPORARY HARDCODED FILENAME ---

    _recordedAudioAppFile = await AppFile.fromBytes(
      allFramedOpusData,
      fileName,
      mimeType: "application/octet-stream", // Correct MIME type for .bin
      length: allFramedOpusData.lengthInBytes,
    );

    try {
      debugPrint('[VoiceRecorderWidget] Attempting to transcribe with filename: ${_recordedAudioAppFile?.name}'); // Log the filename
      // Call the unified transcribeVoiceMessage with the .bin AppFile
      String transcript = await transcribeVoiceMessage(_recordedAudioAppFile!); 

      if (mounted) {
        setState(() {
          _transcript = transcript;
          _state = RecordingState.transcribeSuccess;
          _isProcessing = false;
        });
        if (transcript.isNotEmpty) { // Pass both transcript and AppFile
            widget.onTranscriptReady(transcript, _recordedAudioAppFile);
        } else if (transcript.isEmpty && _recordedAudioAppFile != null) {
            // If transcript is empty but we have audio, still call with null transcript but with AppFile
            widget.onTranscriptReady('', _recordedAudioAppFile);
        }
      }
    } catch (e) {
      debugPrint('Error processing recording: $e');
      if (mounted) {
        setState(() {
          _state = RecordingState.transcribeFailed;
          _isProcessing = false;
        });
      }
      AppSnackbar.showSnackbarError('Failed to transcribe audio');
    }
  }

  void _retry() {
    // If we have an AppFile, it means WAV conversion was done. Retry transcription.
    if (_recordedAudioAppFile != null) { 
      _processRecording(); 
    } else if (_audioChunks.isNotEmpty && _recordedAudioAppFile == null) {
      // If we have chunks but no AppFile (e.g. first attempt failed before AppFile creation or WAV conversion)
      _processRecording(); // This will create AppFile from chunks and then transcribe
    } else { // No audio data at all, or some other unexpected state
       _startRecording(); // Default to starting a new recording
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case RecordingState.recording:
        return Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: widget.onClose,
              ),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: CustomPaint(
                    painter: AudioWavePainter(
                      levels: _audioLevels,
                      timestamp: DateTime.now(),
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: _processRecording,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  margin: const EdgeInsets.only(top: 10, bottom: 10, right: 6, left: 16),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check,
                    color: Colors.black,
                    size: 20.0,
                  ),
                ),
              ),
            ],
          ),
        );

      case RecordingState.transcribing:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Shimmer.fromColors(
                baseColor: Colors.grey.shade800,
                highlightColor: Colors.white,
                child: const Text(
                  'Transcribing...',
                  style: TextStyle(
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        );

      case RecordingState.transcribeSuccess:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _transcript,
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: widget.onClose,
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.white),
                  onPressed: () {
                      // Pass transcript and the recorded AppFile
                      widget.onTranscriptReady(_transcript, _recordedAudioAppFile);
                  }
                ),
              ],
            ),
          ],
        );

      case RecordingState.transcribeFailed:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Error',
                style: TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: CustomPaint(
                    painter: AudioWavePainter(
                      levels: _audioLevels,
                      timestamp: DateTime.now(),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  GestureDetector(
                      onTap: _retry,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        margin: const EdgeInsets.only(left: 10, right: 0, top: 10, bottom: 10),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          color: Colors.black,
                          Icons.refresh,
                          size: 20.0,
                        ),
                      )),
                  GestureDetector(
                    onTap: widget.onClose,
                    child: Container(
                      padding: const EdgeInsets.only(left: 14, right: 0, top: 14, bottom: 14),
                      child: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      default:
        return const SizedBox.shrink();
    }
  }
}

class AudioWavePainter extends CustomPainter {
  final List<double> levels;
  // Add timestamp to control repaint frequency
  final DateTime timestamp;

  AudioWavePainter({
    required this.levels,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 4 // Slightly thicker for better visibility
      ..strokeCap = StrokeCap.round;

    final width = size.width;
    final height = size.height;
    final barWidth = width / levels.length / 2;

    for (int i = 0; i < levels.length; i++) {
      final x = i * (barWidth * 2) + barWidth;

      // Use the level directly for more accurate RMS representation
      final level = levels[i];
      final barHeight = level * height * 0.8;

      final topY = height / 2 - barHeight / 2;
      final bottomY = height / 2 + barHeight / 2;

      // Draw only the individual bars with rounded caps
      canvas.drawLine(
        Offset(x, topY),
        Offset(x, bottomY),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant AudioWavePainter oldDelegate) {
    return true;
  }
}
