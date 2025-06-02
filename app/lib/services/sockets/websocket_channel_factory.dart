import 'package:web_socket_channel/web_socket_channel.dart';

typedef WebSocketChannelFactory = WebSocketChannel Function(
  String url, {
  Map<String, dynamic>? headers,
  Duration? pingInterval,
  Duration? connectTimeout,
});

WebSocketChannel createWebSocketChannel(
  String url, {
  Map<String, dynamic>? headers,
  Duration? pingInterval,
  Duration? connectTimeout,
}) {
  throw UnsupportedError('Cannot create a web socket channel without a platform-specific implementation.');
} 