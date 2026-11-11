import 'dart:convert';
import 'dart:math';

import 'package:affiliateo/affiliateo.dart';
import 'package:affiliateo/src/chat.dart';
import 'package:affiliateo/src/chat_rules.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

// What 4.17.0 draws and does on screen: the wiggle, the SDK's own banner, and
// a tapped notification opening the chat. The rules behind them are tested
// without a screen in chat_wiggle_test.dart and chat_notifications_test.dart.

// ── A stand-in web view, so the chat sheet can open in a test ────────────

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) =>
      _FakeWebViewController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      _FakeWebViewWidget(params);
}

/// The pages the chat sheets loaded, newest last.
final List<String> loadedPages = <String>[];

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(super.params) : super.implementation();

  String? _url;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams javaScriptChannelParams) async {}

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _url = params.uri.toString();
    loadedPages.add(_url!);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<String?> currentUrl() async => _url;
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: ValueKey<String>('chat-page'));
}

// ── The app under test ───────────────────────────────────────────────────

const appId = 'app_1';

ChatEnv env({bool optedOut = false}) => ChatEnv(
      apiBase: 'https://affiliateo.com',
      appId: appId,
      deviceId: () => 'device-1',
      visitorId: () => 'vis-1',
      userId: () => null,
      optedOut: () => optedOut,
      log: (_) {},
    );

PageRoute<T> _page<T>(RouteSettings settings, WidgetBuilder builder) => PageRouteBuilder<T>(
      settings: settings,
      pageBuilder: (context, _, __) => builder(context),
    );

/// An app with a navigator, the chat placed around it as the README says.
Widget app({Widget Function(Widget child)? wrap}) => WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: _page,
      home: const SizedBox.expand(),
      builder: (context, child) => (wrap ?? (child) => AffiliateoChat(child: child))(child!),
    );

/// The same app with no AffiliateoChat (it opens the chat from its own button).
Widget appWithoutBubble() => WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: _page,
      home: const SizedBox.expand(),
    );

/// A screen that talks to the SDK from initState(), as the README says to.
class _Screen extends StatefulWidget {
  const _Screen({required this.onInit});

  final VoidCallback onInit;

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

String reply(String id, String body) =>
    '{"kind":"live_chat","conversation_id":"c-1","event":"message","message":{"id":"$id","sender":"team","body":"$body"}}';

Finder get wiggle => find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_ChatWiggle');
Finder get bannerCard => find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_ChatBannerCard');
Finder get chatPage => find.byKey(const ValueKey<String>('chat-page'));

/// The bubble's turn right now, in degrees, and its size (1 at rest).
(double, double) turnOf(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(find.descendant(of: wiggle, matching: find.byType(Transform))).toList();
  final turn = transforms[0].transform;
  final size = transforms[1].transform;
  return (atan2(turn.entry(1, 0), turn.entry(0, 0)) * 180 / pi, size.entry(0, 0));
}

/// Lets the phone's storage and the chat's own steps answer.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

/// The banner's five seconds pass, and it slides (or fades) away.
Future<void> bannerLeaves(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// A widget test with a chat nobody has used yet, on a phone whose secure
/// store holds no thread key (a call to the real store would never answer in
/// a widget test). The chat is reset inside the test, on the test's own clock.
void chatTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    LiveChat.instance.debugReset();
    await body(tester);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final chat = LiveChat.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    WebViewPlatform.instance = _FakeWebViewPlatform();
    loadedPages.clear();
  });

  group('the wiggle', () {
    chatTest('every so many seconds the whole bubble turns along the curve, then rests', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer(bubble: const ChatBubbleConfig(wiggleSeconds: 10), unread: 2, online: true);
      await tester.pump();
      expect(wiggle, findsOneWidget);
      expect(turnOf(tester), (0.0, 1.0));

      // Not at once: the first wiggle comes a full wait after the bubble shows.
      await tester.pump(const Duration(seconds: 9));
      expect(turnOf(tester), (0.0, 1.0));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      // Each frame is worked out from the formula: here 75, 150, ... ms in.
      var elapsed = 0;
      var widest = 0.0;
      for (var frame = 0; frame < 11; frame++) {
        await tester.pump(const Duration(milliseconds: 75));
        elapsed += 75;
        final (degrees, size) = turnOf(tester);
        expect(degrees, closeTo(wiggleAngle(elapsed / 900), 1e-6), reason: '$elapsed ms');
        expect(size, closeTo(wiggleScale(elapsed / 900), 1e-9), reason: '$elapsed ms');
        widest = max(widest, degrees.abs());
      }
      // The first swing is the widest, about 14 degrees.
      expect(widest, closeTo(14.41, 0.05));

      // 900 ms: back at rest, exactly.
      await tester.pump(const Duration(milliseconds: 75));
      await tester.pump();
      expect(turnOf(tester), (0.0, 1.0));

      // And again one wait after the last one started.
      await tester.pump(const Duration(milliseconds: 9100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(turnOf(tester).$1, closeTo(wiggleAngle(75 / 900), 1e-6));
      await tester.pump(const Duration(seconds: 1));
    });

    chatTest('no wiggle when the dashboard says off or the config has no such field', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await tester.pump();
      await tester.pump(const Duration(seconds: 61));
      await tester.pump(const Duration(milliseconds: 75));
      expect(turnOf(tester), (0.0, 1.0));
    });

    chatTest('the app\'s own time wins: the widget\'s, then setChatBubbleWiggle, then the dashboard', (tester) async {
      // Whether the bubble turned on any frame of the next [ms] milliseconds.
      Future<bool> wigglesWithin(int ms) async {
        var moved = false;
        for (var elapsed = 0; elapsed < ms; elapsed += 100) {
          await tester.pump(const Duration(milliseconds: 100));
          if (turnOf(tester).$1 != 0) moved = true;
        }
        return moved;
      }

      // The dashboard says 30; the code says 5.
      await tester.pumpWidget(app());
      chat.debugAnswer(bubble: const ChatBubbleConfig(wiggleSeconds: 30));
      Affiliateo.setChatBubbleWiggle(seconds: 5);
      await tester.pump();
      expect(await wigglesWithin(4800), isFalse);
      expect(await wigglesWithin(1000), isTrue);

      // The widget's own argument wins over the call.
      await tester.pumpWidget(app(wrap: (child) => AffiliateoChat(wiggleSeconds: 8, child: child)));
      await tester.pump();
      expect(await wigglesWithin(7800), isFalse);
      expect(await wigglesWithin(1000), isTrue);

      // Off in code, whatever the dashboard says: null and 0 both.
      await tester.pumpWidget(app());
      Affiliateo.setChatBubbleWiggle(seconds: null);
      await tester.pump();
      expect(await wigglesWithin(31000), isFalse);
      Affiliateo.setChatBubbleWiggle(seconds: 0);
      await tester.pump();
      expect(await wigglesWithin(31000), isFalse);
      await tester.pumpWidget(app(wrap: (child) => AffiliateoChat(wiggleSeconds: 0, child: child)));
      Affiliateo.setChatBubbleWiggle(seconds: 5);
      await tester.pump();
      expect(await wigglesWithin(31000), isFalse);

      // A number under 3 counts as 3.
      await tester.pumpWidget(app(wrap: (child) => AffiliateoChat(wiggleSeconds: 1, child: child)));
      await tester.pump();
      expect(await wigglesWithin(2800), isFalse);
      expect(await wigglesWithin(1000), isTrue);
    });

    chatTest('never with Reduce Motion, on an iPhone or on Android', (tester) async {
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(app());
      for (final features in const [
        FakeAccessibilityFeatures(reduceMotion: true),
        FakeAccessibilityFeatures(disableAnimations: true),
      ]) {
        tester.platformDispatcher.accessibilityFeaturesTestValue = features;
        chat.debugAnswer(bubble: const ChatBubbleConfig(wiggleSeconds: 10));
        await tester.pump();
        await tester.pump(const Duration(seconds: 10));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        expect(turnOf(tester), (0.0, 1.0));
      }
      // Motion allowed again: it wiggles.
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      chat.debugAnswer(bubble: const ChatBubbleConfig(wiggleSeconds: 10), online: true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(turnOf(tester).$1, isNot(0));
      await tester.pump(const Duration(seconds: 1));
    });

    chatTest('a wiggle under way is cut back to rest when the app goes to the back or the bubble is dragged', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app());
      chat.debugAnswer(bubble: const ChatBubbleConfig(wiggleSeconds: 10));
      await tester.pump();

      Future<void> startWiggle() async {
        await tester.pump(const Duration(seconds: 10));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(turnOf(tester).$1.abs(), greaterThan(5));
      }

      // The app leaves the front.
      await startWiggle();
      chat.debugActive(false);
      await tester.pump();
      expect(turnOf(tester), (0.0, 1.0));
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(milliseconds: 75));
      expect(turnOf(tester), (0.0, 1.0));
      chat.debugActive(true);
      await tester.pump();

      // A finger drags it.
      await startWiggle();
      final gesture = await tester.startGesture(tester.getCenter(find.bySemanticsLabel('Chat')));
      await gesture.moveBy(const Offset(-30, -40));
      await gesture.moveBy(const Offset(-10, -10));
      await tester.pump();
      expect(turnOf(tester), (0.0, 1.0));
      // Held: no wiggle starts during the drag.
      await tester.pump(const Duration(seconds: 11));
      await tester.pump(const Duration(milliseconds: 75));
      expect(turnOf(tester), (0.0, 1.0));
      await gesture.up();
      await tester.pump();
      // Let go: a full wait, then it wiggles again.
      await startWiggle();
      await tester.pump(const Duration(seconds: 1));
      semantics.dispose();
    });
  });

  group('the banner', () {
    chatTest('a reply from the team shows as a card for five seconds, with the app\'s name and the message', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app());
      chat.debugAnswer(name: 'Copydraw');
      await tester.pump();
      expect(bannerCard, findsNothing);

      chat.debugFrame(reply('m-1', 'We fixed it. Try again?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(bannerCard, findsOneWidget);
      expect(find.text('Copydraw'), findsOneWidget);
      expect(find.text('We fixed it. Try again?'), findsOneWidget);
      // One button for a screen reader, saying both.
      expect(find.bySemanticsLabel('Copydraw. We fixed it. Try again?'), findsOneWidget);
      // At the top, inside the screen, and the red number counts the reply.
      expect(tester.getTopLeft(bannerCard.first).dy, lessThan(40));
      expect(Affiliateo.chatState.value.unread, 1);

      // Still there just before five seconds, gone after it slid away.
      await tester.pump(const Duration(milliseconds: 4600));
      expect(bannerCard, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(bannerCard, findsNothing);
      expect(chat.banner.value, isNull);
      semantics.dispose();
    });

    chatTest('a newer reply takes the place of the one on show; a message with no text has words', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer(name: 'Copydraw');
      await tester.pump();
      chat.debugFrame(reply('m-1', 'First'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      chat.debugFrame(reply('m-2', ''));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(bannerCard, findsOneWidget);
      expect(find.text('First'), findsNothing);
      expect(find.text('Sent you a message'), findsOneWidget);
      // The new one gets its own five seconds.
      await tester.pump(const Duration(seconds: 4));
      expect(bannerCard, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(bannerCard, findsNothing);
    });

    chatTest('no name anywhere says "Chat"; the business logo is asked for, the chat icon stands in', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer(logoUrl: 'https://cdn.affiliateo.com/logos/nico.png');
      await tester.pump();
      chat.debugFrame(reply('m-1', 'Hello'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.descendant(of: bannerCard, matching: find.text('Chat')), findsOneWidget);
      expect(find.descendant(of: bannerCard, matching: find.byType(Image)), findsOneWidget);
      expect(tester.takeException(), isNull);
      await bannerLeaves(tester);
    });

    chatTest('shows over a screen the bubble is hidden on, and not at all with inAppBanner off', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app(wrap: (child) => AffiliateoChat(visible: false, child: child)));
      chat.debugAnswer(name: 'Copydraw');
      await tester.pump();
      expect(find.bySemanticsLabel('Chat'), findsNothing);
      chat.debugFrame(reply('m-1', 'Hello'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(bannerCard, findsOneWidget);
      await bannerLeaves(tester);

      await tester.pumpWidget(app(wrap: (child) => AffiliateoChat(inAppBanner: false, child: child)));
      await tester.pump();
      chat.debugFrame(reply('m-2', 'Hello again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(bannerCard, findsNothing);
      // Nothing was kept to show later either.
      expect(chat.banner.value, isNull);
      // The red number still counts both.
      expect(Affiliateo.chatState.value.unread, 2);
      semantics.dispose();
    });

    chatTest('never while the app is at the back, and it goes when the chat is switched off', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer(name: 'Copydraw');
      await tester.pump();
      chat.debugActive(false);
      chat.debugFrame(reply('m-1', 'Hello'));
      await tester.pump();
      expect(chat.banner.value, isNull);

      chat.debugActive(true);
      chat.debugFrame(reply('m-2', 'Hello'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(bannerCard, findsOneWidget);
      chat.debugAppFrame('{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":false}}');
      await tester.pump();
      await tester.pump();
      expect(bannerCard, findsNothing);
    });

    chatTest('a swipe up sends it away sooner; a small move does not', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer(name: 'Copydraw');
      await tester.pump();
      chat.debugFrame(reply('m-1', 'Hello'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.drag(bannerCard, const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 300));
      expect(bannerCard, findsOneWidget);

      await tester.drag(bannerCard, const Offset(0, -40));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(bannerCard, findsNothing);
      expect(chat.banner.value, isNull);
    });

    chatTest('slides down from above the screen; with Reduce Motion it fades in place', (tester) async {
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(app());
      chat.debugAnswer(name: 'Copydraw');
      await tester.pump();

      double cardTop() => tester.getTopLeft(find.descendant(of: bannerCard, matching: find.byType(DecoratedBox)).first).dy;
      double opacity() => tester.widget<Opacity>(find.descendant(of: bannerCard, matching: find.byType(Opacity))).opacity;

      chat.debugFrame(reply('m-1', 'Hello'));
      await tester.pump();
      await tester.pump();
      // Just started: still above the screen and see-through.
      expect(cardTop(), lessThan(0));
      expect(opacity(), lessThan(0.2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cardTop(), 8);
      expect(opacity(), 1);
      await bannerLeaves(tester);
      expect(bannerCard, findsNothing);

      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(reduceMotion: true);
      chat.debugFrame(reply('m-2', 'Hello'));
      await tester.pump();
      await tester.pump();
      // In place from the first frame, only see-through.
      expect(cardTop(), 8);
      expect(opacity(), lessThan(0.2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(cardTop(), 8);
      expect(opacity(), 1);
      await bannerLeaves(tester);
    });

    chatTest('dark follows the phone', (tester) async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(app());
      chat.debugAnswer(name: 'Copydraw');
      await tester.pump();

      Color cardColor() => (tester
              .widget<DecoratedBox>(find.descendant(of: bannerCard, matching: find.byType(DecoratedBox)).first)
              .decoration as BoxDecoration)
          .color!;

      chat.debugFrame(reply('m-1', 'Hello'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(cardColor(), const Color(0xFFFFFFFF));
      expect(tester.widget<Text>(find.text('Copydraw')).style!.color, const Color(0xFF111111));

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      expect(cardColor(), const Color(0xFF2C2C2E));
      expect(tester.widget<Text>(find.text('Copydraw')).style!.color, const Color(0xFFFFFFFF));
      await bannerLeaves(tester);
    });

    chatTest('a tap opens the chat, and no banner shows over the open chat', (tester) async {
      await tester.pumpWidget(app());
      chat.debugConfigured(env());
      chat.debugAnswer(name: 'Copydraw');
      await tester.pump();
      chat.debugFrame(reply('m-1', 'Hello'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(bannerCard);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(chatPage, findsOneWidget);
      expect(bannerCard, findsNothing);
      expect(Affiliateo.chatState.value.isOpen, isTrue);
      expect(loadedPages.single, startsWith('https://affiliateo.com/embed/chat/app_1?lang='));

      // A reply while the chat is open is in front of the person already.
      chat.debugFrame(reply('m-2', 'More'));
      await tester.pump();
      expect(chat.banner.value, isNull);
      expect(bannerCard, findsNothing);

      Affiliateo.closeChat();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(chatPage, findsNothing);
    });
  });

  group('the greeting, once notifications are allowed', () {
    const greeting = 'Hi! Need help?';

    void answerWithGreeting({String id = 'g-1'}) => chat.debugAnswer(
          name: 'Copydraw',
          greeting: greeting,
          greetings: const {'es': '¡Hola! ¿Dudas?'},
          bubble: ChatBubbleConfig(greetingId: id),
          greetingPending: true,
        );

    chatTest('shows once as a banner, and the red 1 stays until the chat is opened', (tester) async {
      await tester.pumpWidget(app());
      chat.debugConfigured(env());
      answerWithGreeting();
      await settle(tester);
      // Not before the app says notifications are allowed.
      expect(bannerCard, findsNothing);
      expect(Affiliateo.chatState.value.unread, 1);

      Affiliateo.chatNotificationsAllowed();
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(bannerCard, findsOneWidget);
      expect(find.text('Copydraw'), findsOneWidget);
      expect(find.text(greeting), findsOneWidget);
      expect(chat.banner.value?.kind, ChatBannerKind.greeting);
      // The phone remembers which greeting it showed.
      expect((await SharedPreferences.getInstance()).getString(chatGreetingNotifiedKey(appId)), 'g-1');

      await bannerLeaves(tester);
      expect(bannerCard, findsNothing);
      expect(Affiliateo.chatState.value.unread, 1);

      // Told again (the next launch does), a fresh config read: never twice.
      Affiliateo.chatNotificationsAllowed();
      answerWithGreeting();
      await settle(tester);
      expect(bannerCard, findsNothing);
      expect(chat.banner.value, isNull);
    });

    chatTest('allowed before the config is here: it shows when the config arrives', (tester) async {
      await tester.pumpWidget(app());
      Affiliateo.chatNotificationsAllowed();
      await settle(tester);
      expect(chat.banner.value, isNull);
      chat.debugConfigured(env());
      answerWithGreeting();
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(greeting), findsOneWidget);
      await bannerLeaves(tester);
    });

    chatTest('a phone that showed this greeting in an earlier launch does not show it again; a new greeting shows', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{chatGreetingNotifiedKey(appId): 'g-1'});
      await tester.pumpWidget(app());
      chat.debugConfigured(env());
      Affiliateo.chatNotificationsAllowed();
      answerWithGreeting();
      await settle(tester);
      expect(chat.banner.value, isNull);

      answerWithGreeting(id: 'g-2');
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(bannerCard, findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString(chatGreetingNotifiedKey(appId)), 'g-2');
      await bannerLeaves(tester);
    });

    chatTest('nothing without a place to draw it, and it is not counted as shown', (tester) async {
      await tester.pumpWidget(app(wrap: (child) => AffiliateoChat(inAppBanner: false, child: child)));
      chat.debugConfigured(env());
      Affiliateo.chatNotificationsAllowed();
      answerWithGreeting();
      await settle(tester);
      expect(chat.banner.value, isNull);
      expect((await SharedPreferences.getInstance()).getString(chatGreetingNotifiedKey(appId)), isNull);

      // The banner is switched on later: now it shows.
      await tester.pumpWidget(app());
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(greeting), findsOneWidget);
      await bannerLeaves(tester);
    });

    chatTest('not once the person has seen the greeting in the chat', (tester) async {
      await tester.pumpWidget(app());
      chat.debugConfigured(env());
      chat.debugAnswer(name: 'Copydraw', greeting: greeting, bubble: const ChatBubbleConfig(greetingId: 'g-1'));
      Affiliateo.chatNotificationsAllowed();
      await settle(tester);
      expect(chat.banner.value, isNull);
    });
  });

  group('the push token, from the app to Affiliateo', () {
    final fcm = 'dQw4w9WgXcQ:APA91bHuN7xK${'Zq-9_Lm' * 20}';
    const configOn =
        '{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":true,"show_bubble":true,"app":{"id":"app_1","name":"Copydraw"}}}';

    /// Runs [body] with a stand-in for Affiliateo's server that says yes and
    /// keeps what it was sent.
    Future<void> withServer(Future<void> Function(List<http.Request> requests) body) {
      final requests = <http.Request>[];
      return http.runWithClient(
        () => body(requests),
        () => MockClient((request) async {
          requests.add(request);
          return http.Response('{"ok":true}', 200, headers: {'content-type': 'application/json'});
        }),
      );
    }

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'Example',
        packageName: 'com.example.app',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
    });

    chatTest('registers once the chat is on, with the app\'s own package name and display "system"', (tester) async {
      await withServer((requests) async {
        await tester.pumpWidget(app());
        chat.debugConfigured(env());
        Affiliateo.registerChatPushToken(fcm, 'android');
        await settle(tester);
        // Not before the server said the chat is on.
        expect(requests, isEmpty);

        chat.debugAppFrame(configOn);
        await settle(tester);
        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.method, 'POST');
        expect(request.url.toString(), 'https://affiliateo.com/api/live-chat/push-devices');
        expect(request.headers['content-type'], startsWith('application/json'));
        // No key and no sign-in go with it.
        expect(request.headers.containsKey('authorization'), isFalse);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['app'], appId);
        expect(body['platform'], 'android');
        expect(body['token'], fcm);
        expect(body['device_id'], 'device-1');
        expect(body['visitor_id'], 'vis-1');
        expect(body['bundle_id'], 'com.example.app');
        expect(body['display'], 'system');
        expect(body['language'], isNotEmpty);
        expect(body.containsKey('user_id'), isFalse);
        expect(body.containsKey('environment'), isFalse);

        // The same token again, another config read, the chat closing: sent once.
        Affiliateo.registerChatPushToken(fcm, 'android');
        chat.debugAppFrame(configOn);
        await settle(tester);
        expect(requests, hasLength(1));
      });
    });

    chatTest('an iPhone says its bundle id and which of Apple\'s services the token is for', (tester) async {
      await withServer((requests) async {
        await tester.pumpWidget(app());
        chat.debugConfigured(env());
        chat.debugAppFrame(configOn);
        Affiliateo.registerChatPushToken('AB' * 32, ' iOS ', bundleId: 'com.you.app', environment: 'production');
        await settle(tester);
        final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
        expect(body['platform'], 'ios');
        expect(body['token'], 'ab' * 32);
        expect(body['bundle_id'], 'com.you.app');
        expect(body['environment'], 'production');

        // Left out, a test (debug) build counts as Apple's sandbox.
        Affiliateo.registerChatPushToken('cd' * 32, 'ios');
        await settle(tester);
        final next = jsonDecode(requests.last.body) as Map<String, dynamic>;
        expect(next['token'], 'cd' * 32);
        expect(next['bundle_id'], 'com.example.app');
        expect(next['environment'], 'sandbox');
      });
    });

    chatTest('a sign-out takes the phone off the list, and opting out does too', (tester) async {
      await withServer((requests) async {
        var optedOut = false;
        await tester.pumpWidget(app());
        chat.debugConfigured(ChatEnv(
          apiBase: 'https://affiliateo.com',
          appId: appId,
          deviceId: () => 'device-1',
          visitorId: () => null,
          userId: () => 'user-1',
          optedOut: () => optedOut,
          log: (_) {},
        ));
        chat.debugAppFrame(configOn);
        Affiliateo.registerChatPushToken(fcm, 'android');
        await settle(tester);
        expect(requests.map((r) => r.method), ['POST']);
        expect((jsonDecode(requests.last.body) as Map<String, dynamic>)['user_id'], 'user-1');

        // Opted out of tracking: forgotten.
        optedOut = true;
        chat.syncPush();
        await settle(tester);
        expect(requests.map((r) => r.method), ['POST', 'DELETE']);
        expect(jsonDecode(requests.last.body), {'app': appId, 'token': fcm});
        expect(requests.last.url.toString(), 'https://affiliateo.com/api/live-chat/push-devices');

        // Opted in again: registered again.
        optedOut = false;
        chat.syncPush();
        await settle(tester);
        expect(requests.map((r) => r.method), ['POST', 'DELETE', 'POST']);

        // logout(): forgotten, and held until the next person has a thread.
        await chat.forget();
        await settle(tester);
        expect(requests.map((r) => r.method), ['POST', 'DELETE', 'POST', 'DELETE']);
        chat.debugAppFrame(configOn);
        Affiliateo.registerChatPushToken(fcm, 'android');
        await settle(tester);
        expect(requests, hasLength(4));
      });
    });
  });

  group('called from a screen\'s initState(), under the bubble', () {
    Future<void> openScreen(WidgetTester tester, GlobalKey<NavigatorState> navigator, VoidCallback onInit) async {
      navigator.currentState!.push(PageRouteBuilder<void>(pageBuilder: (_, __, ___) => _Screen(onInit: onInit)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Widget appWith(GlobalKey<NavigatorState> navigator) => WidgetsApp(
          navigatorKey: navigator,
          color: const Color(0xFF000000),
          pageRouteBuilder: _page,
          home: const SizedBox.expand(),
          builder: (context, child) => AffiliateoChat(child: child!),
        );

    chatTest('page() moves the bubble\'s page rules without an error', (tester) async {
      final semantics = tester.ensureSemantics();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));
      chat.debugAnswer(bubble: const ChatBubbleConfig(pageMode: ChatPageMode.except, pageRules: ['paywall']));
      await tester.pump();
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);

      await openScreen(tester, navigator, () => Affiliateo.page('paywall'));
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Chat'), findsNothing);

      await openScreen(tester, navigator, () => Affiliateo.page('settings'));
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);
      chat.screen.value = null;
      semantics.dispose();
    });

    chatTest('setChatBubbleWiggle, handleChatNotification and logout() are safe there too', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(appWith(navigator));
      chat.debugConfigured(env());
      chat.debugAnswer(unread: 3);
      await tester.pump();

      await openScreen(tester, navigator, () => Affiliateo.setChatBubbleWiggle(seconds: 4));
      expect(tester.takeException(), isNull);
      // Within the next five seconds the bubble wiggles at the app's own pace.
      var wiggled = false;
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (turnOf(tester).$1 != 0) wiggled = true;
      }
      expect(wiggled, isTrue);

      await openScreen(tester, navigator, () => chat.forget());
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(Affiliateo.chatState.value.unread, 0);

      await openScreen(tester, navigator, () => Affiliateo.handleChatNotification({'affiliateo_chat': '1'}));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(chatPage, findsOneWidget);
    });
  });

  group('a tapped notification', () {
    const push = {'affiliateo_chat': '1', 'app': appId, 'conversation_id': 'c-1', 'message_id': 'm-1'};

    chatTest('one that is not the chat\'s is left to the app', (tester) async {
      await tester.pumpWidget(app());
      chat.debugConfigured(env());
      chat.debugAnswer();
      await tester.pump();
      expect(Affiliateo.isChatNotification({'screen': 'offers'}), isFalse);
      expect(Affiliateo.handleChatNotification({'screen': 'offers'}), isFalse);
      expect(Affiliateo.handleChatNotification(null), isFalse);
      await settle(tester);
      expect(chatPage, findsNothing);
      expect(Affiliateo.chatState.value.isOpen, isFalse);
    });

    chatTest('opens the chat over the screen the app is on', (tester) async {
      await tester.pumpWidget(app());
      chat.debugConfigured(env());
      chat.debugAnswer();
      await tester.pump();
      expect(Affiliateo.isChatNotification(push), isTrue);
      expect(Affiliateo.handleChatNotification(push), isTrue);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(chatPage, findsOneWidget);
      expect(Affiliateo.chatState.value.isOpen, isTrue);
      // The iPhone's shape opens it too; already open, nothing more happens.
      expect(
        Affiliateo.handleChatNotification({
          'affiliateo_chat': {'app': appId, 'conversation_id': 'c-1', 'message_id': 'm-2'},
        }),
        isTrue,
      );
      await settle(tester);
      expect(loadedPages, hasLength(1));
    });

    chatTest('after a cold start: kept until the SDK is configured and the app has a screen', (tester) async {
      // The tap comes first: nothing is configured, nothing is on screen.
      expect(Affiliateo.handleChatNotification(push), isTrue);
      await tester.pump(const Duration(milliseconds: 600));
      expect(Affiliateo.chatState.value.isOpen, isFalse);

      // configure() finishes before the first screen is built.
      chat.debugAnswer();
      chat.debugConfigured(env());
      await tester.pump(const Duration(milliseconds: 600));
      expect(Affiliateo.chatState.value.isOpen, isFalse);

      // The app builds its first screen.
      await tester.pumpWidget(app());
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(chatPage, findsOneWidget);
      expect(Affiliateo.chatState.value.isOpen, isTrue);
      expect(loadedPages, hasLength(1));
    });

    chatTest('after a cold start the other way round: the screen first, configure() later', (tester) async {
      await tester.pumpWidget(app());
      expect(Affiliateo.handleChatNotification(push), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(chatPage, findsNothing);
      chat.debugAnswer();
      chat.debugConfigured(env());
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(chatPage, findsOneWidget);
    });

    chatTest('waits for the app to be in front', (tester) async {
      await tester.pumpWidget(app());
      chat.debugConfigured(env());
      chat.debugAnswer();
      chat.debugActive(false);
      expect(Affiliateo.handleChatNotification(push), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(chatPage, findsNothing);
    });

    chatTest('works in an app that has no AffiliateoChat placed', (tester) async {
      await tester.pumpWidget(appWithoutBubble());
      chat.debugConfigured(env());
      chat.debugAnswer();
      expect(Affiliateo.handleChatNotification(push), isTrue);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(chatPage, findsOneWidget);
    });

    chatTest('a chat that is off for the app does not open', (tester) async {
      await tester.pumpWidget(app());
      chat.debugConfigured(env());
      chat.debugAnswer(enabled: false);
      expect(Affiliateo.handleChatNotification(push), isTrue);
      await settle(tester);
      expect(chatPage, findsNothing);
      expect(Affiliateo.chatState.value.isOpen, isFalse);
    });

    chatTest('a sign-out drops a chat that was still waiting to open', (tester) async {
      await tester.pumpWidget(app());
      expect(Affiliateo.handleChatNotification(push), isTrue);
      await chat.forget();
      chat.debugAnswer();
      chat.debugConfigured(env());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(chatPage, findsNothing);
    });
  });
}
