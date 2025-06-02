import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' if (dart.library.html) 'package:omi/utils/stubs/dart_io_web.dart' as DART_IO;

import 'package:flutter/material.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/message.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/string_utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:omi/utils/app_file.dart';
import 'package:http_parser/http_parser.dart' as http_parser;

Future<List<ServerMessage>> getMessagesServer({
  String? pluginId,
  bool dropdownSelected = false,
}) async {
  if (pluginId == 'no_selected') pluginId = null;
  // TODO: Add pagination
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/messages?plugin_id=${pluginId ?? ''}&dropdown_selected=$dropdownSelected',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    var decodedBody = jsonDecode(body) as List<dynamic>;
    if (decodedBody.isEmpty) {
      return [];
    }
    var messages = decodedBody.map((conversation) => ServerMessage.fromJson(conversation)).toList();
    debugPrint('getMessages length: ${messages.length}');
    return messages;
  }
  return [];
}

Future<List<ServerMessage>> clearChatServer({String? pluginId}) async {
  if (pluginId == 'no_selected') pluginId = null;
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/messages?plugin_id=${pluginId ?? ''}',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) throw Exception('Failed to delete chat');
  if (response.statusCode == 200) {
    return [ServerMessage.fromJson(jsonDecode(response.body))];
  } else {
    throw Exception('Failed to delete chat');
  }
}

ServerMessageChunk? parseMessageChunk(String line, String messageId) {
  if (line.startsWith('think: ')) {
    return ServerMessageChunk(messageId, line.substring(7).replaceAll("__CRLF__", "\n"), MessageChunkType.think);
  }

  if (line.startsWith('data: ')) {
    return ServerMessageChunk(messageId, line.substring(6).replaceAll("__CRLF__", "\n"), MessageChunkType.data);
  }

  if (line.startsWith('done: ')) {
    var text = decodeBase64(line.substring(6));
    return ServerMessageChunk(messageId, text, MessageChunkType.done,
        message: ServerMessage.fromJson(json.decode(text)));
  }

  if (line.startsWith('message: ')) {
    var text = decodeBase64(line.substring(9));
    return ServerMessageChunk(messageId, text, MessageChunkType.message,
        message: ServerMessage.fromJson(json.decode(text)));
  }

  return null;
}

Stream<ServerMessageChunk> sendMessageStreamServer(String text, {String? appId, List<String>? filesId, List<AppFile>? appFiles, bool? isVoice}) async* {
  var url = '${Env.apiBaseUrl}v2/messages?plugin_id=$appId';
  if (appId == null || appId.isEmpty || appId == 'null' || appId == 'no_selected') {
    url = '${Env.apiBaseUrl}v2/messages';
  }

  http.Client client = http.Client();
  http.BaseRequest request;
  
  try {
    if (appFiles != null && appFiles.isNotEmpty) {
      // This is a multipart request if new files are being sent
      var multipartRequest = http.MultipartRequest('POST', Uri.parse(url));
      multipartRequest.headers['Authorization'] = await getAuthHeader();
      // Add text and existing file_ids as fields
      multipartRequest.fields['text'] = text;
      if (filesId != null && filesId.isNotEmpty) {
        // Server needs to handle receiving file_ids as part of multipart form data
        // This might require backend changes if it only expects file_ids with JSON body.
        // For now, sending as a comma-separated string or multiple fields.
        multipartRequest.fields['file_ids'] = filesId.join(','); // Or handle as list on server
      }
      if (appId != null) multipartRequest.fields['plugin_id'] = appId;
      if (isVoice != null) multipartRequest.fields['is_voice'] = isVoice.toString();

      for (var appFile in appFiles) {
        final bytes = await appFile.readAsBytes();
        multipartRequest.files.add(http.MultipartFile.fromBytes(
          'files', // Assuming server expects new files under this key
          bytes,
          filename: appFile.name,
          // contentType: MediaType.parse(appFile.mimeType ?? 'application/octet-stream'), // Optional
        ));
      }
      request = multipartRequest;
    } else {
      // This is a JSON request if no new files, or only file_ids
      var jsonRequest = http.Request('POST', Uri.parse(url));
      jsonRequest.headers['Authorization'] = await getAuthHeader();
      jsonRequest.headers['Content-Type'] = 'application/json';
      jsonRequest.body = jsonEncode({
        'text': text,
        'file_ids': filesId,
        'plugin_id': appId, // Redundant if in URL, but can be here
        'is_voice': isVoice,
      });
      request = jsonRequest;
    }

    final streamedResponse = await client.send(request);

    if (streamedResponse.statusCode != 200) {
      Logger.error('Failed to send message: ${streamedResponse.statusCode}, Body: ${await streamedResponse.stream.bytesToString()}');
      yield ServerMessageChunk.failedMessage();
      return;
    }

    var buffers = <String>[];
    var messageId = "1000"; // Default new message
    await for (var data in streamedResponse.stream.transform(utf8.decoder)) {
      var lines = data.split('\n\n');
      for (var line in lines.where((line) => line.isNotEmpty)) {
        if (line.length >= 1024) { buffers.add(line); continue; }
        if (buffers.isNotEmpty) { line = (buffers..add(line)).join(); buffers.clear(); }
        var messageChunk = parseMessageChunk(line, messageId);
        if (messageChunk != null) yield messageChunk;
      }
    }
    if (buffers.isNotEmpty) {
      var mc = parseMessageChunk(buffers.join(), messageId);
      if (mc != null) yield mc;
    }
  } catch (e, s) {
    Logger.error('Error sending message stream: $e\n$s');
    yield ServerMessageChunk.failedMessage();
  } finally {
    client.close();
  }
}

Future<ServerMessage> getInitialAppMessage(String? appId) {
  return makeApiCall(
    url: '${Env.apiBaseUrl}v2/initial-message?app_id=$appId',
    headers: {},
    method: 'POST',
    body: '',
  ).then((response) {
    if (response == null) throw Exception('Failed to send message');
    if (response.statusCode == 200) {
      return ServerMessage.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to send message');
    }
  });
}

Stream<ServerMessageChunk> sendVoiceMessageStreamServer(List<AppFile> appFiles) async* {
  // This function is now more specific to voice, implying appFiles are the primary content.
  // If text or other parameters are needed, consider merging logic or adding params.
  var url = '${Env.apiBaseUrl}v2/voice-messages'; 
  http.Client client = http.Client();
  var request = http.MultipartRequest('POST', Uri.parse(url));
  request.headers['Authorization'] = await getAuthHeader();

  if (appFiles.isEmpty) {
    Logger.warning('sendVoiceMessageStreamServer called with no files.');
    // yield ServerMessageChunk.failedMessage(); // Or handle as appropriate
    return;
  }

  for (var appFile in appFiles) {
    final bytes = await appFile.readAsBytes();
    request.files.add(http.MultipartFile.fromBytes(
      'files', // Server expects files under this key
      bytes,
      filename: appFile.name,
      contentType: http_parser.MediaType.parse(appFile.mimeType ?? 'audio/wav'),
    ));
  }
  
  try {
    final streamedResponse = await client.send(request);

    if (streamedResponse.statusCode != 200) {
      Logger.error('Failed to send voice message: ${streamedResponse.statusCode}, Body: ${await streamedResponse.stream.bytesToString()}');
      yield ServerMessageChunk.failedMessage();
      return;
    }

    var buffers = <String>[];
    var messageId = "1000"; 
    await for (var data in streamedResponse.stream.transform(utf8.decoder)) {
      var lines = data.split('\n\n');
      for (var line in lines.where((line) => line.isNotEmpty)) {
        if (line.length >= 1024) { buffers.add(line); continue; }
        if (buffers.isNotEmpty) { line = (buffers..add(line)).join(); buffers.clear(); }
        var messageChunk = parseMessageChunk(line, messageId);
        if (messageChunk != null) yield messageChunk;
      }
    }
    if (buffers.isNotEmpty) {
      var mc = parseMessageChunk(buffers.join(), messageId);
      if (mc != null) yield mc;
    }
  } catch (e, s) {
    Logger.error('Error sending voice message stream: $e\n$s');
    yield ServerMessageChunk.failedMessage();
  } finally {
    client.close();
  }
}

Future<List<MessageFile>> uploadFilesServer(List<AppFile> appFiles, {String? appId}) async {
  if (kIsWeb) {
    return uploadFilesServerWeb(appFiles, appId: appId);
  } else {
    return uploadFilesServerMobile(appFiles, appId: appId);
  }
}

Future<List<MessageFile>> uploadFilesServerMobile(List<AppFile> appFiles, {String? appId}) async {
  var request = http.MultipartRequest(
    'POST',
    Uri.parse('${Env.apiBaseUrl}v2/files?app_id=${appId ?? ''}'),
  );
  request.headers.addAll({'Authorization': await getAuthHeader()});

  for (var appFile in appFiles) {
    if (appFile.path == null) {
      Logger.error("File path is null for upload on mobile for file: ${appFile.name}");
      continue; // Skip this file or throw error
    }
    // Use DART_IO.File for mobile specific operations if any, but MultipartFile.fromPath is fine.
    request.files.add(await http.MultipartFile.fromPath('files', appFile.path!, filename: appFile.name));
  }

  if (request.files.isEmpty && appFiles.isNotEmpty) {
      Logger.error('No files could be prepared for mobile upload despite input.');
      return []; // Or throw an error
  }
  if (request.files.isEmpty && appFiles.isEmpty) return [];

  var response = await request.send();
  if (response.statusCode == 200) {
    var body = await response.stream.bytesToString();
    var decodedBody = jsonDecode(body) as List<dynamic>;
    return decodedBody.map((file) => MessageFile.fromJson(file)).toList();
  } else {
    Logger.error('Failed to upload files (mobile): ${response.statusCode}, Body: ${await response.stream.bytesToString()}');
    throw Exception('Failed to upload files (mobile)');
  }
}

Future<List<MessageFile>> uploadFilesServerWeb(List<AppFile> appFiles, {String? appId}) async {
  var request = http.MultipartRequest(
    'POST',
    Uri.parse('${Env.apiBaseUrl}v2/files?app_id=${appId ?? ''}'),
  );
  request.headers.addAll({'Authorization': await getAuthHeader()});

  for (var appFile in appFiles) {
    final bytes = await appFile.readAsBytes();
    request.files.add(http.MultipartFile.fromBytes('files', bytes, filename: appFile.name));
  }
  if (request.files.isEmpty && appFiles.isNotEmpty) {
      Logger.error('No files could be prepared for web upload despite input.');
      return []; // Or throw an error
  }
  if (request.files.isEmpty && appFiles.isEmpty) return [];

  var response = await request.send();
  if (response.statusCode == 200) {
    var body = await response.stream.bytesToString();
    var decodedBody = jsonDecode(body) as List<dynamic>;
    return decodedBody.map((file) => MessageFile.fromJson(file)).toList();
  } else {
    Logger.error('Failed to upload files (web): ${response.statusCode}, Body: ${await response.stream.bytesToString()}');
    throw Exception('Failed to upload files (web)');
  }
}

Future<String?> getPresignedUrl(String fileId) async {
  try {
    final response = await makeApiCall(
      url: '${Env.apiBaseUrl}v2/files/$fileId/presigned-url',
      headers: {},
      method: 'GET',
      body: '',
    );
    if (response != null && response.statusCode == 200) {
      final decodedBody = jsonDecode(response.body);
      return decodedBody['url'];
    }
  } catch (e) {
    Logger.error('Error getting presigned URL: $e');
  }
  return null;
}

Future reportMessageServer(String messageId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/messages/$messageId/report',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) throw Exception('Failed to report message');
  if (response.statusCode != 200) {
    throw Exception('Failed to report message');
  }
}

Future<String> transcribeVoiceMessage(AppFile audioFile) async {
  try {
    var request = http.MultipartRequest(
      'POST',
      Uri.parse('${Env.apiBaseUrl}v2/voice-message/transcribe'),
    );
    request.headers.addAll({'Authorization': await getAuthHeader()});

    if (kIsWeb) {
      final bytes = await audioFile.readAsBytes();
      request.files.add(http.MultipartFile.fromBytes('files', bytes, filename: audioFile.name));
    } else {
      if (audioFile.path == null) {
         Logger.error('File path is null for transcribe on mobile');
         throw Exception('File path is null for transcribe on mobile');
      }
      request.files.add(await http.MultipartFile.fromPath('files', audioFile.path!));
    }

    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['transcript'] ?? '';
    } else {
      debugPrint('Failed to transcribe voice message: ${response.statusCode} ${response.body}');
      throw Exception('Failed to transcribe voice message');
    }
  } catch (e) {
    debugPrint('Error transcribing voice message: $e');
    throw Exception('Error transcribing voice message: $e');
  }
}
