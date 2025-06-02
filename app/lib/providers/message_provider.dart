import 'dart:io' if (dart.library.html) 'package:omi/utils/stubs/dart_io_web.dart';
import 'dart:typed_data'; // Added for Uint8List if used directly

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:omi/backend/http/api/messages.dart' as backend;
import 'package:omi/backend/http/api/users.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/app.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/message.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:image_picker/image_picker.dart';
import 'package:omi/utils/file.dart' as util_file; // Aliased to avoid conflict with dart:io File
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/app_file.dart'; // Import AppFile
import 'package:uuid/uuid.dart';

class MessageProvider extends ChangeNotifier {
  AppProvider? appProvider;
  List<ServerMessage> messages = [];
  bool _isNextMessageFromVoice = false;

  bool isLoadingMessages = false;
  bool hasCachedMessages = false;
  bool isClearingChat = false;
  bool showTypingIndicator = false;
  bool sendingMessage = false;

  String firstTimeLoadingText = '';

  List<AppFile> selectedFiles = [];
  List<String> selectedFileTypes = [];
  List<MessageFile> uploadedFiles = [];
  bool isUploadingFiles = false;
  Map<String, bool> uploadingFiles = {};

  void updateAppProvider(AppProvider p) {
    appProvider = p;
  }

  void setNextMessageOriginIsVoice(bool isVoice) {
    _isNextMessageFromVoice = isVoice;
  }

  void setIsUploadingFiles() {
    if (uploadingFiles.values.contains(true)) {
      isUploadingFiles = true;
    } else {
      isUploadingFiles = false;
    }
    notifyListeners();
  }

  void setMultiUploadingFileStatus(List<String> ids, bool value) {
    for (var id in ids) {
      uploadingFiles[id] = value;
    }
    setIsUploadingFiles();
    notifyListeners();
  }

  bool isFileUploading(String id) {
    return uploadingFiles[id] ?? false;
  }

  void setHasCachedMessages(bool value) {
    hasCachedMessages = value;
    notifyListeners();
  }

  void setSendingMessage(bool value) {
    sendingMessage = value;
    notifyListeners();
  }

  void setShowTypingIndicator(bool value) {
    showTypingIndicator = value;
    notifyListeners();
  }

  void setClearingChat(bool value) {
    isClearingChat = value;
    notifyListeners();
  }

  void setLoadingMessages(bool value) {
    isLoadingMessages = value;
    notifyListeners();
  }

  void captureImage() async {
    var res = await ImagePicker().pickImage(source: ImageSource.camera);
    if (res != null) {
      AppFile appFile = AppFile.fromXFile(res);
      selectedFiles.add(appFile);
      selectedFileTypes.add('image');
      await uploadFiles([appFile], appProvider?.selectedChatAppId);
      notifyListeners();
    }
  }

  void selectImage() async {
    if (selectedFiles.length >= 4) {
      AppSnackbar.showSnackbarError('You can only select up to 4 images');
      return;
    }
    List<XFile> xFiles = [];
    if (4 - selectedFiles.length == 1) {
      final image = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (image != null) xFiles.add(image);
    } else {
      xFiles = await ImagePicker().pickMultiImage(limit: 4 - selectedFiles.length);
    }
    if (xFiles.isNotEmpty) {
      List<AppFile> appFilesToAdd = xFiles.map((xf) => AppFile.fromXFile(xf)).toList();
      if (appFilesToAdd.isNotEmpty) {
        selectedFiles.addAll(appFilesToAdd);
        selectedFileTypes.addAll(appFilesToAdd.map((e) => 'image'));
        await uploadFiles(appFilesToAdd, appProvider?.selectedChatAppId);
      }
      notifyListeners();
    }
  }

  void selectFile() async {
    var result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowMultiple: true,
        allowedExtensions: ['jpeg', 'md', 'pdf', 'gif', 'doc', 'png', 'pptx', 'txt', 'xlsx', 'webp']);
    if (result != null) {
      List<AppFile> appFilesToAdd = [];
      for (var pf in result.files) {
        appFilesToAdd.add(await AppFile.fromPlatformFile(pf));
      }
      if (appFilesToAdd.isNotEmpty) {
        selectedFiles.addAll(appFilesToAdd);
        selectedFileTypes.addAll(appFilesToAdd.map((e) => 'file'));
        await uploadFiles(appFilesToAdd, appProvider?.selectedChatAppId);
      }
      notifyListeners();
    }
  }

  void clearSelectedFile(int index) {
    selectedFiles.removeAt(index);
    selectedFileTypes.removeAt(index);
    notifyListeners();
  }

  void clearSelectedFiles() {
    selectedFiles.clear();
    selectedFileTypes.clear();
    notifyListeners();
  }

  void clearUploadedFiles() {
    uploadedFiles.clear();
    notifyListeners();
  }

  Future<void> uploadFiles(List<AppFile> filesToUpload, String? appId) async {
    if (filesToUpload.isNotEmpty) {
      List<String> fileIdentifiers = filesToUpload.map((af) => af.name).toList();
      setMultiUploadingFileStatus(fileIdentifiers, true);

      List<MessageFile>? uploadedMessageFiles = await backend.uploadFilesServer(filesToUpload, appId: appId);

      if (uploadedMessageFiles != null) {
        uploadedFiles.addAll(uploadedMessageFiles);
      } else {
        // AppSnackbar.showSnackbarError('Failed to upload some files, please try again later');
      }
      setMultiUploadingFileStatus(fileIdentifiers, false);
      notifyListeners();
    }
  }

  void removeLocalMessage(String id) {
    messages.removeWhere((m) => m.id == id);
    notifyListeners();
  }

  Future refreshMessages({bool dropdownSelected = false}) async {
    setLoadingMessages(true);
    if (SharedPreferencesUtil().cachedMessages.isNotEmpty) {
      setHasCachedMessages(true);
    }
    messages = await getMessagesFromServer(dropdownSelected: dropdownSelected);
    if (messages.isEmpty) {
      messages = SharedPreferencesUtil().cachedMessages;
    } else {
      SharedPreferencesUtil().cachedMessages = messages;
      setHasCachedMessages(true);
    }
    setLoadingMessages(false);
    notifyListeners();
  }

  void setMessagesFromCache() {
    if (SharedPreferencesUtil().cachedMessages.isNotEmpty) {
      setHasCachedMessages(true);
      messages = SharedPreferencesUtil().cachedMessages;
    }
    notifyListeners();
  }

  Future<List<ServerMessage>> getMessagesFromServer({bool dropdownSelected = false}) async {
    if (!hasCachedMessages) {
      firstTimeLoadingText = 'Reading your memories...';
      notifyListeners();
    }
    setLoadingMessages(true);
    var mes = await backend.getMessagesServer(
      pluginId: appProvider?.selectedChatAppId,
      dropdownSelected: dropdownSelected,
    );
    if (!hasCachedMessages) {
      firstTimeLoadingText = 'Learning from your memories...';
      notifyListeners();
    }
    messages = mes;
    setLoadingMessages(false);
    notifyListeners();
    return messages;
  }

  Future setMessageNps(ServerMessage message, int value) async {
    await setMessageResponseRating(message.id, value);
    message.askForNps = false;
    notifyListeners();
  }

  void clearChat() async {
    setClearingChat(true);
    var mes = await backend.clearChatServer(pluginId: appProvider?.selectedChatAppId);
    messages = mes;
    setClearingChat(false);
    notifyListeners();
  }

  void addMessageLocally(String messageText, {AppFile? audioFile}) {
    List<String> fileIds = uploadedFiles.map((e) => e.id).toList();
    var currentAppId = appProvider?.selectedChatAppId;
    if (currentAppId == 'no_selected') {
      currentAppId = null;
    }

    MessageFile? localMf;
    if (audioFile != null) {
      String? filePath;
      if (!kIsWeb) {
        filePath = audioFile.path;
      }
      localMf = MessageFile(
        id: const Uuid().v4(),
        name: audioFile.name,
        mimeType: audioFile.mimeType ?? 'audio/wav',
        createdAt: DateTime.now(),
        size: 0, 
        localPath: filePath,
        appId: currentAppId,
      );
    }

    var message = ServerMessage(
      const Uuid().v4(),                              // id
      DateTime.now(),                                 // createdAt
      messageText,                                    // text
      MessageSender.human,                            // sender
      MessageType.text,                               // type
      currentAppId,                                   // appId
      false,                                          // fromIntegration
      localMf != null ? [localMf] : List<MessageFile>.from(uploadedFiles), // files - ensure correct type
      localMf != null ? [] : fileIds,                 // filesId
      [],                                             // memories
      askForNps: false,
      isVoice: _isNextMessageFromVoice || audioFile != null,
      localAudioFile: localMf,
    );

    if (messages.firstWhereOrNull((m) => m.id == message.id) != null) {
      return;
    }
    messages.insert(0, message);
    if (audioFile == null) {
      uploadedFiles.clear();
    }
    notifyListeners();
  }

  void addMessage(ServerMessage message) {
    if (messages.firstWhereOrNull((m) => m.id == message.id) != null) {
      return;
    }
    messages.insert(0, message);
    notifyListeners();
  }

  Future sendVoiceMessageStreamToServer(List<List<int>> audioBytes,
      {Function? onFirstChunkRecived, BleAudioCodec? codec}) async {
    // THIS METHOD IS LIKELY OBSOLETE OR NEEDS COMPLETE REFACTORING WITH AppFile
    // For now, commenting out to avoid compilation errors not related to current AppFile flow.
    /*
    if (kIsWeb) {
      // TODO: Implement web-specific voice message sending or show an unsupported message.
      debugPrint("Voice message streaming is not supported on web in this version.");
      AppSnackbar.showSnackbarError('Sending voice messages is not supported on web yet.');
      return;
    }

    var file = await util_file.saveAudioBytesToTempFile(
      audioBytes,
      DateTime.now().millisecondsSinceEpoch ~/ 1000 - (audioBytes.length / 100).ceil(),
      codec?.getFrameSize() ?? 160,
    );

    var currentAppId = appProvider?.selectedChatAppId;
    if (currentAppId == 'no_selected') {
      currentAppId = null;
    }
    String chatTargetId = currentAppId ?? 'omi';
    App? targetApp = currentAppId != null ? appProvider?.apps.firstWhereOrNull((app) => app.id == currentAppId) : null;
    bool isPersonaChat = targetApp != null ? !targetApp.isNotPersona() : false;

    MixpanelManager().chatVoiceInputUsed(
      chatTargetId: chatTargetId,
      isPersonaChat: isPersonaChat,
    );

    setShowTypingIndicator(true);
    var message = ServerMessage.empty();
    messages.insert(0, message);
    notifyListeners();

    try {
      bool firstChunkRecieved = false;
      await for (var chunk in sendVoiceMessageStreamServer([file!])) {
        if (!firstChunkRecieved && [MessageChunkType.data, MessageChunkType.done].contains(chunk.type)) {
          firstChunkRecieved = true;
          if (onFirstChunkRecived != null) {
            onFirstChunkRecived();
          }
        }

        if (chunk.type == MessageChunkType.think) {
          message.thinkings.add(chunk.text);
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.data) {
          message.text += chunk.text;
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.done) {
          message = chunk.message!;
          messages[0] = message;
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.message) {
          messages.insert(1, chunk.message!);
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.error) {
          message.text = chunk.text;
          notifyListeners();
          continue;
        }
      }
    } catch (e) {
      message.text = ServerMessageChunk.failedMessage().text;
      notifyListeners();
    }

    setShowTypingIndicator(false);
    */
  }

  Future sendMessageStreamToServer(String text, {AppFile? audioFile}) async {
    setShowTypingIndicator(true);
    var currentAppId = appProvider?.selectedChatAppId;
    if (currentAppId == 'no_selected') {
      currentAppId = null;
    }

    String chatTargetId = currentAppId ?? 'omi';
    App? targetApp = currentAppId != null ? appProvider?.apps.firstWhereOrNull((app) => app.id == currentAppId) : null;
    bool isPersonaChat = targetApp != null ? !targetApp.isNotPersona() : false;

    // Prepare file IDs for already uploaded files (non-audioFile case)
    List<String> fileIdsForServer = uploadedFiles.map((e) => e.id).toList();

    MixpanelManager().chatMessageSent(
      message: text,
      includesFiles: (audioFile != null) || fileIdsForServer.isNotEmpty, // Simplified logic
      numberOfFiles: (audioFile != null ? 1 : 0) + fileIdsForServer.length,
      chatTargetId: chatTargetId,
      isPersonaChat: isPersonaChat,
      isVoiceInput: _isNextMessageFromVoice || audioFile != null,
    );

    ServerMessage? localMessage = messages.firstWhereOrNull((m) => m.text == text && m.sender == MessageSender.human && m.localAudioFile?.name == audioFile?.name);
    bool existingMessageFound = localMessage != null;

    if (!existingMessageFound) {
        localMessage = ServerMessage.empty(appId: currentAppId); 
        localMessage.text = text; 
        localMessage.sender = MessageSender.human;
        localMessage.createdAt = DateTime.now(); 
        localMessage.isVoice = _isNextMessageFromVoice || audioFile != null; 
        if (audioFile != null) {
            String? filePath;
            if (!kIsWeb) {
                filePath = audioFile.path;
            }
            localMessage.localAudioFile = MessageFile(
                id: const Uuid().v4(), name: audioFile.name, mimeType: audioFile.mimeType ?? 'audio/wav',
                createdAt: DateTime.now(),
                size: 0, 
                localPath: filePath, 
                appId: currentAppId
            );
            localMessage.files = [localMessage.localAudioFile!];
        }
        messages.insert(0, localMessage);
        notifyListeners();
    }

    final String messageToUpdateId = localMessage!.id;

    try {
      final Stream<ServerMessageChunk> stream;
      if (audioFile != null) {
        // Voice message: send the AppFile directly via sendVoiceMessageStreamServer
        stream = backend.sendVoiceMessageStreamServer([audioFile]);
      } else {
        // Text message (possibly with already uploaded files): use sendMessageStreamServer with fileIds
        stream = backend.sendMessageStreamServer(
          text,
          appId: currentAppId,
          filesId: fileIdsForServer, // Pass IDs of already uploaded files
        );
      }

      ServerMessage? serverConfirmedMessage;
      String fullResponseText = "";

      await for (var chunk in stream) {
        int msgIndex = messages.indexWhere((m) => m.id == messageToUpdateId || (serverConfirmedMessage != null && m.id == serverConfirmedMessage.id));
        if (msgIndex == -1) continue; 

        ServerMessage currentDisplayMessage = messages[msgIndex];

        if (chunk.type == MessageChunkType.think) {
          currentDisplayMessage.thinkings.add(chunk.text);
          notifyListeners();
        } else if (chunk.type == MessageChunkType.data) {
          fullResponseText += chunk.text;
          currentDisplayMessage.text = fullResponseText;
          notifyListeners();
        } else if (chunk.type == MessageChunkType.message || chunk.type == MessageChunkType.done) {
          if (chunk.message != null) {
            serverConfirmedMessage = chunk.message!;
            messages[msgIndex] = serverConfirmedMessage.copyWith(
              text: serverConfirmedMessage.text.isEmpty ? fullResponseText : serverConfirmedMessage.text,
              thinkings: currentDisplayMessage.thinkings, 
            );
            if (messageToUpdateId != serverConfirmedMessage.id && msgIndex != -1) {
                 messages.removeWhere((m) => m.id == messageToUpdateId && messages.indexOf(m) != msgIndex); // Avoid index issue
            }
          }
          if (chunk.type == MessageChunkType.done) notifyListeners();
        } else if (chunk.type == MessageChunkType.error) { // Removed .failed
          currentDisplayMessage.text = chunk.text.isNotEmpty ? chunk.text : ServerMessageChunk.failedMessage().text;
          currentDisplayMessage.type = MessageType.error;
          notifyListeners();
          break; 
        }
      }
      if (serverConfirmedMessage != null) {
          int finalIdx = messages.indexWhere((m) => m.id == serverConfirmedMessage!.id || m.id == messageToUpdateId);
          if (finalIdx != -1) {
               messages[finalIdx] = serverConfirmedMessage.copyWith(
                text: serverConfirmedMessage.text.isEmpty ? fullResponseText : serverConfirmedMessage.text,
              );
          }
      }
    } catch (e) {
      debugPrint('Error sending message stream: $e');
      int msgIndex = messages.indexWhere((m) => m.id == messageToUpdateId);
      if (msgIndex != -1) {
        messages[msgIndex] = messages[msgIndex].copyWith(text: ServerMessageChunk.failedMessage().text, type: MessageType.error);
      }
      AppSnackbar.showSnackbarError('Failed to send message. Please try again.');
    } finally {
      if (_isNextMessageFromVoice || audioFile != null) {
        _isNextMessageFromVoice = false; 
      }
      if (audioFile == null) { 
          clearSelectedFiles(); 
          clearUploadedFiles(); 
      }
      setShowTypingIndicator(false);
      setSendingMessage(false); 
      notifyListeners();
    }
  }

  Future sendInitialAppMessage(App? app) async {
    setSendingMessage(true);
    ServerMessage message = await backend.getInitialAppMessage(app?.id);
    addMessage(message);
    setSendingMessage(false);
    notifyListeners();
  }

  App? messageSenderApp(String? appId) {
    return appProvider?.apps.firstWhereOrNull((p) => p.id == appId);
  }

  Future sendMessage(
    String text,
    BuildContext context, {
    String? appId,
    bool addToMessageList = true,
    AppFile? audioFile,
  }) async {
    if (text.isEmpty && uploadedFiles.isEmpty && audioFile == null) {
      AppSnackbar.showSnackbarError('Please enter a message or upload a file');
      return;
    }
    setSendingMessage(true);

    bool isVoiceMsg = audioFile != null || _isNextMessageFromVoice;

    MessageFile? localAudioMsgFile;
    if (audioFile != null) {
        String? filePath;
        if(!kIsWeb) filePath = audioFile.path;
        localAudioMsgFile = MessageFile(
            id: const Uuid().v4(),
            name: audioFile.name,
            mimeType: audioFile.mimeType ?? 'audio/wav',
            createdAt: DateTime.now(),
            size: 0, 
            localPath: filePath,
            appId: appId ?? appProvider?.selectedChatAppId
        );
    }

    ServerMessage localMessage = ServerMessage(
      const Uuid().v4(),
      DateTime.now(), 
      text, 
      MessageSender.human, 
      MessageType.text, 
      appId ?? appProvider?.selectedChatAppId, 
      false, 
      localAudioMsgFile != null ? [localAudioMsgFile] : List<MessageFile>.from(uploadedFiles),
      localAudioMsgFile != null ? [] : uploadedFiles.map((e) => e.id).toList(), 
      [], 
      askForNps: false,
      isVoice: isVoiceMsg,
      localAudioFile: localAudioMsgFile,
    );

    if (addToMessageList) {
      messages.insert(0, localMessage);
      notifyListeners();
    }
    if (audioFile == null) {
        clearUploadedFiles();
        clearSelectedFiles();
    }

    ServerMessage? lastBotMessage;
    String? lastBotMessageId;
    bool isFirstChunk = true;

    try {
      Stream<ServerMessageChunk> stream;
      if (audioFile != null) {
        stream = backend.sendVoiceMessageStreamServer([audioFile]); 
      } else {
        stream = backend.sendMessageStreamServer(
          text,
          appId: appId ?? appProvider?.selectedChatAppId,
          filesId: uploadedFiles.map((e) => e.id).toList(), // Pass file IDs for non-audioFile case
          // appFiles: selectedFiles, // This was causing an error, sendMessageStreamServer expects filesId
        );
      }

      await for (var chunk in stream) {
        int msgIdx = messages.indexWhere((m) => m.id == localMessage.id || (lastBotMessageId != null && m.id == lastBotMessageId));
        if (msgIdx == -1) continue; 

        ServerMessage currentDisplayMessage = messages[msgIdx];

        if (chunk.type == MessageChunkType.error) { // Removed .failed
          messages[msgIdx] = currentDisplayMessage.copyWith(
            text: chunk.text.isNotEmpty ? chunk.text : ServerMessageChunk.failedMessage().text,
            type: MessageType.error,
          );
          notifyListeners();
          return; 
        }

        if (lastBotMessage == null || lastBotMessageId == null) {
          if (chunk.message != null) { 
            lastBotMessage = chunk.message!;
            lastBotMessageId = lastBotMessage.id;
            if (addToMessageList) {
                if (isFirstChunk && messages.isNotEmpty && messages.first.id == localMessage.id && messages.length > 1 && messages[1].sender == MessageSender.ai && messages[1].text.isEmpty) {
                     messages[1] = lastBotMessage; 
                } else if (isFirstChunk && messages.isNotEmpty && messages.first.sender == MessageSender.ai && messages.first.text.isEmpty) {
                     messages[0] = lastBotMessage;
                } else {
                    messages.insert(0, lastBotMessage); 
                }
            }
          } else { 
             lastBotMessage = ServerMessage.empty(appId: appId ?? appProvider?.selectedChatAppId);
             lastBotMessageId = lastBotMessage.id;
             if (addToMessageList) {
                 messages.insert(0, lastBotMessage); 
             }
          }
          isFirstChunk = false;
        }
        
        ServerMessage botMessageToUpdate = messages.firstWhere((m) => m.id == lastBotMessageId);
        int botMessageIdx = messages.indexOf(botMessageToUpdate);

        if (chunk.type == MessageChunkType.think) {
          botMessageToUpdate.thinkings.add(chunk.text);
        } else if (chunk.type == MessageChunkType.data) {
          botMessageToUpdate.text += chunk.text;
        } else if (chunk.type == MessageChunkType.message || chunk.type == MessageChunkType.done) {
          if (chunk.message != null) {
            botMessageToUpdate = chunk.message!;
            if (botMessageToUpdate.appId == null || botMessageToUpdate.appId!.isEmpty) {
              botMessageToUpdate.appId = appId ?? appProvider?.selectedChatAppId;
            }
          }
        }
        messages[botMessageIdx] = botMessageToUpdate; 
        notifyListeners();
      }

      int finalUserMsgIdx = messages.indexWhere((m) => m.id == localMessage.id);
      if(finalUserMsgIdx != -1) {
        // Create a new instance to signal update, effectively removing any loading state if it relied on instance change
        messages[finalUserMsgIdx] = localMessage.copyWith(); 
      }

      if (_isNextMessageFromVoice || audioFile != null) {
        _isNextMessageFromVoice = false;
      }
      notifyListeners();
    } catch (e) {
      int finalUserMsgIdx = messages.indexWhere((m) => m.id == localMessage.id);
      if(finalUserMsgIdx != -1) {
         messages[finalUserMsgIdx] = localMessage.copyWith(type: MessageType.error, text: e.toString());
      }
      notifyListeners();
      AppSnackbar.showSnackbarError('Error sending message: $e');
    } finally {
      setSendingMessage(false);
      setShowTypingIndicator(false);
    }
  }
}
