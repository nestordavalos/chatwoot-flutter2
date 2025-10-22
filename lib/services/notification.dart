import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:chatwoot/services/notification_channels.dart';
import '/screens/conversations/controllers/chat.dart';
import '/screens/conversations/views/chat.dart';
import '/imports.dart';

enum NotificationEventId { onMessage, onMessageOpenedApp }

class NotificationService extends GetxService {
  final _logger = Logger();
  final _firebaseMessaging = FirebaseMessaging.instance;
  final _notificationsPlugin = FlutterLocalNotificationsPlugin();

  final events = EventEmitter();
  final enabled = PersistentRxBool(false, key: 'notification:enabled');
  final token = PersistentRx<String?>(null, key: 'notification:token');
  final authorizationStatus = AuthorizationStatus.notDetermined.obs;
  final registrationPending =
      PersistentRxBool(false, key: 'notification:registrationPending');
  final lastRegisteredToken =
      PersistentRx<String?>(null, key: 'notification:lastRegisteredToken');
  final lastRegisteredAccountId = PersistentRxCustom<int?>(
    null,
    key: 'notification:lastRegisteredAccountId',
    encode: (value) => value?.toString(),
    decode: (value) => int.tryParse(value),
  );

  RemoteMessage? _initialMessage;
  StreamSubscription<bool>? _enabledChangeSubscription;
  StreamSubscription<String?>? _tokenChangeSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _onMessageSubscription;
  StreamSubscription<RemoteMessage>? _onMessageOpenedAppSubscription;
  EventListener<ConversationInfo>? _conversationReadListener;
  EventListener<NotificationInfo>? _notificationCreatedListener;
  EventListener<int>? _notificationDeletedListener;
  Timer? _registrationRetryTimer;
  bool _isRegisteringDevice = false;

  ApiService? _api;
  ApiService get _getApi {
    _api ??= Get.find<ApiService>();
    if (_api == null) throw Exception('ApiService not found!');
    return _api!;
  }

  AuthService? _auth;
  AuthService get _getAuth {
    _auth ??= Get.find<AuthService>();
    if (_auth == null) throw Exception('AuthService not found!');
    return _auth!;
  }

  RealtimeService? _realtime;
  RealtimeService get _getRealtime {
    _realtime ??= Get.find<RealtimeService>();
    if (_realtime == null) throw Exception('RealtimeService not found!');
    return _realtime!;
  }

  RemoteMessage? get getRemoteMessage => _initialMessage;

  @override
  void onReady() {
    super.onReady();

    _getAuth.isSignedIn.listen((next) {
      if (!next) {
        _logger.i('auth signed out; clearing notification session');
        _cancelRegistrationRetry();
        registrationPending.value = false;
        lastRegisteredToken.value = null;
        lastRegisteredAccountId.value = null;
        token.value = null;
        return;
      }
      _logger.i('auth signed in; ensuring notification session');
      registrationPending.value = true;
      _ensurePermission();
      saveDeviceDetails();
    });

    _conversationReadListener = _getRealtime.events.on(
      RealtimeEventId.conversationRead.name,
      _onConversationRead,
    );

    _notificationCreatedListener = _getRealtime.events.on(
      RealtimeEventId.notificationCreated.name,
      _onNotificationCreated,
    );

    _notificationDeletedListener = _getRealtime.events.on(
      RealtimeEventId.notificationDeleted.name,
      _onNotificationDeleted,
    );

    _enabledChangeSubscription = enabled.listen((next) {
      _logger.i('enabled changed => $next');
      if (next) {
        registrationPending.value = true;
        _ensurePermission();
      }
    });

    _tokenChangeSubscription = token.listen((next) {
      if (isNullOrEmpty(next)) {
        _cancelRegistrationRetry();
        registrationPending.value = false;
        return;
      }

      if (next != lastRegisteredToken.value) {
        registrationPending.value = true;
      }

      saveDeviceDetails();
    });

    if (!GetPlatform.isDesktop) {
      _tokenRefreshSubscription = _firebaseMessaging.onTokenRefresh.listen(
        (next) {
          registrationPending.value = true;
          token.value = next;
        },
        onError: (error, stackTrace) {
          _logger.e(error, stackTrace: stackTrace);
        },
      );
    }

    _onMessageSubscription =
        FirebaseMessaging.onMessage.listen(_onMessage);
    _onMessageOpenedAppSubscription =
        FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpenedApp);
  }

  @override
  void onClose() {
    _enabledChangeSubscription?.cancel();
    _tokenChangeSubscription?.cancel();
    _tokenRefreshSubscription?.cancel();
    _onMessageSubscription?.cancel();
    _onMessageOpenedAppSubscription?.cancel();
    _conversationReadListener?.cancel();
    _notificationCreatedListener?.cancel();
    _notificationDeletedListener?.cancel();
    _cancelRegistrationRetry();

    super.onClose();
  }

  Future<NotificationService> init() async {
    await _ensurePermission();

    await configureChatwootLocalNotifications(
      _notificationsPlugin,
      onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
    );

    if (GetPlatform.isIOS || GetPlatform.isMacOS) {
      await _firebaseMessaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    if (!GetPlatform.isDesktop) {
      _initialMessage = await _firebaseMessaging.getInitialMessage();
      if (_initialMessage != null) {
        _logger.i('getInitialMessage: ${jsonEncode(_initialMessage!.toMap())}');
      }
    }

    if (_getAuth.isSignedIn.value) {
      registrationPending.value = true;
    }

    await saveDeviceDetails(force: registrationPending.value);

    return this;
  }

  Future<void> handleNavigation(NotificationInfo info) async {
    switch (info.primary_actor_type) {
      case NotificationActorType.conversation:
        Get.to(
          () => ConversationChatView(conversation_id: info.primary_actor_id),
        );
        break;

      default:
        _logger.w('unhandled primary_actor_type ${info.primary_actor_id}');
        return;
    }
  }

  Future<void> showPushNotification(NotificationInfo info) async {
    await _notificationsPlugin.show(
      info.id,
      info.push_message_title,
      info.notification_type.name,
      chatwootNotificationDetails,
      payload: jsonEncode(info.toJson()),
    );
  }

  Future<void> _onMessage(RemoteMessage message) async {
    _logger.i(jsonEncode(message.toMap()));
    events.emit(NotificationEventId.onMessage.name, message);

    // TODO: message.data not tested
    try {
      final info = NotificationInfo.fromJson(message.data);

      // if conversation opened
      if (isConversationChatOpened(info.id)) return;

      // show push notifications
      await showPushNotification(info);
    } on Error catch (error) {
      _logger.e(error, stackTrace: error.stackTrace);
      _logger.e('failed to parse message.data');
      _logger.e(message.data);
    }
  }

  Future<void> _onMessageOpenedApp(RemoteMessage message) async {
    _logger.i(jsonEncode(message.toMap()));
    events.emit(NotificationEventId.onMessageOpenedApp.name, message);

    // TODO: message.data not tested
    try {
      final info = NotificationInfo.fromJson(message.data);
      await handleNavigation(info);
    } on Error catch (error) {
      _logger.e(error, stackTrace: error.stackTrace);
      _logger.e('failed to parse message.data');
      _logger.e(message.data);
    }
  }

  Future<void> _onDidReceiveNotificationResponse(
      NotificationResponse response) async {
    try {
      final data = jsonDecode(response.payload!);
      final info = NotificationInfo.fromJson(data);
      await handleNavigation(info);
    } on Error catch (error) {
      _logger.e(error, stackTrace: error.stackTrace);
      _logger.e('failed to parse response.payload');
      _logger.e(response.payload);
    }
  }

  bool isConversationChatOpened(int conversation_id) {
    return Get.isRegistered<ConversationChatController>(
      tag: '$conversation_id',
    );
  }

  Future<void> _onConversationRead(ConversationInfo info) async {
    await _notificationsPlugin.cancel(info.id);
  }

  Future<void> _onNotificationCreated(NotificationInfo info) async {
    await showPushNotification(info);
  }

  Future<void> _onNotificationDeleted(int id) async {
    await _notificationsPlugin.cancel(id);
  }

  Future<void> _ensurePermission() async {
    if (GetPlatform.isDesktop) {
      _logger.d('requestPermission ignored when isDesktop');
      return;
    }
    _logger.d('requestPermission');

    final notificationSettings =
        await _firebaseMessaging.requestPermission(provisional: true);
    authorizationStatus.value = notificationSettings.authorizationStatus;
    if (authorizationStatus.value == AuthorizationStatus.denied) {
      _logger.w('permission:denied');
      return;
    }
    _logger.d('permission:${authorizationStatus.value}');

    final getToken = await _firebaseMessaging.getToken();
    if (isNullOrEmpty(token.value) || getToken != token.value) {
      token.value = getToken;
    }
    _logger.d('token:${token.value}');
  }

  void handleLogout() {
    _cancelRegistrationRetry();
    registrationPending.value = false;
    lastRegisteredToken.value = null;
    lastRegisteredAccountId.value = null;
  }

  Future<void> saveDeviceDetails({bool force = false}) async {
    if (_isRegisteringDevice) {
      _logger.d('saveDeviceDetails() => already running');
      return;
    }

    if (!_getAuth.isSignedIn.value) {
      _logger.w('saveDeviceDetails() => skipped (not signed in)');
      return;
    }

    if (isNullOrEmpty(token.value)) {
      _logger.w('saveDeviceDetails() => token is empty');
      return;
    }

    final accountId = _getAuth.profile.value?.account_id;
    if (accountId == null) {
      _logger.w('saveDeviceDetails() => account_id is null');
      return;
    }

    if (!force &&
        !registrationPending.value &&
        lastRegisteredToken.value == token.value &&
        lastRegisteredAccountId.value == accountId) {
      _logger.d('saveDeviceDetails() => already registered');
      return;
    }

    registrationPending.value = true;
    _isRegisteringDevice = true;

    try {
      _logger.d('saveDeviceDetails()');
      final result =
          await _getApi.notifications.saveDeviceDetails(push_token: token.value!);
      if (result.isError()) {
        final error = result.exceptionOrNull();
        _logger.e(
          'saveDeviceDetails() => failed',
          error,
          stackTrace: error is Error ? error.stackTrace : null,
        );
        _scheduleRegistrationRetry();
        return;
      }

      lastRegisteredToken.value = token.value;
      lastRegisteredAccountId.value = accountId;
      registrationPending.value = false;
      _cancelRegistrationRetry();
      _logger.d('saveDeviceDetails() => successful');
    } finally {
      _isRegisteringDevice = false;
    }
  }

  void _scheduleRegistrationRetry() {
    if (_registrationRetryTimer?.isActive ?? false) {
      return;
    }

    _registrationRetryTimer = Timer(const Duration(minutes: 5), () {
      _registrationRetryTimer = null;
      if (registrationPending.value) {
        saveDeviceDetails();
      }
    });
  }

  void _cancelRegistrationRetry() {
    _registrationRetryTimer?.cancel();
    _registrationRetryTimer = null;
  }
}
