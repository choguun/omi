import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'websocket_channel_factory.dart'
    if (dart.library.html) 'websocket_channel_factory_html.dart'
    if (dart.library.io) 'websocket_channel_factory_io.dart';
import 'package:web_socket_channel/status.dart' as socket_channel_status;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/utils/platform/platform_manager.dart';

enum PureSocketStatus { notConnected, connecting, connected, disconnected }

abstract class IPureSocketListener {
  void onConnected();
  void onMessage(dynamic message);
  void onClosed();
  void onError(Object err, StackTrace trace);

  void onInternetConnectionFailed() {}

  void onMaxRetriesReach() {}
}

abstract class IPureSocket {
  Future<bool> connect();
  Future disconnect();
  void send(dynamic message);

  void onInternetSatusChanged(InternetStatus status);

  void onMessage(dynamic message);
  void onConnected();
  void onClosed();
  void onError(Object err, StackTrace trace);
}

class PureSocketMessage {
  String? raw;
}

class PureCore {
  late InternetConnection internetConnection;

  factory PureCore() => _instance;

  /// The singleton instance of [PureCore].
  static final _instance = PureCore.createInstance();

  PureCore.createInstance() {
    internetConnection = InternetConnection.createInstance(
      useDefaultOptions: false,
      customCheckOptions: [
        InternetCheckOption(
          uri: Uri.parse('https://one.one.one.one'),
          timeout: const Duration(seconds: 12),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://icanhazip.com/'),
          timeout: const Duration(seconds: 12),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://jsonplaceholder.typicode.com/todos/1'),
          timeout: const Duration(seconds: 12),
        ),
        // InternetCheckOption(
        //   uri: Uri.parse('https://reqres.in/api/users/1'),
        //   timeout: const Duration(seconds: 12),
        // ),
      ],
    );
  }
}

class PureSocket implements IPureSocket {
  StreamSubscription<InternetStatus>? _internetStatusListener;
  InternetStatus? _internetStatus;
  Timer? _internetLostDelayTimer;

  WebSocketChannel? _channel;
  WebSocketChannel get channel {
    if (_channel == null) {
      throw Exception('Socket is not connected');
    }
    return _channel!;
  }

  PureSocketStatus _status = PureSocketStatus.notConnected;
  PureSocketStatus get status => _status;

  IPureSocketListener? _listener;

  int _retries = 0;

  String url;

  PureSocket(this.url) {
    _internetStatusListener = PureCore().internetConnection.onStatusChange.listen((InternetStatus status) {
      onInternetSatusChanged(status);
    });
  }

  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    return await _connect();
  }

  Future<bool> _connect() async {
    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      return false;
    }

    debugPrint("request wss ${url}");
    _channel = createWebSocketChannel(
      url,
      headers: {
        'Authorization': await getAuthHeader(),
      },
      pingInterval: kIsWeb ? null : const Duration(seconds: 20),
      connectTimeout: kIsWeb ? null : const Duration(seconds: 15),
    );
    if (kIsWeb) {
      // For HtmlWebSocketChannel, `ready` is not available. Connection is attempted immediately.
      // We assume connection is in progress or will shortly complete/fail.
      // The stream listeners will handle connection success/failure.
    } else {
      // For IOWebSocketChannel
      if (_channel?.ready == null) {
        return false;
      }
    }

    _status = PureSocketStatus.connecting;
    dynamic err;

    // The `ready` future is primarily for IOWebSocketChannel.
    // For HtmlWebSocketChannel, the connection attempt is made on construction.
    // Errors will come through the stream.
    if (!kIsWeb) {
      try {
        await channel.ready;
      } on TimeoutException catch (e) {
        err = e;
      } on SocketException catch (e) {
        err = e;
      } on WebSocketChannelException catch (e) {
        err = e;
      }
      if (err != null) {
        print("Error: $err");
        _status = PureSocketStatus.notConnected;
        return false;
      }
    }
    // For web, we optimistically set to connected and let stream listeners correct it if an error occurs.
    // For IO, if `ready` completes without error, we are connected.
    _status = PureSocketStatus.connected;
    _retries = 0;
    onConnected(); // Call onConnected earlier for web, as `ready` isn't awaited.

    final that = this;

    _channel?.stream.listen(
      (message) {
        if (message == "ping") {
          debugPrint(message);
          // Pong frame added manually https://www.rfc-editor.org/rfc/rfc6455#section-5.5.2
          // This manual pong might only be relevant for IOWebSocketChannel.
          // Browsers handle ping/pong automatically for HtmlWebSocketChannel.
          if (!kIsWeb) {
            _channel?.sink.add([0x8A, 0x00]);
          }
          return;
        }
        that.onMessage(message);
      },
      onError: (error, stackTrace) { // Modified to accept stackTrace
        // If an error occurs on the stream, especially for web, it might mean connection failed.
        if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected ) {
           _status = PureSocketStatus.disconnected; // Update status if connection fails
        }
        that.onError(error, stackTrace);
      },
      onDone: () {
        debugPrint("onDone");
        that.onClosed();
      },
      cancelOnError: true,
    );
    // For web, if onConnected was called optimistically and an error occurs immediately on the stream,
    // onError will handle setting the status to disconnected.
    return true;
  }

  @override
  Future disconnect() async {
    if (_status == PureSocketStatus.connected) {
      // Warn: should not use await cause dead end by socket closed.
      _channel?.sink.close(socket_channel_status.normalClosure);
    }
    _status = PureSocketStatus.disconnected;
    debugPrint("disconnect");
    onClosed();
  }

  Future _cleanUp() async {
    _internetLostDelayTimer?.cancel();
    _internetStatusListener?.cancel();
  }

  Future stop() async {
    await disconnect();
    await _cleanUp();
  }

  @override
  void onClosed() {
    _status = PureSocketStatus.disconnected;
    debugPrint("Socket closed");
    _listener?.onClosed();
  }

  @override
  void onError(Object err, StackTrace trace) {
    _status = PureSocketStatus.disconnected;
    print("Error: ${err}");
    debugPrintStack(stackTrace: trace);

    _listener?.onError(err, trace);
    PlatformManager.instance.instabug.reportCrash(err, trace);
  }

  @override
  void onMessage(dynamic message) {
    debugPrint("[Socket] Message $message");
    _listener?.onMessage(message);
  }

  @override
  void onConnected() {
    _listener?.onConnected();
  }

  @override
  void send(message) {
    _channel?.sink.add(message);
  }

  void _reconnect() async {
    debugPrint("[Socket] reconnect...${_retries + 1}...");
    const int initialBackoffTimeMs = 1000; // 1 second
    const double multiplier = 1.5;
    const int maxRetries = 8;

    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      debugPrint("[Socket] Can not reconnect, because socket is $_status");
      return;
    }

    await _cleanUp();

    var ok = await _connect();
    if (ok) {
      return;
    }

    // retry
    int waitInMilliseconds = pow(multiplier, _retries).toInt() * initialBackoffTimeMs;
    await Future.delayed(Duration(milliseconds: waitInMilliseconds));
    _retries++;
    if (_retries > maxRetries) {
      debugPrint("[Socket] Reach max retries $maxRetries");
      _listener?.onMaxRetriesReach();
      return;
    }
    _reconnect();
  }

  @override
  void onInternetSatusChanged(InternetStatus status) {
    debugPrint("[Socket] Internet connection changed $status socket $_status");
    _internetStatus = status;
    switch (status) {
      case InternetStatus.connected:
        if (_status == PureSocketStatus.connected || _status == PureSocketStatus.connecting) {
          return;
        }
        _reconnect();
        break;
      case InternetStatus.disconnected:
        var that = this;
        _internetLostDelayTimer?.cancel();
        _internetLostDelayTimer = Timer(const Duration(seconds: 60), () async {
          if (_internetStatus != InternetStatus.disconnected) {
            return;
          }

          await that.disconnect();
          _listener?.onInternetConnectionFailed();
        });

        break;
    }
  }
}
