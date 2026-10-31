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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
// chat is closed, a socket keeps the red number live.

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
  final ChatTokenStore _tokens = ChatTokenStore(_SecureStore(), _PrefsStore());

  /// What `Affiliateo.chatState` hands out.
  final ValueNotifier<AffiliateoChatState> state = ValueNotifier(const AffiliateoChatState());

  /// The screen the app last named with page(), for the bubble's page rules.
  final ValueNotifier<String?> screen = ValueNotifier<String?>(null);

  /// The dashboard's bubble (corner, size, screens, colors).
  ChatBubbleConfig dashboardBubble = const ChatBubbleConfig();

  /// The send color and placeholder the app's own code set (AffiliateoChat).
  ChatLook widgetLook = const ChatLook();

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

  /// configure() ran: where to ask and what the SDK knows.
  void attach(ChatEnv env) {
    if (_env != null) return;
    _env = env;
    if (_forgetPending) {
      _forgetPending = false;
      unawaited(_tokens.clear(env.appId));
    }
    if (_wanted) _start();
  }

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
    }
    _syncSocket();
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
  }) {
    _known = true;
    _enabled = enabled;
    _showBubble = showBubble;
    _online = online;
    _unread = unread;
    dashboardBubble = bubble;
    _publish();
  }

  void _publish() {
    state.value = AffiliateoChatState(
      enabled: _enabled,
      showBubble: _enabled && _showBubble,
      online: _enabled && (_online || _visitorOnline),
      unread: _unread + (_greetingPending ? 1 : 0),
      isOpen: _isOpen,
    );
    notifyListeners();
    _syncSocket();
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
      final Object? json = res.statusCode == 200 ? jsonDecode(res.body) : null;
      final Map<Object?, Object?>? config = json is Map && json['enabled'] == true ? json : null;
      _known = true;
      _enabled = config != null;
      _showBubble = config?['show_bubble'] == true;
      _online = config?['online'] == true;
      dashboardBubble = config != null ? readBubbleConfig(config['bubble']) : const ChatBubbleConfig();
      final greetingId = config != null ? dashboardBubble.greetingId : null;
      if (greetingId == null) {
        _greetingPending = false;
      } else {
        final seen = (await _prefs())?.getString(_greetingKey(env.appId));
        final token = await _loadToken(env.appId);
        // Somebody who already wrote has seen it.
        _greetingPending = token == null && seen != greetingId;
      }
      _publish();
    } catch (_) {
      env.log('chat: config check failed (network)');
    }
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
    close();
    _publish();
    final env = _env;
    if (env == null) {
      _forgetPending = true;
      return;
    }
    await _tokens.clear(env.appId);
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
      );

  @override
  void initState() {
    super.initState();
    _chat.widgetLook = _look;
    _chat.want();
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
  }

  @override
  void dispose() {
    _shown.remove(this);
    _chat.widgetLook = const ChatLook();
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
      ],
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
            _moving = true;
            setState(() => _dragged = clamp(Offset(_start.dx - _moved.dx, _start.dy - _moved.dy)));
          },
          onPanEnd: (_) {
            if (!_moving) {
              _open();
              return;
            }
            final at = _dragged;
            if (appId != null && at != null) {
              unawaited(_prefs().then((p) => p?.setString(_posKey(appId), jsonEncode({'x': at.dx, 'y': at.dy}))));
            }
          },
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
    );
  }
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
