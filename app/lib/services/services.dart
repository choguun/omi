import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/sockets.dart';
import 'package:omi/services/wals.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:opus_dart/opus_dart.dart';

class ServiceManager {
  late IMicRecorderService _mic;
  late IDeviceService _device;
  late ISocketService _socket;
  late IWalService _wal;
  late ISystemAudioRecorderService _systemAudio;

  static ServiceManager? _instance;

  static ServiceManager _create() {
    ServiceManager sm = ServiceManager();
    if (kIsWeb) {
      sm._mic = MicRecorderService(); // Use MicRecorderService for web
    } else {
      sm._mic = MicRecorderBackgroundService(
        runner: BackgroundService(),
      );
    }
    sm._device = DeviceService();
    sm._socket = SocketServicePool();
    sm._wal = WalService();
    if (!kIsWeb && Platform.isMacOS) {
      sm._systemAudio = MacSystemAudioRecorderService();
    }

    return sm;
  }

  static ServiceManager instance() {
    if (_instance == null) {
      throw Exception("Service manager is not initiated");
    }

    return _instance!;
  }

  IMicRecorderService get mic => _mic;

  IDeviceService get device => _device;

  ISocketService get socket => _socket;

  IWalService get wal => _wal;

  ISystemAudioRecorderService get systemAudio {
    if (kIsWeb || !Platform.isMacOS) {
      throw Exception("System audio recording is only available on macOS");
    }
    return _systemAudio;
  }

  static void init() {
    if (_instance != null) {
      throw Exception("Service manager is initiated");
    }
    _instance = ServiceManager._create();
  }

  Future<void> start() async {
    _device.start();
    _wal.start();
    if (!kIsWeb && Platform.isMacOS) {
      // TODO: Decide if system audio should start automatically or be user-initiated
      // await _systemAudio.start();
    }
  }

  void deinit() async {
    await _wal.stop();
    _mic.stop();
    _device.stop();
    if (!kIsWeb && Platform.isMacOS) {
      _systemAudio.stop();
    }
  }
}

enum BackgroundServiceStatus {
  initiated,
  running,
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  return true;
}

@pragma('vm:entry-point')
Future onStart(ServiceInstance service) async {
  // Recorder
  MicRecorderService? recorder;
  service.on('recorder.start').listen((event) async {
    recorder = MicRecorderService(isInBG: !kIsWeb && Platform.isAndroid ? true : false);
    recorder?.start(onByteReceived: (bytes) {
      Uint8List audioBytes = bytes;
      List<dynamic> audioBytesList = audioBytes.toList();
      service.invoke("recorder.ui.audioBytes", {"data": audioBytesList});
    }, onStop: () {
      service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
    }, onRecording: () {
      service.invoke("recorder.ui.stateUpdate", {"state": 'recording'});
    });
  });

  service.on('recorder.stop').listen((event) async {
    service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
    recorder?.stop();
  });

  service.on('stop').listen((event) async {
    if (recorder?.status != RecorderServiceStatus.stop) {
      recorder?.stop();
    }
    service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
    service.stopSelf();
  });

  // watchdog
  var pongAt = DateTime.now();
  service.on('pong').listen((event) async {
    pongAt = DateTime.now();
  });
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    if (pongAt.isBefore(DateTime.now().subtract(const Duration(seconds: 15)))) {
      // retire
      if (recorder?.status != RecorderServiceStatus.stop) {
        recorder?.stop();
      }
      service.invoke("recorder.ui.stateUpdate", {"state": 'stopped'});
      service.stopSelf();
      return;
    }
    service.invoke("ui.ping");
  });
}

class BackgroundService {
  late FlutterBackgroundService _service;
  BackgroundServiceStatus? _status;

  BackgroundServiceStatus? get status => _status;

  Future<void> init() async {
    _service = FlutterBackgroundService();
    _status = BackgroundServiceStatus.initiated;

    await _service.configure(
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
      androidConfiguration: AndroidConfiguration(
        autoStart: false,
        onStart: onStart,
        isForegroundMode: true,
        autoStartOnBoot: false,
        foregroundServiceType: AndroidForegroundType.microphone,
      ),
    );

    _status = BackgroundServiceStatus.initiated;
  }

  Future<void> ensureRunning() async {
    await init();
    await start();
  }

  Future<void> start() async {
    _service.startService();

    // status
    if (await _service.isRunning()) {
      _status = BackgroundServiceStatus.running;
    }

    // heartbeat
    _service.on('ui.ping').listen((event) {
      _service.invoke("pong");
    });
  }

  void stop() {
    debugPrint("invoke stop");
    _service.invoke("stop");
  }

  void onStop(ServiceInstance instance) async {
    _service.invoke("recorder.stateUpdate", {"state": 'stopped'});
    instance.stopSelf();
  }

  void startRecorder({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
  }) {
    StreamSubscription? recordAudioByteStream = _service.on('recorder.ui.audioBytes').listen((event) {
      Uint8List bytes = Uint8List.fromList(event!['data'].cast<int>());
      onByteReceived(bytes);
    });
    StreamSubscription? recordStateStream;
    recordStateStream = _service.on('recorder.ui.stateUpdate').listen((event) {
      if (event!['state'] == 'recording') {
        if (onRecording != null) {
          onRecording();
        }
      } else if (event['state'] == 'initializing') {
        if (onInitializing != null) {
          onInitializing();
        }
      } else if (event['state'] == 'stopped') {
        // Close streams
        recordAudioByteStream.cancel();
        recordStateStream?.cancel();

        // Callback
        if (onStop != null) {
          onStop();
        }
      }
    });

    // tell service > start record
    _service.invoke("recorder.start");
  }

  void stopRecorder() {
    _service.invoke("recorder.stop");
  }
}

enum RecorderServiceStatus {
  initialising,
  recording,
  stop,
}

abstract class IMicRecorderService {
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
  });
  void stop();
  int? get actualSampleRate;
}

class MicRecorderBackgroundService implements IMicRecorderService {
  late BackgroundService _runner;

  MicRecorderBackgroundService({required BackgroundService runner}) {
    _runner = runner;
  }

  @override
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
  }) async {
    await _runner.ensureRunning();

    _runner.startRecorder(
      onByteReceived: onByteReceived,
      onRecording: onRecording,
      onStop: onStop,
      onInitializing: onInitializing,
    );

    return;
  }

  @override
  void stop() {
    _runner.stopRecorder();
  }

  @override
  int? get actualSampleRate => 16000;
}

class MicRecorderService implements IMicRecorderService {
  RecorderServiceStatus? _status;
  int? _actualSampleRate;

  late FlutterSoundRecorder _recorder;
  StreamController<Uint8List>? _pcmController;
  StreamSubscription? _opusSubscription;

  Function(Uint8List bytes)? _onByteReceived;
  Function? _onRecording;
  Function? _onStop;
  Function? _onInitializing;

  bool _isInBG = false;

  MicRecorderService({bool isInBG = false}) {
    _recorder = FlutterSoundRecorder();
    _isInBG = isInBG;
  }

  get status => _status;

  @override
  int? get actualSampleRate => _actualSampleRate;

  @override
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    Function()? onRecording,
    Function()? onStop,
    Function()? onInitializing,
  }) async {
    if (_status == RecorderServiceStatus.recording) {
      throw Exception("Recorder is recording, please stop it before start new recording.");
    }
    if (_status == RecorderServiceStatus.initialising) {
      throw Exception("Recorder is initialising");
    }

    // Assign core callbacks first
    _onByteReceived = onByteReceived;
    _onRecording = onRecording;
    _onStop = onStop;
    _onInitializing = onInitializing;

    _status = RecorderServiceStatus.initialising;
    if (_onInitializing != null) _onInitializing!();

    await _recorder.openRecorder(isBGService: _isInBG);

    if (kIsWeb) {
      _actualSampleRate = 48000; // 48kHz for web
    } else {
      _actualSampleRate = 16000;
    }
    debugPrint('Using effective sample rate for PCM capture: $_actualSampleRate');

    _pcmController = StreamController<Uint8List>();

    await _recorder.startRecorder(
      toStream: _pcmController!.sink,
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: _actualSampleRate,
    );

    if (_onRecording != null) _onRecording!();
    _status = RecorderServiceStatus.recording;

    final opusStream = _pcmController!.stream.cast<List<int>>().transform(
      StreamOpusEncoder.bytes(
        floatInput: false,
        sampleRate: _actualSampleRate!,
        channels: 1,
        application: Application.audio,
        frameTime: FrameTime.ms20,
        copyOutput: true,
        fillUpLastFrame: true,
      ),
    );

    _opusSubscription = opusStream.listen(
      (opusPacket) {
        if (opusPacket == null) {
          debugPrint('[MicRecorderService] Null Opus packet received.');
          return;
        }
        debugPrint('[MicRecorderService] Raw Opus packet received, length: ${opusPacket.length}');

        final opusData = Uint8List.fromList(opusPacket);
        if (opusData.isEmpty) {
          debugPrint('[MicRecorderService] Empty Opus data after conversion.');
          return; // Don't send empty packets
        }
        final lengthBytes = ByteData(4);
        lengthBytes.setUint32(0, opusData.lengthInBytes, Endian.little);

        final framedPacket = Uint8List.fromList(
          lengthBytes.buffer.asUint8List() + opusData,
        );
        debugPrint('[MicRecorderService] Sending framed Opus packet, frame content length: ${opusData.lengthInBytes}, total length: ${framedPacket.lengthInBytes}');

        if (_onByteReceived != null) {
          _onByteReceived!(framedPacket);
        }
      },
      onError: (error) {
        debugPrint("[MicRecorderService] Opus encoding stream error: $error");
      },
      onDone: () {
        debugPrint("[MicRecorderService] Opus encoding stream done.");
      },
    );
    return;
  }

  @override
  void stop() {
    if (_status != RecorderServiceStatus.recording && _status != RecorderServiceStatus.initialising) {
      debugPrint("Recorder not recording or initialising. Stop called in state: $_status");
      return;
    }

    _recorder.stopRecorder().then((_) {
      debugPrint("FlutterSoundRecorder stopped.");
    }).catchError((e) {
      debugPrint("Error stopping FlutterSoundRecorder: $e");
    });

    _opusSubscription?.cancel();
    _pcmController?.close();

    _status = RecorderServiceStatus.stop;
    if (_onStop != null) {
      _onStop!();
    }

    _onByteReceived = null;
    _onStop = null;
    _onRecording = null;
    _onInitializing = null;
    _opusSubscription = null;
    _pcmController = null;
  }
}

abstract class ISystemAudioRecorderService {
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    required Function(Map<String, dynamic> format) onFormatReceived,
    Function()? onRecording,
    Function()? onStop,
    Function(String error)? onError,
  });
  void stop();
  // TODO: Add status property
}

class MacSystemAudioRecorderService implements ISystemAudioRecorderService {
  static const MethodChannel _channel = MethodChannel('screenCapturePlatform');
  Function(Uint8List bytes)? _onByteReceived;
  Function(Map<String, dynamic> format)? _onFormatReceived;
  Function()? _onRecording;
  Function()? _onStop;
  Function(String error)? _onError;

  // To keep track of recording state from Dart's perspective
  bool _isRecording = false;

  MacSystemAudioRecorderService() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'audioFrame':
        if (_onByteReceived != null && call.arguments is Uint8List) {
          _onByteReceived!(call.arguments);
        }
        break;
      case 'audioFormat':
        debugPrint("audioFormat: ${call.arguments}");
        if (_onFormatReceived != null && call.arguments is Map) {
          final Map<String, dynamic> format = Map<String, dynamic>.from(call.arguments as Map);
          _onFormatReceived!(format);
        }
        break;
      case 'audioStreamEnded':
        debugPrint("audioStreamEnded");
        _isRecording = false;
        if (_onStop != null) {
          _onStop!();
        }
        _clearCallbacks(); // Clear callbacks after stopping
        break;
      case 'captureError':
      case 'converterError':
        debugPrint("captureError: ${call.arguments}");
        _isRecording = false;
        if (_onError != null && call.arguments is String) {
          _onError!(call.arguments as String);
        }
        if (_onStop != null) {
          _onStop!(); // Also call onStop if there's an error
        }
        _clearCallbacks(); // Clear callbacks after error
        break;
      default:
        debugPrint('MacSystemAudioRecorderService: Unhandled method call: \${call.method}');
    }
  }

  void _clearCallbacks() {
    _onByteReceived = null;
    _onFormatReceived = null;
    _onRecording = null;
    _onStop = null;
    _onError = null;
  }

  @override
  Future<void> start({
    required Function(Uint8List bytes) onByteReceived,
    required Function(Map<String, dynamic> format) onFormatReceived,
    Function()? onRecording,
    Function()? onStop,
    Function(String error)? onError,
  }) async {
    if (_isRecording) {
      // Potentially call onError or throw if already recording
      onError?.call("Already recording. Please stop the current recording first.");
      return;
    }

    // Store the callbacks
    _onByteReceived = onByteReceived;
    _onFormatReceived = onFormatReceived;
    _onRecording = onRecording;
    _onStop = onStop;
    _onError = onError;

    try {
      await _channel.invokeMethod('start');
      _isRecording = true; // Assume recording starts successfully
      if (_onRecording != null) {
        _onRecording!();
      }
    } catch (e) {
      debugPrint("Error starting system audio recording: \$e");
      _isRecording = false;
      if (_onError != null) {
        _onError!(e.toString());
      }
      if (_onStop != null) {
        // Ensure onStop is called if start fails immediately
        _onStop!();
      }
      _clearCallbacks(); // Clear callbacks if start fails
    }
  }

  @override
  void stop() {
    if (!_isRecording) {
      // Optionally, log or call onError if trying to stop when not recording
      // _onError?.call("Not recording.");
      // return;
      // Or silently do nothing if preferred
    }
    try {
      _channel.invokeMethod('stop');
      // _isRecording will be set to false and _onStop called
      // when 'audioStreamEnded' is received from native code.
      // If the invokeMethod 'stop' itself fails, we might not get 'audioStreamEnded'.
    } catch (e) {
      debugPrint("Error stopping system audio recording: \$e");
      // If stopping failed, force cleanup on Dart side.
      _isRecording = false;
      if (_onError != null) {
        _onError!(e.toString());
      }
      if (_onStop != null) {
        _onStop!();
      }
      _clearCallbacks();
    }
  }
}
