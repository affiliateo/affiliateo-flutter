import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
// Named for older Flutter versions, whose foundation library has neither.
// ignore: unnecessary_import
import 'dart:ui' show Brightness, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'chat_push.dart';
import 'chat_rules.dart';
import 'chat_token_store.dart';

// Live Chat (4.15.4): the app's users chat in real time with the business,
// which answers from the Live Chat inbox in its Affiliateo dashboard.
//
//   MaterialApp(builder: (context, child) => AffiliateoChat(child: child!))
//   Affiliateo.openChat(context)      open it from your own button
//
// Nothing shows until the app places AffiliateoChat or calls openChat(): an
// app must not grow a visible feature its store reviewer never saw. And
// nothing shows while the business has the chat switched off for this app in
// its dashboard, which the SDK asks the server about.
//
// The chat SCREEN is Affiliateo's hosted page (/embed/chat/{app}) in a web
// view, the same page the website bubble and the Swift, Kotlin and React
// Native SDKs open, so it looks and behaves the same everywhere.
//
// The visitor's key to their thread (a token the server hands out with their
// first message) is kept in the phone's secure store (chat_token_store.dart)
// and passed to the page in the URL fragment, which never reaches a server
// log. logout(), reset() and a different user signing in drop it, so the
// next person on the phone starts a new thread.
//
// The owner's choices come with the config (chat_rules.dart): the corner the
// bubble starts in, its size, the screens it shows on (matched against the
// name the app last passed to page()), and a greeting that counts as one
// unread message until the chat is opened. While the app is open and the
// chat is closed, a socket keeps the red number live. While a bubble is
// placed and the app is in front, the app's own channel brings the owner's
// on/off switch and the team's Online switches at once (a `config` frame,
// applied as a fresh config read is).
//
// 4.17.0: the bubble wiggles every so often (the owner's seconds, or the
// app's own with AffiliateoChat(wiggleSeconds:); one smooth 0.9 s wiggle of
// the whole bubble, chat_rules.dart wiggleAngle), and a reply shows as a
// notification, like a message. The app hands over its push token
// (Affiliateo.registerChatPushToken) and the phone itself draws the
// notification while the app is closed or in the background; the app passes
// a tapped notification's data to Affiliateo.handleChatNotification, which
// opens the chat over whatever is on screen. With the app open the SDK draws
// a banner of its own at the top of the screen (AffiliateoChat's
// inAppBanner), and once the app says notifications are allowed
// (Affiliateo.chatNotificationsAllowed) a greeting nobody has seen shows as
// one too, once.

/// The chat's state, for a button of your own (`Affiliateo.chatState`).
@immutable
class AffiliateoChatState {
  const AffiliateoChatState({
    this.enabled = false,
    this.showBubble = false,
    this.online = false,
    this.unread = 0,
    this.isOpen = false,
  });

  /// The business has the chat on for this app.
  final bool enabled;

  /// The bubble should show (on, and not hidden by "only while someone is online").
  final bool showBubble;

  /// Someone on the business's team is online right now.
  final bool online;

  /// Replies the person has not seen yet (the greeting counts as one until
  /// the chat is first opened).
  final int unread;

  /// The chat is on screen.
  final bool isOpen;

  @override
  bool operator ==(Object other) =>
      other is AffiliateoChatState &&
      other.enabled == enabled &&
      other.showBubble == showBubble &&
      other.online == online &&
      other.unread == unread &&
      other.isOpen == isOpen;

  @override
  int get hashCode => Object.hash(enabled, showBubble, online, unread, isOpen);

  @override
  String toString() =>
      'AffiliateoChatState(enabled: $enabled, showBubble: $showBubble, online: $online, unread: $unread, isOpen: $isOpen)';
}

/// What the SDK hands the chat: where to ask, and what it knows.
class ChatEnv {
  const ChatEnv({
    required this.apiBase,
    required this.appId,
    required this.deviceId,
    required this.visitorId,
    required this.userId,
    required this.optedOut,
    required this.log,
  });

  final String apiBase;
  final String appId;
  final String? Function() deviceId;
  final String? Function() visitorId;
  final String? Function() userId;
  final bool Function() optedOut;
  final void Function(String message) log;
}

class _PrefsStore implements ChatPlainStore {
  @override
  Future<String?> read(String key) async => (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await SharedPreferences.getInstance()).setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await (await SharedPreferences.getInstance()).remove(key);
  }
}

/// The phone's secure store: the Keychain on this iPhone only, after its
/// first unlock, never synced or restored to another phone; Android's
/// Keystore.
class _SecureStore implements ChatSecretStore {
  static const _storage = FlutterSecureStorage();
  static const _ios = IOSOptions(
    accountName: 'com.affiliateo.chat-token',
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _android = AndroidOptions();

  @override
  Future<String?> read(String name) => _storage.read(key: name, iOptions: _ios, aOptions: _android);

  @override
  Future<bool> write(String name, String value) async {
    await _storage.write(key: name, value: value, iOptions: _ios, aOptions: _android);
    return true;
  }

  @override
  Future<void> remove(String name) => _storage.delete(key: name, iOptions: _ios, aOptions: _android);
}

/// The phone's first preferred language.
String _deviceLanguage() {
  final locales = PlatformDispatcher.instance.locales;
  return locales.isEmpty ? 'en' : locales.first.toLanguageTag();
}

String _posKey(String appId) => 'affiliateo_chat_pos_$appId';
String _greetingKey(String appId) => 'affiliateo_chat_greeting_seen_$appId';

Future<SharedPreferences?> _prefs() async {
  try {
    return await SharedPreferences.getInstance();
  } catch (_) {
    return null;
  }
}

/// The app's root navigator under [context]: the one above it, else the
/// first one below it (AffiliateoChat sits above the app's navigator when
/// placed in MaterialApp.builder).
NavigatorState? _navigatorFor(BuildContext context) {
  final above = Navigator.maybeOf(context, rootNavigator: true);
  if (above != null) return above;
  NavigatorState? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is NavigatorState) {
      found = element.state as NavigatorState;
      return;
    }
    element.visitChildren(visit);
  }

  context.visitChildElements(visit);
  return found;
}

/// A route that covers the bubble, as sheets, dialogs and full-screen
/// pop-ups do in the other SDKs: the bubble is for the app's pages.
bool _coversBubble(Route<Object?> route) =>
    route is PopupRoute || (route is PageRoute && route.fullscreenDialog);

/// The sheet, dialog or full-screen pop-up on top of [navigator], or of a
/// navigator inside its top page (a tab's own navigator), or null.
ModalRoute<Object?>? _coverOn(NavigatorState navigator) {
  if (!navigator.mounted) return null;
  Route<Object?>? top;
  // Reads the top route: answering true at once pops nothing.
  navigator.popUntil((route) {
    top = route;
    return true;
  });
  final page = top;
  if (page is! ModalRoute<Object?>) return null;
  if (_coversBubble(page)) return page;
  final pageContext = page.subtreeContext;
  if (pageContext == null) return null;
  ModalRoute<Object?>? found;
  void visit(Element element) {
    if (found != null) return;
    // A tab that isn't showing, its navigator included.
    final widget = element.widget;
    if (widget is Offstage && widget.offstage) return;
    if (element is StatefulElement && element.state is NavigatorState) {
      found = _coverOn(element.state as NavigatorState);
      return;
    }
    element.visitChildren(visit);
  }

  pageContext.visitChildElements(visit);
  return found;
}

/// The chat, once per app: asks the server whether it is on, keeps the
/// unread count, and opens the chat screen.
class LiveChat extends ChangeNotifier with WidgetsBindingObserver {
  LiveChat._();

  static final LiveChat instance = LiveChat._();

  static const _configEvery = Duration(seconds: 60);
  static const _unreadEvery = Duration(seconds: 30);
  static const _timeout = Duration(seconds: 15);

  ChatEnv? _env;
  ChatTokenStore _tokens = ChatTokenStore(_SecureStore(), _PrefsStore());

  /// What `Affiliateo.chatState` hands out.
  final ValueNotifier<AffiliateoChatState> state = ValueNotifier(const AffiliateoChatState());

  /// The screen the app last named with page(), for the bubble's page rules.
  final ValueNotifier<String?> screen = ValueNotifier<String?>(null);

  /// The dashboard's bubble (corner, size, screens, colors).
  ChatBubbleConfig dashboardBubble = const ChatBubbleConfig();

  /// The whole config as the server last answered it (whose chat it is and
  /// the greeting, for the banner).
  ChatConfig _config = ChatConfig.off;

  /// The banner on show (4.17.0): a reply, or the greeting. AffiliateoChat
  /// draws it.
  final ValueNotifier<ChatBanner?> banner = ValueNotifier<ChatBanner?>(null);

  /// AffiliateoChat widgets placed with `inAppBanner` on: a banner shows only
  /// while there is one to draw it.
  int _bannerPlaces = 0;

  /// The app said notifications are allowed (chatNotificationsAllowed), in
  /// this launch.
  bool _allowed = false;

  /// Greetings shown as a banner in this launch ("app:greeting id"): holds
  /// also when the phone's storage does not.
  final Set<String> _greetingsShown = <String>{};
  bool _greetingBusy = false;

  /// A tapped notification's chat (handleChatNotification), waiting for the
  /// SDK to be configured, the app to be in front and a navigator to open on.
  bool _openPending = false;
  int _openTries = 0;
  Timer? _openRetry;

  /// How the placed AffiliateoChat widgets find the app's navigator.
  final Set<NavigatorState? Function()> _navigators = <NavigatorState? Function()>{};

  // The push token the app handed over (registerChatPushToken).
  String? _pushToken;
  String? _pushPlatform;
  String? _pushBundleId;
  String? _pushEnvironment;

  /// The app's own bundle id or package name, read once. Until the read has
  /// answered, nothing is registered: an iPhone's token is no use without it.
  String? _ownBundleId;
  bool _ownBundleIdKnown = false;
  Future<String?>? _ownBundleIdRead;

  /// Keeps Affiliateo's list of phones in step with this one (chat_push.dart).
  late ChatPushRegistrar _push = _newPushRegistrar();

  ChatPushRegistrar _newPushRegistrar() => ChatPushRegistrar(
        store: _PrefsStore(),
        send: _sendPush,
        state: _pushState,
        hasThread: (appId) async => await _loadToken(appId) != null,
        log: (message) => _env?.log(message),
      );

  /// The send color and placeholder the app's own code set (AffiliateoChat).
  ChatLook widgetLook = const ChatLook();

  /// The app's own seconds between two wiggles (setChatBubbleWiggle, 4.17.0):
  /// 0 for none, null while the app never said (the dashboard decides).
  int? _codeWiggle;
  int? get codeWiggle => _codeWiggle;

  /// The app's own wiggle time, over the dashboard's: null and 0 are off.
  void setWiggle(int? seconds) {
    _codeWiggle = wiggleOverride(seconds ?? 0);
    _afterBuild(notifyListeners);
  }

  /// The app named the screen on show (page()): the bubble's page rules
  /// follow it.
  void setScreen(String name) {
    if (name.isEmpty || name == screen.value) return;
    _afterBuild(() => screen.value = name);
  }

  /// Runs [change] now, or right after this frame when the app is in the
  /// middle of building one (4.17.0). The SDK is often called from a
  /// screen's initState() (page() is), and the bubble sits above that
  /// screen: telling it to redraw while the frame is still being built is an
  /// error in Flutter ("setState() or markNeedsBuild() called during build").
  void _afterBuild(VoidCallback change) {
    var building = false;
    try {
      building = SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks;
    } catch (_) {
      // No Flutter binding yet (the app has not started drawing): nothing to wait for.
    }
    if (building) {
      SchedulerBinding.instance.addPostFrameCallback((_) => change());
    } else {
      change();
    }
  }

  bool _known = false;
  bool _enabled = false;
  bool _showBubble = false;
  bool _online = false;
  int _unread = 0;
  bool _visitorOnline = false;
  bool _isOpen = false;
  String? _token;
  bool _greetingPending = false;
  bool _active = true;
  bool _wanted = false;
  bool _observing = false;
  DateTime? _lastConfig;
  DateTime? _lastUnread;
  Future<void>? _configInFlight;

  /// A sign-out before configure() said which app: done once it has.
  bool _forgetPending = false;

  /// Goes up on sign-out: an answer about the last person's token is dropped.
  int _signOuts = 0;

  Route<void>? _sheet;

  // The socket that keeps the red number live while the chat is closed.
  WebSocket? _socket;
  String? _socketToken;
  int _socketRun = 0;
  int _tries = 0;
  Timer? _retry;
  Timer? _ping;

  // The app channel: the owner's switch and the team's Online switches, live.
  int _bubbles = 0;
  WebSocket? _appSocket;
  int _appRun = 0;
  bool _appOn = false;
  int _appTries = 0;
  Timer? _appRetry;
  Timer? _appPing;

  /// The server refused the app channel (no such app, or the chat is off):
  /// not tried again until a config read says the chat is on.
  bool _appRefused = false;

  /// configure() ran: where to ask and what the SDK knows.
  void attach(ChatEnv env) {
    if (_env != null) return;
    _env = env;
    if (_forgetPending) {
      _forgetPending = false;
      unawaited(_tokens.clear(env.appId));
      unawaited(_push.forget(env.appId, token: _pushToken, platform: _pushPlatform));
    }
    if (_wanted) _start();
    // What the app asked for before configure() had finished (4.17.0).
    syncPush();
    _tryPendingOpen();
  }

  /// The app is in front (the wiggle and the banner wait for it).
  bool get active => _active;

  /// Something in the app uses the chat (the bubble, chatState, openChat or
  /// chatAvailable). Until then the SDK asks the server nothing about it.
  void want() {
    if (_wanted) return;
    _wanted = true;
    if (_env != null) _start();
  }

  void _start() {
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
    unawaited(_refreshConfig(force: true));
    unawaited(_refreshUnread(force: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    _active = lifecycle == AppLifecycleState.resumed;
    if (_active) {
      unawaited(_refreshConfig());
      unawaited(_refreshUnread());
      // A registration that got no answer is tried again, and a tapped
      // notification's chat opens now that the app is in front (4.17.0).
      syncPush();
      _tryPendingOpen();
      unawaited(_showGreetingIfDue());
    } else {
      // A banner is for the app in front.
      banner.value = null;
    }
    _syncSocket();
    _syncAppChannel();
    // The bubble's wiggle rests while the app is at the back.
    notifyListeners();
  }

  /// An AffiliateoChat came on screen: the app channel runs while one is.
  void bubblePlaced() {
    _bubbles++;
    _syncAppChannel();
  }

  /// An AffiliateoChat went away.
  void bubbleRemoved() {
    _bubbles = max(0, _bubbles - 1);
    _syncAppChannel();
  }

  /// Whether the business has the chat on for this app (asks the server when
  /// it has not yet).
  Future<bool> available() async {
    want();
    if (!_known) await _refreshConfig(force: true);
    return _enabled;
  }

  /// Tests only: the chat as if the server had answered.
  @visibleForTesting
  void debugAnswer({
    bool enabled = true,
    bool showBubble = true,
    bool online = false,
    int unread = 0,
    ChatBubbleConfig bubble = const ChatBubbleConfig(),
    String? name,
    String? logoUrl,
    String? greeting,
    Map<String, String> greetings = const <String, String>{},
    bool greetingPending = false,
  }) {
    _known = true;
    _enabled = enabled;
    _showBubble = showBubble;
    _online = online;
    _unread = unread;
    dashboardBubble = bubble;
    _config = ChatConfig(
      enabled: enabled,
      showBubble: showBubble,
      online: online,
      bubble: bubble,
      name: name,
      logoUrl: logoUrl,
      greeting: greeting,
      greetings: greetings,
    );
    _greetingPending = enabled && greetingPending;
    _publish();
  }

  /// Tests only: a frame as if it came on the app channel.
  @visibleForTesting
  void debugAppFrame(String text) => _appFrame(text);

  /// Tests only: a frame as if it came on the thread's socket.
  @visibleForTesting
  void debugFrame(String text) => _frame(text);

  /// Tests only: the app as if it were in front, or at the back.
  @visibleForTesting
  void debugActive(bool active) {
    _active = active;
    if (!active) banner.value = null;
    notifyListeners();
  }

  /// Tests only: back to a chat nobody has used and an SDK that is not
  /// configured yet. Call it inside the test: the stores keep their work in
  /// a line, and a line started in one test's clock never moves in the next.
  @visibleForTesting
  void debugReset() {
    _tokens = ChatTokenStore(_SecureStore(), _PrefsStore());
    _push = _newPushRegistrar();
    _ownBundleId = null;
    _ownBundleIdKnown = false;
    _ownBundleIdRead = null;
    _pushToken = null;
    _pushPlatform = null;
    _pushBundleId = null;
    _pushEnvironment = null;
    _token = null;
    _openRetry?.cancel();
    _openRetry = null;
    _openPending = false;
    _openTries = 0;
    _allowed = false;
    _greetingsShown.clear();
    _greetingPending = false;
    _codeWiggle = null;
    banner.value = null;
    _known = false;
    _enabled = false;
    _showBubble = false;
    _online = false;
    _unread = 0;
    _sheet = null;
    _isOpen = false;
    _active = true;
    _config = ChatConfig.off;
    dashboardBubble = const ChatBubbleConfig();
    _env = null;
    _forgetPending = false;
    _appRefused = false;
    _publish();
  }

  /// Tests only: as if configure() had finished, without asking the server
  /// anything (the app channel counts as refused, so no socket opens).
  @visibleForTesting
  void debugConfigured(ChatEnv env) {
    _env = env;
    _wanted = true;
    _appRefused = true;
    _tryPendingOpen();
    unawaited(_showGreetingIfDue());
  }

  void _publish() => _afterBuild(_publishNow);

  void _publishNow() {
    state.value = AffiliateoChatState(
      enabled: _enabled,
      showBubble: _enabled && _showBubble,
      online: _enabled && (_online || _visitorOnline),
      unread: _unread + (_greetingPending ? 1 : 0),
      isOpen: _isOpen,
    );
    // Never a banner over the open chat, and none left over once the chat is off.
    if (_isOpen || !_enabled) banner.value = null;
    notifyListeners();
    _syncSocket();
    _syncAppChannel();
    unawaited(_showGreetingIfDue());
  }

  Future<String?> _loadToken(String appId) async {
    try {
      return await _tokens.token(appId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshConfig({bool force = false}) {
    final env = _env;
    if (env == null) return Future<void>.value();
    final last = _lastConfig;
    if (!force && last != null && DateTime.now().difference(last) < _configEvery) return Future<void>.value();
    return _configInFlight ??= _askConfig(env).whenComplete(() => _configInFlight = null);
  }

  Future<void> _askConfig(ChatEnv env) async {
    _lastConfig = DateTime.now();
    try {
      final res = await http
          .get(Uri.parse('${env.apiBase}/api/live-chat/config?app=${Uri.encodeComponent(env.appId)}'))
          .timeout(_timeout);
      final config = readChatConfig(res.statusCode == 200 ? jsonDecode(res.body) : null);
      // The chat is on: the app channel may be tried again.
      if (config.enabled) _appRefused = false;
      await _applyConfig(config, env);
    } catch (_) {
      env.log('chat: config check failed (network)');
    }
  }

  /// A config, from a read or the app channel, applied the same way.
  Future<void> _applyConfig(ChatConfig config, ChatEnv? env) async {
    _known = true;
    _enabled = config.enabled;
    _showBubble = config.showBubble;
    _online = config.online;
    dashboardBubble = config.bubble;
    _config = config;
    final greetingId = config.enabled ? dashboardBubble.greetingId : null;
    if (greetingId == null || env == null) {
      _greetingPending = false;
    } else {
      final seen = (await _prefs())?.getString(_greetingKey(env.appId));
      final token = await _loadToken(env.appId);
      // Somebody who already wrote has seen it.
      _greetingPending = token == null && seen != greetingId;
    }
    _publish();
    // The phone is registered for replies once the chat is known to be on (4.17.0).
    syncPush();
  }

  /// A `config` frame from the app channel: kept as a fresh config read
  /// would be (the current config and its age) and applied the same way.
  /// Off, the bubble goes and an open chat closes.
  void _appFrame(Object? data) {
    final config = readAppFrame(data);
    if (config == null) return;
    _lastConfig = DateTime.now();
    if (!config.enabled) {
      _env?.log('chat: the chat was switched off for this app');
      close();
    }
    unawaited(_applyConfig(config, _env));
  }

  Future<void> _refreshUnread({bool force = false}) async {
    final env = _env;
    if (env == null) return;
    final last = _lastUnread;
    if (!force && last != null && DateTime.now().difference(last) < _unreadEvery) return;
    final signOut = _signOuts;
    final token = await _loadToken(env.appId);
    if (signOut != _signOuts) return;
    _token = token;
    if (token == null) {
      _publish();
      return;
    }
    _lastUnread = DateTime.now();
    try {
      final res = await http
          .get(Uri.parse('${env.apiBase}/api/live-chat/unread'), headers: {'Authorization': 'Bearer $token'})
          .timeout(_timeout);
      if (signOut != _signOuts) return;
      if (res.statusCode == 200) {
        final Object? json = jsonDecode(res.body);
        if (json is Map) {
          final unread = json['unread'];
          final online = json['online'];
          if (unread is num) _unread = unread.toInt();
          // Online for this person alone (the affiliate who brought them counts).
          if (online is bool) _visitorOnline = online;
        }
      }
    } catch (_) {
      // Keep the count.
    }
    if (signOut == _signOuts) _publish();
  }

  /// Opens the chat on [navigator]. [look] is the app's own send color and
  /// placeholder, over the ones AffiliateoChat set.
  Future<void> open(NavigatorState navigator, {ChatLook? look}) async {
    final env = _env;
    if (env == null) {
      debugPrint('[Affiliateo] openChat: call Affiliateo.configure() first');
      return;
    }
    want();
    if (!_known) await _refreshConfig(force: true);
    if (!_known) {
      env.log('chat: openChat skipped, the chat settings could not be loaded (network)');
      return;
    }
    if (!_enabled) {
      env.log('chat: openChat skipped, the chat is off for this app');
      return;
    }
    if (_isOpen) return;
    final signOut = _signOuts;
    final token = await _loadToken(env.appId);
    if (signOut != _signOuts || _isOpen || !navigator.mounted) return;
    _token = token;
    _isOpen = true;
    // They see the greeting now; a new one counts again.
    final greetingId = dashboardBubble.greetingId;
    if (greetingId != null) unawaited(_prefs().then((p) => p?.setString(_greetingKey(env.appId), greetingId)));
    _greetingPending = false;
    _publish();

    final sendColor = look?.sendColor ?? widgetLook.sendColor;
    final placeholder = look?.placeholder ?? widgetLook.placeholder;
    final url = chatPageUrl(
      apiBase: env.apiBase,
      appId: env.appId,
      android: Platform.isAndroid,
      language: _deviceLanguage(),
      optedOut: env.optedOut(),
      deviceId: env.deviceId(),
      visitorId: env.visitorId(),
      userId: env.userId(),
      token: token,
      sendColor: sendColor,
      placeholder: placeholder,
    );
    final route = _ChatSheetRoute(
      closeLabel: chatWords(_deviceLanguage())[1],
      // openedAt: a token the sheet hands over after a sign-out since then
      // belongs to the person who left.
      page: _ChatSheet(url: url, env: env, chat: this, openedAt: signOut),
    );
    _sheet = route;
    try {
      await navigator.push(route);
    } finally {
      _closed(route);
    }
  }

  /// The chat screen went away (closed, or removed with its navigator).
  void _closed(Route<Object?> route) {
    if (!identical(_sheet, route)) return;
    _sheet = null;
    _isOpen = false;
    _unread = 0;
    _publish();
    // A sign-in since the phone was registered: it is registered as that
    // person now, so their replies find it (the same registration is sent once).
    syncPush();
  }

  /// Closes the chat screen when it is open.
  void close() {
    final route = _sheet;
    final navigator = route?.navigator;
    if (route == null || navigator == null) return;
    if (route.isCurrent) {
      navigator.pop();
    } else if (route.isActive) {
      navigator.removeRoute(route);
      _closed(route);
    }
  }

  void _onToken(String token, int openedAt) {
    final env = _env;
    // Opened before a sign-out that has happened since: not saved.
    if (env == null || openedAt != _signOuts) return;
    _token = token;
    unawaited(_tokens.save(env.appId, token));
    // A thread of their own: after a sign-out the phone may be registered
    // for its replies again (4.17.0).
    syncPush();
  }

  void _onRead() {
    _unread = 0;
    _publish();
  }

  /// The person signed out (or another signed in): the chat drops their red
  /// number, socket and open chat first, so a token the open page still
  /// hands over is not saved again, then their key goes. The bubble's place
  /// and the greeting seen belong to the phone, not the person: they stay.
  Future<void> forget() async {
    _signOuts++;
    _lastUnread = null;
    _token = null;
    _unread = 0;
    _visitorOnline = false;
    // Nor does their banner, or the chat their tapped notification asked for.
    _afterBuild(() => banner.value = null);
    _openPending = false;
    _openRetry?.cancel();
    _openRetry = null;
    close();
    _publish();
    final env = _env;
    if (env == null) {
      _forgetPending = true;
      return;
    }
    final cleared = _tokens.clear(env.appId);
    // The server forgets this phone too (4.17.0): a reply to the last
    // person's thread must not show up for whoever holds the phone next. It
    // is registered again once the next person starts a thread of their own
    // (asked after the key above is gone, so the last person's does not count).
    unawaited(_push.forget(env.appId, token: _pushToken, platform: _pushPlatform));
    await cleared;
  }

  // ── Notifications (4.17.0) ─────────────────────────────────────────────

  /// The app handed over the phone's push token (registerChatPushToken).
  void setPushToken(String token, {String? platform, String? bundleId, String? environment}) {
    final own = Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : null);
    final phone = platform == 'ios' || platform == 'android' ? platform : own;
    if (phone == null) {
      _env?.log('chat: push tokens are for iPhone and Android');
      return;
    }
    _pushToken = token;
    _pushPlatform = phone;
    _pushBundleId = bundleId;
    _pushEnvironment = environment;
    // The registration needs to know whether the chat is on for this app.
    want();
    syncPush();
  }

  /// Brings Affiliateo's list in line with this phone (chat_push.dart). Safe
  /// to call as often as anything changes: the same registration is sent once.
  void syncPush() {
    if (_env == null) return;
    unawaited(_syncPush());
  }

  Future<void> _syncPush() async {
    // The bundle id or package name, when the app did not pass one: read
    // before the registration is built, so an iPhone's is never sent without.
    if (_pushToken != null && _pushBundleId == null && !_ownBundleIdKnown) {
      _ownBundleId = await (_ownBundleIdRead ??= _readOwnBundleId());
      _ownBundleIdKnown = true;
    }
    await _push.sync();
  }

  static Future<String?> _readOwnBundleId() async {
    try {
      final name = (await PackageInfo.fromPlatform()).packageName;
      return name.isEmpty ? null : name;
    } catch (_) {
      // No such plugin on this platform.
      return null;
    }
  }

  ChatPushState? _pushState() {
    final env = _env;
    if (env == null) return null;
    return ChatPushState(
      appId: env.appId,
      chatOn: _known && _enabled,
      optedOut: env.optedOut(),
      deviceId: env.deviceId(),
      visitorId: env.visitorId(),
      userId: env.userId(),
      language: _deviceLanguage(),
      // Not before the bundle id is known (the app's own, or the one it passed).
      token: _pushBundleId != null || _ownBundleIdKnown ? _pushToken : null,
      platform: _pushPlatform ?? (Platform.isAndroid ? 'android' : 'ios'),
      bundleId: _pushBundleId ?? _ownBundleId,
      // A debug or profile build's token is Apple's sandbox one; a wrong
      // guess is corrected by the server.
      environment: _pushEnvironment ?? (kReleaseMode ? 'production' : 'sandbox'),
    );
  }

  /// POST or DELETE /api/live-chat/push-devices. No key goes with it: the
  /// phone is named by the app and its token.
  Future<ChatPushAnswer> _sendPush(String method, Map<String, String> body) async {
    final env = _env;
    if (env == null) return ChatPushAnswer.noAnswer;
    final url = Uri.parse('${env.apiBase}/api/live-chat/push-devices');
    const headers = {'Content-Type': 'application/json'};
    try {
      final sending = method == 'DELETE'
          ? http.delete(url, headers: headers, body: jsonEncode(body))
          : http.post(url, headers: headers, body: jsonEncode(body));
      final res = await sending.timeout(_timeout);
      return chatPushAnswer(res.statusCode, res.body);
    } catch (_) {
      return ChatPushAnswer.noAnswer;
    }
  }

  /// The person tapped a chat notification (handleChatNotification): the
  /// chat opens over whatever is on screen, as openChat() does. After a cold
  /// start that is a moment later, so the request is kept until the SDK is
  /// configured, the app is in front and there is a navigator to open on.
  void openFromNotification() {
    _openPending = true;
    _openTries = 0;
    want();
    _afterBuild(_tryPendingOpen);
  }

  /// An AffiliateoChat came on screen: it knows the app's navigator.
  void navigatorPlaced(NavigatorState? Function() find) {
    _navigators.add(find);
    if (_openPending) {
      // Once this frame has built the app under it.
      SchedulerBinding.instance.addPostFrameCallback((_) => _tryPendingOpen());
    }
  }

  void navigatorRemoved(NavigatorState? Function() find) => _navigators.remove(find);

  /// The app's navigator: the one a placed AffiliateoChat found, else the
  /// first one in the app (for an app that opens the chat from its own button).
  NavigatorState? _hostNavigator() {
    for (final find in _navigators.toList()) {
      final navigator = find();
      if (navigator != null && navigator.mounted) return navigator;
    }
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    final navigator = _navigatorFor(root);
    return navigator != null && navigator.mounted ? navigator : null;
  }

  void _tryPendingOpen() {
    if (!_openPending) return;
    _openRetry?.cancel();
    _openRetry = null;
    // Not configured yet, or at the back: attach() and the app coming to the
    // front come back here.
    if (_env == null || !_active) return;
    final navigator = _hostNavigator();
    if (navigator == null) {
      // The app is still building its first screen: a few more looks, for
      // ten seconds. An app with no navigator at all never opens it.
      if (_openTries++ < 40) {
        _openRetry = Timer(const Duration(milliseconds: 250), _tryPendingOpen);
      } else {
        _openPending = false;
        _env?.log('chat: the notification\'s chat was skipped, the app has no Navigator to open it on');
      }
      return;
    }
    _openPending = false;
    unawaited(open(navigator));
  }

  /// The app says notifications are allowed (chatNotificationsAllowed): a
  /// greeting nobody on this phone has seen shows as a banner, now or as
  /// soon as the config is here.
  void notificationsAllowed() {
    _allowed = true;
    want();
    unawaited(_showGreetingIfDue());
  }

  /// An AffiliateoChat with `inAppBanner` on came on screen.
  void bannerPlaced() {
    _bannerPlaces++;
    unawaited(_showGreetingIfDue());
  }

  /// It went away (or switched its banner off).
  void bannerRemoved() {
    _bannerPlaces = max(0, _bannerPlaces - 1);
    if (_bannerPlaces == 0) banner.value = null;
  }

  /// The banner left the screen: its time ran out, it was swiped away or tapped.
  void dismissBanner(String id) {
    if (banner.value?.id == id) banner.value = null;
  }

  ChatBanner? _greetingBanner(String? notifiedId) => greetingBanner(
        config: _config,
        enabled: _bannerPlaces > 0,
        chatOpen: _isOpen,
        appActive: _active,
        language: _deviceLanguage(),
        allowed: _allowed,
        greetingPending: _greetingPending,
        notifiedId: notifiedId,
      );

  /// Shows the greeting as ONE banner per greeting and install
  /// (chat_rules.dart greetingBanner). The red 1 stays until the chat opens.
  Future<void> _showGreetingIfDue() async {
    final env = _env;
    if (env == null || _greetingBusy || _greetingBanner(null) == null) return;
    _greetingBusy = true;
    try {
      final prefs = await _prefs();
      final key = chatGreetingNotifiedKey(env.appId);
      // Asked again: the chat may have opened while the phone's storage answered.
      final next = _greetingBanner(prefs?.getString(key));
      final greetingId = next?.greetingId;
      if (next == null || greetingId == null || !_greetingsShown.add('${env.appId}:$greetingId')) return;
      unawaited(prefs?.setString(key, greetingId));
      banner.value = next;
    } finally {
      _greetingBusy = false;
    }
  }

  // ── The socket ─────────────────────────────────────────────────────────

  void _syncSocket() {
    final env = _env;
    final token = _token;
    final run = env != null && token != null && !_isOpen && _active && _enabled && _wanted;
    if (run && _socketToken == token) return;
    _stopSocket();
    if (!run) return;
    _socketToken = token;
    _tries = 0;
    unawaited(_connect(_socketRun, env, token));
  }

  void _stopSocket() {
    _socketRun++;
    _socketToken = null;
    _retry?.cancel();
    _retry = null;
    _ping?.cancel();
    _ping = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close().catchError((Object _) {}));
  }

  Future<void> _connect(int run, ChatEnv env, String token) async {
    if (run != _socketRun) return;
    // The key rides in the Authorization header, never in the address,
    // where it would land in the server's request logs.
    final url = '${env.apiBase.replaceFirst(RegExp('^http'), 'ws')}/api/live-chat/stream';
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(url, headers: {'Authorization': 'Bearer $token'}).timeout(_timeout);
    } catch (_) {
      _again(run, env, token);
      return;
    }
    if (run != _socketRun) {
      unawaited(socket.close().catchError((Object _) {}));
      return;
    }
    _socket = socket;
    _tries = 0;
    _ping = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        socket.add('ping');
      } catch (_) {
        // Closing.
      }
    });
    socket.listen(
      (Object? data) {
        if (run == _socketRun) _frame(data);
      },
      onError: (Object _) {},
      onDone: () {
        if (run != _socketRun) return;
        _ping?.cancel();
        _ping = null;
        _socket = null;
        _again(run, env, token);
      },
      cancelOnError: false,
    );
  }

  void _again(int run, ChatEnv env, String token) {
    if (run != _socketRun) return;
    _tries++;
    final ms = min(60000, 1000 * pow(2, min(_tries, 6)).toInt());
    _retry = Timer(Duration(milliseconds: ms), () => unawaited(_connect(run, env, token)));
  }

  // ── The app channel ────────────────────────────────────────────────────

  /// Opens or closes the app channel to match appChannelWanted. The chat
  /// sheet may be open or closed, and the bubble hidden by the page rules:
  /// the channel stays while a bubble is placed.
  void _syncAppChannel() {
    final env = _env;
    final wanted =
        env != null && appChannelWanted(bubblePlaced: _bubbles > 0, active: _active, enabled: _enabled, refused: _appRefused);
    if (wanted == _appOn) return;
    _stopAppChannel();
    if (!wanted) return;
    _appOn = true;
    unawaited(_connectApp(_appRun, env));
  }

  void _stopAppChannel() {
    _appRun++;
    _appOn = false;
    _appTries = 0;
    _appRetry?.cancel();
    _appRetry = null;
    _appPing?.cancel();
    _appPing = null;
    final socket = _appSocket;
    _appSocket = null;
    if (socket != null) unawaited(socket.close().catchError((Object _) {}));
  }

  Future<void> _connectApp(int run, ChatEnv env) async {
    if (run != _appRun) return;
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(appChannelUrl(env.apiBase, env.appId)).timeout(_timeout);
    } on WebSocketException catch (e) {
      if (run != _appRun) return;
      final status = upgradeStatus(e.toString());
      // An older Dart names no status: a refused upgrade reads as a refusal.
      if (refusesAppChannel(status) || (status == null && e.message.contains('not upgraded'))) {
        env.log('chat: app channel refused');
        _appRefused = true;
        _stopAppChannel();
        return;
      }
      _appAgain(run, env);
      return;
    } catch (_) {
      _appAgain(run, env);
      return;
    }
    if (run != _appRun) {
      unawaited(socket.close().catchError((Object _) {}));
      return;
    }
    _appSocket = socket;
    _appTries = 0;
    _appPing = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        socket.add('ping');
      } catch (_) {
        // Closing.
      }
    });
    socket.listen(
      (Object? data) {
        if (run == _appRun) _appFrame(data);
      },
      onError: (Object _) {},
      onDone: () {
        if (run != _appRun) return;
        _appPing?.cancel();
        _appPing = null;
        _appSocket = null;
        _appAgain(run, env);
      },
      cancelOnError: false,
    );
  }

  void _appAgain(int run, ChatEnv env) {
    if (run != _appRun) return;
    _appTries++;
    _appRetry = Timer(appChannelDelay(_appTries, Random().nextDouble()), () => unawaited(_connectApp(run, env)));
  }

  void _frame(Object? data) {
    if (data is! String || data == 'pong') return;
    Object? frame;
    try {
      frame = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (frame is! Map || frame['kind'] != 'live_chat') return;
    final message = frame['message'];
    if (frame['event'] == 'message' && message is Map && message['sender'] == 'team') {
      _unread++;
      _publish();
      // With the app in front and the chat closed, the reply shows as a
      // banner too (4.17.0), a newer one in place of the last.
      final next = replyBanner(
        frame,
        config: _config,
        enabled: _bannerPlaces > 0,
        chatOpen: _isOpen,
        appActive: _active,
        language: _deviceLanguage(),
      );
      if (next != null) banner.value = next;
    } else if (frame['event'] == 'read' && frame['by'] == 'visitor') {
      _unread = 0;
      _publish();
    }
  }
}

// ── The chat screen ──────────────────────────────────────────────────────

/// A sheet that slides up over the dimmed app, as in the other SDKs: a tap
/// on the app around it, the back button, a pull down on its handle or the
/// page's own close button closes it. Built on the plain navigator, so it
/// works in any app (Material, Cupertino or neither).
class _ChatSheetRoute extends PopupRoute<void> {
  _ChatSheetRoute({required this.page, required this.closeLabel});

  final Widget page;
  final String closeLabel;

  @override
  Color? get barrierColor => const Color(0x66000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => closeLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => page;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(curved),
      child: child,
    );
  }
}

class _ChatSheet extends StatefulWidget {
  const _ChatSheet({required this.url, required this.env, required this.chat, required this.openedAt});

  final String url;
  final ChatEnv env;
  final LiveChat chat;
  final int openedAt;

  @override
  State<_ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends State<_ChatSheet> {
  late final WebViewController _web;

  /// The key only the chat page's own frame is given (review S18): Flutter's
  /// web view puts its channels in every frame, so a message without it is a
  /// frame's, and nothing happens.
  final String _key = _newKey();

  static String _newKey() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// This sheet's route, so the chat hears it went away however it went.
  ModalRoute<Object?>? _route;

  /// A link the page names opens at most this often.
  DateTime _lastLink = DateTime.fromMillisecondsSinceEpoch(0);
  double _drag = 0;

  bool get _dark => PlatformDispatcher.instance.platformBrightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    final env = widget.env;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_dark ? const Color(0xFF111214) : const Color(0xFFFFFFFF))
      // Tells the page an app opened it; it carries nothing until the page
      // has the key (_giveKey).
      ..addJavaScriptChannel(chatBridgeName, onMessageReceived: (_) {})
      ..addJavaScriptChannel(chatKeyedBridgeName, onMessageReceived: (m) => unawaited(_received(m.message)))
      ..setNavigationDelegate(
        NavigationDelegate(
          // Only this app's own chat page loads in the sheet, frames inside
          // it only from the chat's origin (review S18, chatLoads).
          onNavigationRequest: (request) => chatLoads(
            request.url,
            isMainFrame: request.isMainFrame,
            apiBase: env.apiBase,
            appId: env.appId,
          )
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (url) => unawaited(_giveKey(url)),
        ),
      );
    unawaited(_web.loadRequest(Uri.parse(widget.url)));
  }

  /// Hands the chat page's own frame the key, and empties the page's own
  /// storage: the token lives in the secure store and goes with logout(), so
  /// no copy of it or of the transcript is left in the web view.
  Future<void> _giveKey(String url) async {
    if (!isChatPage(url, widget.env.apiBase, widget.env.appId)) return;
    final script = chatBridgeScript(_key, widget.env.apiBase);
    if (script == null) return;
    try {
      await _web.runJavaScript(script);
    } catch (_) {
      // The page went away.
    }
  }

  Future<void> _emptyPageStorage() async {
    try {
      await _web.runJavaScript('try{localStorage.clear()}catch(e){}');
    } catch (_) {
      // The page went away.
    }
  }

  Future<void> _received(String raw) async {
    final json = unkeyedMessage(raw, _key);
    if (json == null || !mounted) return;
    // Only this app's own chat page may speak, never another app's chat page.
    final current = await _web.currentUrl();
    if (!mounted || current == null || !isChatPage(current, widget.env.apiBase, widget.env.appId)) return;
    switch (parseHostMessage(json)) {
      case ChatTokenMessage(:final token):
        widget.chat._onToken(token, widget.openedAt);
        unawaited(_emptyPageStorage());
      case ChatReadMessage():
        widget.chat._onRead();
      case ChatCloseMessage():
        widget.chat.close();
      case ChatLinkMessage(:final url):
        // A link the person tapped in a team message (links=post).
        final now = DateTime.now();
        if (now.difference(_lastLink) > const Duration(seconds: 1)) {
          _lastLink = now;
          try {
            await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          } catch (_) {
            // Nothing on the phone opens it.
          }
        }
      case null:
        break;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
  }

  @override
  void dispose() {
    unawaited(_emptyPageStorage());
    // Later, outside the tree's teardown: a route removed with its navigator
    // never says it was popped.
    final route = _route;
    final chat = widget.chat;
    if (route != null) scheduleMicrotask(() => chat._closed(route));
    super.dispose();
  }

  void _dragUpdate(DragUpdateDetails details) {
    setState(() => _drag = max(0, _drag + details.delta.dy));
  }

  void _dragEnd(DragEndDetails details) {
    if (_drag > 120 || (details.primaryVelocity ?? 0) > 700) {
      widget.chat.close();
    } else {
      setState(() => _drag = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final background = _dark ? const Color(0xFF111214) : const Color(0xFFFFFFFF);
    final handle = _dark ? const Color(0x55FFFFFF) : const Color(0x33000000);
    return Padding(
      padding: EdgeInsets.only(top: media.padding.top + 12),
      child: Transform.translate(
        offset: Offset(0, _drag),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: ColoredBox(
            color: background,
            child: Padding(
              // The keyboard pushes the sheet's bottom up.
              padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
              child: Stack(
                children: [
                  Positioned.fill(child: WebViewWidget(controller: _web)),
                  // The handle the page leaves room for (sheet=1): pull it
                  // down to close.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 22,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: _dragUpdate,
                      onVerticalDragEnd: _dragEnd,
                      child: Center(
                        child: Container(
                          width: 36,
                          height: 5,
                          decoration: BoxDecoration(color: handle, borderRadius: BorderRadius.circular(2.5)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── The bubble ───────────────────────────────────────────────────────────

/// The floating chat bubble over your app (4.15.4). Place it once, around
/// the app's navigator:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => AffiliateoChat(child: child!),
///   home: const HomeScreen(),
/// )
/// ```
///
/// Tap to open the chat; press and move to drag it, and it remembers where
/// it was left. Hidden while the business has the chat off for this app, on
/// screens its page rules leave out (matched against the name you pass to
/// `Affiliateo.page`), and while the chat is open.
///
/// Since 4.17.0 it also wiggles every so often (the Wiggle setting in your
/// dashboard, or [wiggleSeconds]) and draws the SDK's own banner at the top
/// of the screen for a reply that arrives while the app is open
/// ([inAppBanner]).
///
/// Every setting is optional and wins over the Live Chat settings in your
/// Affiliateo dashboard; anything left out keeps the dashboard's choice.
class AffiliateoChat extends StatefulWidget {
  const AffiliateoChat({
    super.key,
    required this.child,
    this.visible = true,
    this.color,
    this.iconColor,
    this.sendColor,
    this.placeholder,
    this.bubbleStyle,
    this.corner,
    this.size,
    this.bottomPadding = 0,
    this.navigatorKey,
    this.wiggleSeconds,
    this.inAppBanner = true,
  });

  /// Your app (in MaterialApp.builder, the `child` it hands you).
  final Widget child;

  /// False hides the bubble (on a screen where it would cover something).
  final bool visible;

  /// The circle.
  final Color? color;

  /// The speech bubble inside the circle.
  final Color? iconColor;

  /// The send button and the person's own messages in the chat.
  final Color? sendColor;

  /// The message box text, in your own words and language (up to 60
  /// characters): pass your app's own translation.
  final String? placeholder;
  final AffiliateoChatBubbleStyle? bubbleStyle;
  final AffiliateoChatCorner? corner;

  /// In points, 40 to 80, for phones and tablets alike.
  final double? size;

  /// Extra room under the bubble, in points (a tab bar's height, say).
  final double bottomPadding;

  /// Your app's navigator key, when it has one; otherwise the bubble finds
  /// the navigator itself.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Seconds between two wiggles of the bubble (4.17.0), over the dashboard's
  /// Wiggle setting and over `Affiliateo.setChatBubbleWiggle`: a whole
  /// number, 3 or more; 0 for no wiggle. Leave it out and the dashboard (or
  /// `setChatBubbleWiggle`) decides.
  final int? wiggleSeconds;

  /// The SDK's own banner (4.17.0) for a reply that arrives while the app is
  /// open and the chat is closed, and for the greeting once after
  /// `Affiliateo.chatNotificationsAllowed()`: a card at the top of the
  /// screen for 5 seconds; a tap opens the chat. It shows over any screen,
  /// also while [visible] is false. Set it to false when your app shows chat
  /// notifications itself while it is open.
  final bool inAppBanner;

  @override
  State<AffiliateoChat> createState() => _AffiliateoChatState();
}

String? _hexOf(Color? color) {
  if (color == null) return null;
  // ignore: deprecated_member_use
  final rgb = color.value & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}

Color _colorOf(String hex) => Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

class _AffiliateoChatState extends State<AffiliateoChat> {
  final LiveChat _chat = LiveChat.instance;
  late final Listenable _changes = Listenable.merge([_chat, _chat.screen]);

  /// Every bubble on screen, checked after each frame for a sheet over it.
  static final Set<_AffiliateoChatState> _shown = {};
  static bool _watching = false;

  /// The app's own sheet, dialog or full-screen pop-up while it shows,
  /// sliding away included: the bubble hides under it, as in the other SDKs
  /// where those cover it. The bubble sits above the app's navigator, so it
  /// looks after each frame (frames run while a sheet opens or closes).
  ModalRoute<Object?>? _cover;

  /// Where the person left it: its distance from the right and bottom edges.
  Offset? _dragged;
  Offset _start = Offset.zero;
  Offset _moved = Offset.zero;
  bool _moving = false;
  bool _loadedPos = false;

  ChatLook get _look => ChatLook(
        color: _hexOf(widget.color),
        iconColor: _hexOf(widget.iconColor),
        sendColor: _hexOf(widget.sendColor),
        placeholder: widget.placeholder,
        style: widget.bubbleStyle,
        corner: widget.corner,
        size: widget.size,
        // This widget's own time first, then setChatBubbleWiggle's.
        wiggleSeconds: widget.wiggleSeconds ?? _chat.codeWiggle,
      );

  NavigatorState? _findNavigator() =>
      mounted ? widget.navigatorKey?.currentState ?? _navigatorFor(context) : null;

  @override
  void initState() {
    super.initState();
    _chat.widgetLook = _look;
    _chat.want();
    _chat.bubblePlaced();
    _chat.navigatorPlaced(_findNavigator);
    if (widget.inAppBanner) _chat.bannerPlaced();
    _shown.add(this);
    if (!_watching) {
      _watching = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        for (final bubble in _shown.toList()) {
          bubble._checkCover();
        }
      });
    }
  }

  void _checkCover() {
    if (!mounted) return;
    final navigator = widget.navigatorKey?.currentState ?? _navigatorFor(context);
    var cover = navigator == null ? null : _coverOn(navigator);
    final last = _cover;
    // Closed: still covering while it slides away.
    if (cover == null && last != null && !last.isActive && last.animation?.status != AnimationStatus.dismissed) {
      cover = last;
    }
    if (identical(cover, last)) return;
    _cover = cover;
    if ((cover == null) == (last == null)) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(AffiliateoChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    _chat.widgetLook = _look;
    if (widget.inAppBanner != oldWidget.inAppBanner) {
      // Later, outside this build: the banner on show may go with it.
      final on = widget.inAppBanner;
      scheduleMicrotask(() => on ? _chat.bannerPlaced() : _chat.bannerRemoved());
    }
  }

  @override
  void dispose() {
    _shown.remove(this);
    _chat.bubbleRemoved();
    _chat.navigatorRemoved(_findNavigator);
    _chat.widgetLook = const ChatLook();
    if (widget.inAppBanner) {
      // Later, outside the tree's teardown: the banner on show goes with the last place.
      final chat = _chat;
      scheduleMicrotask(chat.bannerRemoved);
    }
    super.dispose();
  }

  Future<void> _loadPos(String appId) async {
    _loadedPos = true;
    final raw = (await _prefs())?.getString(_posKey(appId));
    if (raw == null || !mounted) return;
    try {
      final saved = jsonDecode(raw);
      final x = saved is Map ? saved['x'] : null;
      final y = saved is Map ? saved['y'] : null;
      if (x is num && y is num) setState(() => _dragged = Offset(x.toDouble(), y.toDouble()));
    } catch (_) {
      // A broken note: the owner's corner.
    }
  }

  void _open() {
    final navigator = widget.navigatorKey?.currentState ?? _navigatorFor(context);
    if (navigator == null) {
      debugPrint('[Affiliateo] AffiliateoChat: no Navigator found; pass navigatorKey');
      return;
    }
    unawaited(_chat.open(navigator));
  }

  /// The phone asks for less motion: Android's "Remove animations" (or an
  /// animator scale of 0) reads as disableAnimations, the iPhone's Reduce
  /// Motion as reduceMotion.
  static bool _reduceMotion(MediaQueryData media) =>
      media.disableAnimations || WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion;

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _changes,
          builder: (context, _) => _bubble(context),
        ),
        // The banner shows over any screen, also one the bubble is hidden on.
        if (widget.inAppBanner)
          ValueListenableBuilder<ChatBanner?>(
            valueListenable: _chat.banner,
            builder: (context, banner, _) => banner == null ? const SizedBox.shrink() : _banner(context, banner),
          ),
      ],
    );
  }

  Widget _banner(BuildContext context, ChatBanner banner) {
    final media = MediaQuery.of(context);
    final bubble = applyChatLook(_chat.dashboardBubble, _look);
    return _ChatBannerCard(
      // A newer banner takes the place of the one on show.
      key: ValueKey<String>(banner.id),
      banner: banner,
      color: _colorOf(bubble.color),
      iconColor: _colorOf(bubble.iconColor),
      dark: media.platformBrightness == Brightness.dark,
      reduceMotion: _reduceMotion(media),
      insets: media.padding,
      onOpen: () {
        _chat.dismissBanner(banner.id);
        _open();
      },
      onDismiss: _chat.dismissBanner,
    );
  }

  Widget _bubble(BuildContext context) {
    final state = _chat.state.value;
    final bubble = applyChatLook(state.enabled ? _chat.dashboardBubble : const ChatBubbleConfig(), _look);
    if (!widget.visible ||
        _cover != null ||
        !state.showBubble ||
        state.isOpen ||
        !bubbleShowsOn(bubble.pageMode, bubble.pageRules, _chat.screen.value)) {
      return const SizedBox.shrink();
    }
    final appId = _chat._env?.appId;
    if (!_loadedPos && appId != null) unawaited(_loadPos(appId));

    final media = MediaQuery.of(context);
    final screen = media.size;
    final insets = media.padding;
    // A phone gets the owner's phone size ("auto" makes it smaller); a
    // tablet the other one.
    final size = screen.shortestSide < 600 ? bubble.sizePhone : bubble.size;
    const margin = 20.0;
    final corner = Offset(
      bubble.corner == AffiliateoChatCorner.bottomLeft || bubble.corner == AffiliateoChatCorner.topLeft
          ? screen.width - size - margin - insets.left
          : margin + insets.right,
      bubble.corner == AffiliateoChatCorner.topRight || bubble.corner == AffiliateoChatCorner.topLeft
          ? screen.height - size - margin - insets.top
          : margin + insets.bottom + widget.bottomPadding,
    );
    Offset clamp(Offset p) => Offset(
          p.dx.clamp(insets.right + 8, max(insets.right + 8, screen.width - size - insets.left - 8)).toDouble(),
          p.dy
              .clamp(insets.bottom + 8 + widget.bottomPadding,
                  max(insets.bottom + 8 + widget.bottomPadding, screen.height - size - insets.top - 8))
              .toDouble(),
        );
    final pos = clamp(_dragged ?? corner);
    final words = chatWords(_deviceLanguage());
    final label = state.unread > 0 ? words[2].replaceAll('{n}', '${state.unread}') : words[0];
    // The wiggle (4.17.0): every so many seconds the bubble does one short
    // wiggle and rests (chat_rules.dart mayWiggle says when). 0 holds still.
    final wiggles = mayWiggle(
      seconds: bubble.wiggleSeconds,
      visible: true,
      chatOpen: state.isOpen,
      appActive: _chat.active,
      dragging: _moving,
      reduceMotion: _reduceMotion(media),
    );

    return Positioned(
      right: pos.dx,
      bottom: pos.dy,
      child: Semantics(
        container: true,
        button: true,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          onPanStart: (_) {
            _start = pos;
            _moved = Offset.zero;
            _moving = false;
          },
          onPanUpdate: (d) {
            _moved += d.delta;
            if (!_moving && _moved.dx.abs() + _moved.dy.abs() < 6) return;
            // A bubble being dragged holds still (the rebuild rests its wiggle).
            _moving = true;
            setState(() => _dragged = clamp(Offset(_start.dx - _moved.dx, _start.dy - _moved.dy)));
          },
          onPanEnd: (_) {
            if (!_moving) {
              _open();
              return;
            }
            // Let go: it may wiggle again, a full wait from now.
            setState(() => _moving = false);
            final at = _dragged;
            if (appId != null && at != null) {
              unawaited(_prefs().then((p) => p?.setString(_posKey(appId), jsonEncode({'x': at.dx, 'y': at.dy}))));
            }
          },
          onPanCancel: () {
            if (_moving) setState(() => _moving = false);
          },
          // The whole bubble moves as one piece: the red number and the
          // green dot are part of the drawing.
          child: _ChatWiggle(
            seconds: wiggles ? bubble.wiggleSeconds : 0,
            child: CustomPaint(
              size: Size.square(size),
              painter: _BubblePainter(
                color: _colorOf(bubble.color),
                iconColor: _colorOf(bubble.iconColor),
                glass: bubble.style == AffiliateoChatBubbleStyle.glass,
                badge: badgeText(state.unread),
                online: state.online,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The wiggle (4.17.0, version 2): every [seconds] the bubble turns left and
/// right around its own center through three swings that die down, growing a
/// touch on the way, and rests (0.9 s; chat_rules.dart wiggleAngle and
/// wiggleScale). One value runs 0 to 1 at an even pace and the turn and the
/// size are worked out from the formulas on every frame, so the motion is a
/// smooth curve, never a few steps. The first wiggle comes a full wait after
/// the bubble shows. With [seconds] 0 (hidden, dragged, the chat open, the
/// app at the back, Reduce Motion) a wiggle under way is cut back to rest at
/// once.
class _ChatWiggle extends StatefulWidget {
  const _ChatWiggle({required this.seconds, required this.child});

  final int seconds;
  final Widget child;

  @override
  State<_ChatWiggle> createState() => _ChatWiggleState();
}

class _ChatWiggleState extends State<_ChatWiggle> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: wiggleDuration);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(_ChatWiggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seconds != oldWidget.seconds) _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    // Back to rest: the start of the curve, which is also its end.
    if (_turn.isAnimating || _turn.value != 0) _turn.value = 0;
    final seconds = widget.seconds;
    if (seconds <= 0) return;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted) return;
      // An even pace (no easing): the curve is in the formulas.
      _turn.forward(from: 0).whenCompleteOrCancel(() {
        if (mounted && !_turn.isAnimating) _turn.value = 0;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _turn,
      child: widget.child,
      builder: (context, child) {
        final p = _turn.value;
        return Transform.rotate(
          angle: wiggleAngle(p) * pi / 180,
          child: Transform.scale(scale: wiggleScale(p), child: child),
        );
      },
    );
  }
}

/// The SDK's own banner (4.17.0): a reply, or the greeting, as a card at the
/// top of the screen inside the safe area, like a notification. The business
/// logo (the bubble's chat icon when there is none), the Live Chat app's name
/// in bold and the message under it, two lines at most. It slides down, stays
/// chatBannerStay and slides away; a swipe up sends it away sooner and a tap
/// opens the chat. With Reduce Motion it fades instead of sliding. Light and
/// dark follow the phone. The same card as the React Native SDK's.
class _ChatBannerCard extends StatefulWidget {
  const _ChatBannerCard({
    super.key,
    required this.banner,
    required this.color,
    required this.iconColor,
    required this.dark,
    required this.reduceMotion,
    required this.insets,
    required this.onOpen,
    required this.onDismiss,
  });

  final ChatBanner banner;

  /// The bubble's colors, for the chat icon when there is no logo.
  final Color color;
  final Color iconColor;
  final bool dark;
  final bool reduceMotion;

  /// The safe area.
  final EdgeInsets insets;
  final VoidCallback onOpen;

  /// It left the screen: its time ran out or it was swiped away. Called with
  /// the banner's id.
  final void Function(String id) onDismiss;

  @override
  State<_ChatBannerCard> createState() => _ChatBannerCardState();
}

class _ChatBannerCardState extends State<_ChatBannerCard> with SingleTickerProviderStateMixin {
  /// 0: off screen (or see-through), 1: in place.
  late final AnimationController _place = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    reverseDuration: const Duration(milliseconds: 220),
  );
  late final Animation<double> _eased =
      CurvedAnimation(parent: _place, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  Timer? _stay;
  bool _leaving = false;
  double _swiped = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_place.forward());
    _stay = Timer(chatBannerStay, _leave);
  }

  /// Slides (or fades) away, then says it is gone.
  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _stay?.cancel();
    final id = widget.banner.id;
    final gone = widget.onDismiss;
    _place.reverse().whenCompleteOrCancel(() {
      if (mounted) gone(id);
    });
  }

  @override
  void dispose() {
    _stay?.cancel();
    _place.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banner = widget.banner;
    final dark = widget.dark;
    final insets = widget.insets;
    final top = insets.top + 8;
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final title = TextStyle(
      inherit: false,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: dark ? const Color(0xFFFFFFFF) : const Color(0xFF111111),
      decoration: TextDecoration.none,
    );
    final body = TextStyle(
      inherit: false,
      fontSize: 14,
      height: 19 / 14,
      fontWeight: FontWeight.w400,
      color: dark ? const Color(0xCCEBEBF5) : const Color(0xFF3C3C43),
      decoration: TextDecoration.none,
    );
    final glyph = _ChatGlyph(color: widget.color, iconColor: widget.iconColor);
    final logoUrl = banner.logoUrl;

    final card = Semantics(
      container: true,
      button: true,
      // Read out as a notification would be.
      liveRegion: true,
      label: '${banner.title}. ${banner.body}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        // A swipe up sends it away; anything else is left to the tap.
        onVerticalDragStart: (_) => _swiped = 0,
        onVerticalDragUpdate: (d) => _swiped += d.delta.dy,
        onVerticalDragEnd: (d) {
          if (_swiped < -12 || (d.primaryVelocity ?? 0) < -300) _leave();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.circular(20),
            border: dark ? Border.all(color: const Color(0x24FFFFFF), width: 0.5) : null,
            boxShadow: const [BoxShadow(color: Color(0x2E000000), blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            child: Row(
              children: [
                // Both pictures are decoration: the card itself is the
                // button, and it says the title and the message.
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox.square(
                    dimension: 38,
                    child: logoUrl == null
                        ? glyph
                        : Image.network(
                            logoUrl,
                            width: 38,
                            height: 38,
                            fit: BoxFit.cover,
                            excludeFromSemantics: true,
                            // While it loads, and when it cannot: the chat icon.
                            frameBuilder: (context, child, frame, loadedAtOnce) =>
                                frame == null && !loadedAtOnce ? glyph : child,
                            errorBuilder: (context, error, stack) => glyph,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(banner.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: title),
                      const SizedBox(height: 1),
                      Text(banner.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: body),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.only(top: top, left: insets.left + 12, right: insets.right + 12),
        // Only the card takes touches: the app beside it stays usable.
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            // No wider than a notification on a tablet.
            constraints: const BoxConstraints(maxWidth: 520),
            child: AnimatedBuilder(
              animation: _eased,
              child: Directionality(textDirection: direction, child: card),
              builder: (context, child) {
                final t = _eased.value;
                final faded = Opacity(opacity: t.clamp(0.0, 1.0).toDouble(), child: child);
                // Reduce Motion: it fades in place instead of sliding down.
                if (widget.reduceMotion) return faded;
                return Transform.translate(offset: Offset(0, -(top + 120) * (1 - t)), child: faded);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The bubble's chat icon on its color, for a banner with no logo.
class _ChatGlyph extends StatelessWidget {
  const _ChatGlyph({required this.color, required this.iconColor});

  final Color color;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: CustomPaint(size: const Size.square(38), painter: _GlyphPainter(iconColor)),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The speech bubble at 22 points, in the middle (60% of a circle 22 / 0.6 wide).
    const circle = 22 / 0.6;
    canvas.save();
    canvas.translate((size.width - circle) / 2, (size.height - circle) / 2);
    canvas.drawPath(_BubblePainter._speechBubble(circle), Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.color != color;
}

/// The bubble as the website and the other SDKs draw it: solid is the color
/// with light from the top left and a shadow in its own color; glass is the
/// color at 60%, light from the top, a fine white edge and a soft dark
/// shadow. The speech bubble is the icon color. The red number (or the green
/// dot while someone is online) sits on its edge, sized with the circle and
/// never with the font setting.
class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.color,
    required this.iconColor,
    required this.glass,
    required this.badge,
    required this.online,
  });

  final Color color;
  final Color iconColor;
  final bool glass;
  final String? badge;
  final bool online;

  static int _r(Color c) => (c.value >> 16) & 0xFF; // ignore: deprecated_member_use
  static int _g(Color c) => (c.value >> 8) & 0xFF; // ignore: deprecated_member_use
  static int _b(Color c) => c.value & 0xFF; // ignore: deprecated_member_use

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final r = s / 2;
    final center = Offset(r, r);
    final circle = Path()..addOval(Rect.fromCircle(center: center, radius: r));

    canvas.drawShadow(circle, glass ? const Color(0x2E000000) : color.withAlpha(0x59), 4, false);
    if (glass) {
      canvas.drawCircle(center, r, Paint()..color = Color.fromARGB(150, _r(color), _g(color), _b(color)));
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x5AFFFFFF), Color(0x00FFFFFF)],
          ).createShader(Offset.zero & size),
      );
      canvas.drawCircle(
        center,
        r - 0.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x8CFFFFFF),
      );
    } else {
      // color-mix(in oklab, color 55%, white), close enough in plain RGB.
      int light(int c) => (c * 0.55 + 255 * 0.45).round();
      final lighter = Color.fromARGB(255, light(_r(color)), light(_g(color)), light(_b(color)));
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [lighter, color],
          ).createShader(Offset.zero & size),
      );
    }
    canvas.drawPath(_speechBubble(s), Paint()..color = iconColor);

    final m = BadgeMetrics(s);
    final text = badge;
    if (text != null) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: m.pillFont, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = max(m.pillHeight, painter.width + m.pillPadding * 2 + m.border * 2);
      final pill = RRect.fromRectAndRadius(
        Rect.fromLTWH(s + m.pillOffset - width, -m.pillOffset, width, m.pillHeight),
        Radius.circular(m.pillHeight / 2),
      );
      canvas.drawRRect(pill, Paint()..color = const Color(0xFFEF4444));
      canvas.drawRRect(
        pill.deflate(m.border / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = m.border
          ..color = const Color(0xFFFFFFFF),
      );
      painter.paint(
        canvas,
        Offset(pill.left + (width - painter.width) / 2, pill.top + (m.pillHeight - painter.height) / 2),
      );
    } else if (online) {
      final dotCenter = Offset(-m.dotOffset + m.dot / 2, -m.dotOffset + m.dot / 2);
      canvas.drawCircle(dotCenter, m.dot / 2, Paint()..color = const Color(0xFF22C55E));
      canvas.drawCircle(
        dotCenter,
        m.dot / 2 - m.border / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = m.border
          ..color = const Color(0xFFFFFFFF),
      );
    }
  }

  /// The website bubble's speech bubble (public/chat.js, a 24-point drawing)
  /// filling 60% of a circle of [size].
  static Path _speechBubble(double size) {
    final scale = size * 0.6 / 24;
    final inset = size * 0.2;
    double p(double v) => inset + v * scale;
    return Path()
      ..moveTo(p(12), p(2.5))
      ..cubicTo(p(17.25), p(2.5), p(21.5), p(6.4), p(21.5), p(11.25))
      ..cubicTo(p(21.5), p(16.1), p(17.25), p(20), p(12), p(20))
      ..cubicTo(p(10.9), p(20), p(9.85), p(19.83), p(8.87), p(19.52))
      ..cubicTo(p(7.3), p(20.9), p(5.2), p(21.55), p(3.05), p(21.45))
      ..cubicTo(p(4.35), p(20.55), p(5.2), p(19.3), p(5.45), p(17.85))
      ..cubicTo(p(3.6), p(16.25), p(2.5), p(13.87), p(2.5), p(11.25))
      ..cubicTo(p(2.5), p(6.4), p(6.75), p(2.5), p(12), p(2.5))
      ..close();
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.color != color ||
      old.iconColor != iconColor ||
      old.glass != glass ||
      old.badge != badge ||
      old.online != online;
}
