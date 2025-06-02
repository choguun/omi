import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

enum MessageSender { ai, human }

enum MessageType {
  text('text'),
  daySummary('day_summary'),
  error('error'),
  ;

  final String value;

  const MessageType(this.value);

  static MessageType valuesFromString(String value) {
    return MessageType.values.firstWhereOrNull((e) => e.value == value) ?? MessageType.text;
  }
}

class MessageConversationStructured {
  String title;
  String emoji;

  MessageConversationStructured(this.title, this.emoji);

  static MessageConversationStructured fromJson(Map<String, dynamic> json) {
    return MessageConversationStructured(json['title'], json['emoji']);
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'emoji': emoji,
    };
  }
}

class MessageConversation {
  String id;
  DateTime createdAt;
  MessageConversationStructured structured;

  MessageConversation(this.id, this.createdAt, this.structured);

  static MessageConversation fromJson(Map<String, dynamic> json) {
    return MessageConversation(
      json['id'],
      DateTime.parse(json['created_at']).toLocal(),
      MessageConversationStructured.fromJson(json['structured']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'created_at': createdAt.toUtc().toIso8601String(),
      'structured': structured.toJson(),
    };
  }
}

class MessageFile {
  String id;
  String? openaiFileId;
  String? thumbnail;
  String? thumbnailName;
  String name;
  String mimeType;
  DateTime createdAt;
  int size;

  String? localPath;
  Uint8List? bytes;
  String? appId;

  MessageFile({
    required this.id,
    this.openaiFileId,
    this.thumbnail,
    this.thumbnailName,
    required this.name,
    required this.mimeType,
    required this.createdAt,
    required this.size,
    this.localPath,
    this.bytes,
    this.appId,
  });

  static MessageFile fromJson(Map<String, dynamic> json) {
    return MessageFile(
      id: json['id'],
      openaiFileId: json['openai_file_id'],
      thumbnail: json['thumbnail'],
      name: json['name'],
      mimeType: json['mime_type'],
      createdAt: DateTime.parse(json['created_at']).toLocal(),
      thumbnailName: json['thumb_name'],
      size: json['size'] ?? 0,
      appId: json['app_id'],
    );
  }

  static List<MessageFile> fromJsonList(List<dynamic> json) {
    return json.map((e) => MessageFile.fromJson(e)).toList();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'openai_file_id': openaiFileId,
      'thumbnail': thumbnail,
      'name': name,
      'mime_type': mimeType,
      'created_at': createdAt.toUtc().toIso8601String(),
      'thumb_name': thumbnailName,
      'size': size,
      'app_id': appId,
    };
  }

  String mimeTypeToFileType() {
    if (mimeType.contains('image')) {
      return 'image';
    } else {
      return 'file';
    }
  }
}

class ServerMessage {
  String id;
  DateTime createdAt;
  String text;
  MessageSender sender;
  MessageType type;

  String? appId;
  bool fromIntegration;

  List<MessageFile> files;
  List filesId;

  List<MessageConversation> memories;
  bool askForNps = false;

  List<String> thinkings = [];
  bool isVoice;
  MessageFile? localAudioFile;

  ServerMessage(
    this.id,
    this.createdAt,
    this.text,
    this.sender,
    this.type,
    this.appId,
    this.fromIntegration,
    this.files,
    this.filesId,
    this.memories, {
    this.askForNps = false,
    this.isVoice = false,
    this.localAudioFile,
  });

  static ServerMessage fromJson(Map<String, dynamic> json) {
    return ServerMessage(
      json['id'],
      DateTime.parse(json['created_at']).toLocal(),
      json['text'] ?? "",
      MessageSender.values.firstWhere((e) => e.toString().split('.').last == json['sender'], orElse: () => MessageSender.ai),
      MessageType.valuesFromString(json['type']),
      json['plugin_id'],
      json['from_integration'] ?? false,
      ((json['files'] ?? []) as List<dynamic>).map((m) => MessageFile.fromJson(m)).toList(),
      (json['files_id'] ?? []).map((m) => m.toString()).toList(),
      ((json['memories'] ?? []) as List<dynamic>).map((m) => MessageConversation.fromJson(m)).toList(),
      askForNps: json['ask_for_nps'] ?? false,
      isVoice: json['is_voice'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'created_at': createdAt.toUtc().toIso8601String(),
      'text': text,
      'sender': sender.toString().split('.').last,
      'type': type.value,
      'plugin_id': appId,
      'from_integration': fromIntegration,
      'memories': memories.map((m) => m.toJson()).toList(),
      'ask_for_nps': askForNps,
      'files': files.map((m) => m.toJson()).toList(),
      'is_voice': isVoice,
    };
  }

  ServerMessage copyWith({
    String? id,
    DateTime? createdAt,
    String? text,
    MessageSender? sender,
    MessageType? type,
    String? appId,
    bool? fromIntegration,
    List<MessageFile>? files,
    List? filesId,
    List<MessageConversation>? memories,
    bool? askForNps,
    List<String>? thinkings,
    bool? isVoice,
    MessageFile? localAudioFile,
    bool setLocalAudioFileToNull = false,
  }) {
    return ServerMessage(
      id ?? this.id,
      createdAt ?? this.createdAt,
      text ?? this.text,
      sender ?? this.sender,
      type ?? this.type,
      appId ?? this.appId,
      fromIntegration ?? this.fromIntegration,
      files ?? this.files,
      filesId ?? this.filesId,
      memories ?? this.memories,
      askForNps: askForNps ?? this.askForNps,
      isVoice: isVoice ?? this.isVoice,
      localAudioFile: setLocalAudioFileToNull ? null : (localAudioFile ?? this.localAudioFile),
    )..thinkings = thinkings ?? this.thinkings;
  }

  bool areFilesOfSameType() {
    if (files.isEmpty) {
      return true;
    }

    final firstType = files.first.mimeTypeToFileType();
    return files.every((element) => element.mimeTypeToFileType() == firstType);
  }

  static ServerMessage empty({String? appId}) {
    return ServerMessage(
      const Uuid().v4(),
      DateTime.now(),
      '',
      MessageSender.ai,
      MessageType.text,
      appId,
      false,
      [],
      [],
      [],
      isVoice: false,
    );
  }

  static ServerMessage failedMessage() {
    return ServerMessage(
      const Uuid().v4(),
      DateTime.now(),
      'Looks like we are having issues with the server. Please try again later.',
      MessageSender.ai,
      MessageType.text,
      null,
      false,
      [],
      [],
      [],
      isVoice: false,
    );
  }

  bool get isEmpty => id == '0000';
}

enum MessageChunkType {
  think('think'),
  data('data'),
  done('done'),
  error('error'),
  message('message'),
  ;

  final String value;

  const MessageChunkType(this.value);
}

class ServerMessageChunk {
  String messageId;
  MessageChunkType type;
  String text;
  ServerMessage? message;

  ServerMessageChunk(
    this.messageId,
    this.text,
    this.type, {
    this.message,
  });

  static ServerMessageChunk failedMessage() {
    return ServerMessageChunk(
      const Uuid().v4(),
      'Looks like we are having issues with the server. Please try again later.',
      MessageChunkType.error,
    );
  }
}
