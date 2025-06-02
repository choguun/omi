import 'dart:io' if (dart.library.html) 'package:omi/utils/stubs/dart_io_web.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:omi/backend/http/api/apps.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/app.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:image_picker/image_picker.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/utils/app_file.dart';

typedef ShowSuccessDialogCallback = void Function(String url);

enum PersonaProfileRouting {
  no_device,
  create_my_clone,
  apps_updates,
  home,
}

class PersonaProvider extends ChangeNotifier {
  // Routing state for persona profile
  PersonaProfileRouting _routing = PersonaProfileRouting.no_device;
  PersonaProfileRouting get routing => _routing;

  void setRouting(PersonaProfileRouting routing, {App? app}) {
    _routing = routing;
    if (app != null) {
      _userPersona = app;
      prepareUpdatePersona(app);
    }
    notifyListeners();
  }

  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  TextEditingController nameController = TextEditingController(text: SharedPreferencesUtil().givenName);
  TextEditingController usernameController = TextEditingController();
  bool isUsernameTaken = false;
  bool isCheckingUsername = false;
  bool makePersonaPublic = false;
  bool isFormValid = false;
  bool hasOmiConnection = false;
  bool hasTwitterConnection = false;
  ShowSuccessDialogCallback? onShowSuccessDialog;

  AppFile? selectedImage;
  String? selectedImageUrl;

  Future updatePersonaName() async {
    debugPrint("updatePersonaName");
    await updatePersona();
    notifyListeners();
  }

  String? get _verifiedPersonaId => SharedPreferencesUtil().verifiedPersonaId;

  bool isLoading = false;

  Map _twitterProfile = {};
  Map get twitterProfile => _twitterProfile;

  App? _userPersona;
  App? get userPersona => _userPersona;
  String? get personaId => _userPersona?.id;

  String _username = '';
  String get username => _username;

  void updateUsername(String value) {
    _username = value;
    notifyListeners();
  }

  Future getTwitterProfile(String handle) async {
    setIsLoading(true);
    var res = await getTwitterProfileData(handle);
    debugPrint('Twitter Profile: $res');
    if (res != null) {
      if (res['status'] == 'notfound') {
        AppSnackbar.showSnackbarError('Twitter handle not found');
        _twitterProfile = {};
        MixpanelManager().personaTwitterProfileFetched(twitterHandle: handle, fetchSuccessful: false);
      } else if (res['status'] == 'suspended') {
        AppSnackbar.showSnackbarError('Twitter handle is suspended');
        _twitterProfile = {};
        MixpanelManager().personaTwitterProfileFetched(twitterHandle: handle, fetchSuccessful: false);
      } else {
        _twitterProfile = res;
        MixpanelManager().personaTwitterProfileFetched(twitterHandle: handle, fetchSuccessful: true);
      }
    } else {
      MixpanelManager().personaTwitterProfileFetched(twitterHandle: handle, fetchSuccessful: false);
    }
    setIsLoading(false);
    notifyListeners();
  }

  Future verifyTweet() async {
    var (verified, verifiedPersonaId) = await verifyTwitterOwnership(_username, _twitterProfile['profile'], personaId);
    if (!verified) {
      AppSnackbar.showSnackbarError('Failed to verify Twitter handle');
    }
    MixpanelManager().personaTwitterOwnershipVerified(
        personaId: verifiedPersonaId ?? personaId,
        twitterHandle: _twitterProfile['profile'],
        verificationSuccessful: verified);
    SharedPreferencesUtil().hasPersonaCreated = true;
    SharedPreferencesUtil().verifiedPersonaId = verifiedPersonaId;
    toggleTwitterConnection(true);

    return verified;
  }

  // TODO: get rid of this one
  Future _getUserPersona() async {
    setIsLoading(true);
    var res = await getUserPersonaServer();
    if (res != null) {
      _userPersona = res;
    } else {
      _userPersona = null;
      AppSnackbar.showSnackbarError('Failed to fetch your persona');
    }
    setIsLoading(false);
  }

  // Get upsert verified user persona
  Future getVerifiedUserPersona() async {
    setIsLoading(true);

    if (_verifiedPersonaId == null || routing != PersonaProfileRouting.no_device) {
      // If no verified persona ID exists, get or create one
      var res = await getUpsertUserPersonaServer();
      if (res != null) {
        _userPersona = App.fromJson(res as Map<String, dynamic>);
        // Save the persona ID for future use
        SharedPreferencesUtil().verifiedPersonaId = _userPersona?.id;
      } else {
        _userPersona = null;
        AppSnackbar.showSnackbarError('Failed to create your persona');
      }
    } else {
      // If we have a verified persona ID, fetch it
      var res = await getAppDetailsServer(_verifiedPersonaId!);
      if (res != null) {
        _userPersona = App.fromJson(res as Map<String, dynamic>);
      } else {
        _userPersona = null;
        AppSnackbar.showSnackbarError('Failed to fetch your persona');
      }
    }

    // Prepare for updates
    if (_userPersona != null) {
      prepareUpdatePersona(_userPersona!);
    }

    setIsLoading(false);
  }

  void setPersonaPublic(bool? value) {
    if (value == null) {
      return;
    }
    if (value == makePersonaPublic) {
      return;
    }
    makePersonaPublic = value;

    // Update
    debugPrint("setPersonaPublic");
    if (_userPersona != null) {
      MixpanelManager().personaPublicToggled(personaId: _userPersona!.id, isPublic: makePersonaPublic);
    }
    updatePersona();
  }

  void prepareUpdatePersona(App app) {
    nameController.text = app.name;
    usernameController.text = app.username!;
    makePersonaPublic = !app.private;
    selectedImageUrl = app.image;
    _userPersona = app;
    hasOmiConnection = app.connectedAccounts.contains('omi');
    hasTwitterConnection = app.connectedAccounts.contains('twitter');
    if (hasTwitterConnection && app.twitter != null) {
      _twitterProfile = app.twitter!;
    }
    notifyListeners();
  }

  Future<void> pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      selectedImage = AppFile.fromXFile(image);
      selectedImageUrl = null;
      MixpanelManager().personaCreateImagePicked();
      validateForm();
    }
    notifyListeners();
  }

  Future<void> pickAndUpdateImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      selectedImage = AppFile.fromXFile(image);
      selectedImageUrl = null;
      if (_userPersona != null) {
        MixpanelManager().personaUpdateImagePicked(personaId: _userPersona!.id);
      } else {
        MixpanelManager().personaCreateImagePicked();
      }
      validateForm();

      debugPrint("pickAndUpdateImage");
      await updatePersona();
    }
    notifyListeners();
  }

  void validateForm() {
    bool hasValidImage = selectedImage != null || selectedImageUrl != null;
    bool hasValidFormFields = true; //formKey.currentState!.validate(); // dont use form for now
    bool hasKnowledgeData = hasOmiConnection || hasTwitterConnection;

    isFormValid = hasValidImage && hasValidFormFields && hasKnowledgeData;
    notifyListeners();
  }

  void resetForm() {
    nameController.clear();
    usernameController.clear();
    selectedImage = null;
    selectedImageUrl = null;
    makePersonaPublic = false;
    isFormValid = false;
    onShowSuccessDialog = null;
    hasOmiConnection = false;
    _userPersona = null;
    hasTwitterConnection = false;
    _twitterProfile = {};
    notifyListeners();
  }

  void toggleOmiConnection(bool value) {
    hasOmiConnection = value;
    if (_userPersona != null) {
      MixpanelManager().personaOmiConnectionToggled(personaId: _userPersona!.id, omiConnected: value);
    }
    notifyListeners();
  }

  void toggleTwitterConnection(bool value) {
    hasTwitterConnection = value;
    if (!value) {
      _twitterProfile = {};
    }
    if (_userPersona != null) {
      MixpanelManager().personaTwitterConnectionToggled(personaId: _userPersona!.id, twitterConnected: value);
    }
    notifyListeners();
  }

  void disconnectTwitter() {
    _twitterProfile = {};
    hasTwitterConnection = false;

    debugPrint("disconnectTwitter");
    if (_isEditablePersona()) {
      updatePersona();
      if (_userPersona != null) {
        MixpanelManager().personaTwitterConnectionToggled(personaId: _userPersona!.id, twitterConnected: false);
      }
    }
    notifyListeners();
  }

  void disconnectOmi() {
    hasOmiConnection = false;
    debugPrint("disconnectOmi");
    if (_isEditablePersona()) {
      updatePersona();
      if (_userPersona != null) {
        MixpanelManager().personaOmiConnectionToggled(personaId: _userPersona!.id, omiConnected: false);
      }
    }
    notifyListeners();
  }

  bool _isEditablePersona() {
    return routing != PersonaProfileRouting.no_device;
  }

  Future<void> updatePersona() async {
    debugPrint("updatePersona");
    setIsLoading(true);
    Map<String, dynamic> personaData = {
      'name': nameController.text,
      'username': usernameController.text,
      'private': !makePersonaPublic,
      'id': _userPersona?.id,
      'connected_accounts': {
        'omi': hasOmiConnection,
        'twitter': hasTwitterConnection,
      },
      'twitter_data': _twitterProfile,
    };

    // updatePersonaApp now takes AppFile?
    bool success = await updatePersonaApp(selectedImage, personaData);

    if (success) {
      if (selectedImage != null && _userPersona != null) {
        // MixpanelManager().personaImageUpdated(personaId: _userPersona!.id);
      }
      // await _getUserPersona(); // Consider re-fetching or updating local _userPersona
      // For now, if selectedImage was used, its URL isn't immediately known without re-fetch
      // Let's assume UI updates from selectedImage directly if it's a new local file
      AppSnackbar.showSnackbarSuccess('Persona updated successfully');
      selectedImage = null; // Clear selected local file after successful upload
    } else {
      AppSnackbar.showSnackbarError('Failed to update persona');
    }
    validateForm();
    setIsLoading(false);
  }

  Future<void> createPersonaAndRedirect() async {
    if (!isFormValid) {
      AppSnackbar.showSnackbarError('Please fill all required fields and connect at least one data source.');
      return;
    }
    setIsLoading(true);

    Map<String, dynamic> personaData = {
      'name': nameController.text,
      'username': usernameController.text,
      'private': !makePersonaPublic,
      'connected_accounts': {
        'omi': hasOmiConnection,
        'twitter': hasTwitterConnection,
      },
      'twitter_data': _twitterProfile,
    };

    if (selectedImage == null) {
      AppSnackbar.showSnackbarError('Please select an image for your persona.');
      setIsLoading(false);
      return;
    }

    // createPersonaApp now takes AppFile
    Map response = await createPersonaApp(selectedImage!, personaData);

    if (response.containsKey('id')) {
      AppSnackbar.showSnackbarSuccess('Persona created successfully!');
      MixpanelManager().personaCreated(
        personaId: response['id'], 
        isPublic: makePersonaPublic,
      );
      SharedPreferencesUtil().hasPersonaCreated = true;
      SharedPreferencesUtil().verifiedPersonaId = response['id'];
      _userPersona = App.fromJson(response as Map<String, dynamic>); // Update local user persona
      prepareUpdatePersona(_userPersona!);     // Prepare for any immediate follow-up edits if needed
      if (onShowSuccessDialog != null && response.containsKey('share_url')) {
        onShowSuccessDialog!(response['share_url']);
      }
      selectedImage = null; // Clear selected file after successful creation
    } else {
      String errorMsg = 'Unknown error during persona creation';
      if (response != null && response['detail'] != null) {
        errorMsg = response['detail'];
      } else if (response != null && response['message'] != null) {
        errorMsg = response['message'];
      }
      AppSnackbar.showSnackbarError(errorMsg);
      MixpanelManager().personaCreateFailed(
        errorMessage: errorMsg
      );
    }
    setIsLoading(false);
    validateForm();
  }

  Future checkIsUsernameTaken(String username) async {
    setIsCheckingUsername(true);
    isUsernameTaken = await checkPersonaUsername(username);
    MixpanelManager().personaUsernameCheck(username: username, isTaken: isUsernameTaken);
    setIsCheckingUsername(false);
  }

  void setIsCheckingUsername(bool checking) {
    isCheckingUsername = checking;
    notifyListeners();
  }

  void setIsLoading(bool loading) {
    isLoading = loading;
    notifyListeners();
  }

  Future<bool> enablePersonaApp() async {
    setIsLoading(true);
    if (_userPersona == null) {
      await getVerifiedUserPersona();
    }
    try {
      var enabled = await enableAppServer(_userPersona!.id);
      if (enabled) {
        MixpanelManager().personaEnabled(personaId: _userPersona!.id);
        return true;
      } else {
        AppSnackbar.showSnackbarError('Failed to enable persona');
        MixpanelManager().personaEnableFailed(personaId: _userPersona!.id, errorMessage: 'API returned false');
        return false;
      }
    } catch (e) {
      AppSnackbar.showSnackbarError('Error enabling persona: $e');
      if (_userPersona != null) {
        MixpanelManager().personaEnableFailed(personaId: _userPersona!.id, errorMessage: e.toString());
      }
      return false;
    } finally {
      setIsLoading(false);
    }
  }

  Future onTwitterVerifiedCompleted() async {
    debugPrint("routing ${routing}");
    if (routing == PersonaProfileRouting.no_device) {
      return;
    }

    // update
    debugPrint("onTwitterVerifiedCompleted");
    updatePersona();
  }
}
