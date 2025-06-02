import 'package:web_socket_channel/io.dart' as io;
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel createWebSocketChannel(
  String url, {
  Map<String, dynamic>? headers,
  Duration? pingInterval,
  Duration? connectTimeout,
}) {
  return io.IOWebSocketChannel.connect(
    url,
    headers: headers,
    pingInterval: pingInterval,
    connectTimeout: connectTimeout,
  );
} 