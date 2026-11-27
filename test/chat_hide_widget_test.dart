import 'dart:math';

import 'package:affiliateo/affiliateo.dart';
import 'package:affiliateo/src/chat.dart';
import 'package:affiliateo/src/chat_rules.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

// Hold to hide on screen (4.19.0): the hold, hide mode (the rock and the X),
// the X hiding the bubble on this phone, and what ends hide mode. The rules
// behind it are tested without a screen in chat_hide_test.dart.

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
  Future<void> loadRequest(LoadRequestParams params) async => _url = params.uri.toString();

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
final hiddenKey = chatHiddenKey(appId);

/// What the SDK logged, newest last.
final List<String> logs = <String>[];

/// The haptics the phone was asked for, newest last.
final List<String> haptics = <String>[];

/// Taps the app itself got.
int appTaps = 0;

ChatEnv env() => ChatEnv(
      apiBase: 'https://affiliateo.com',
      appId: appId,
      deviceId: () => 'device-1',
      visitorId: () => 'vis-1',
      userId: () => null,
      optedOut: () => false,
      log: logs.add,
    );

PageRoute<T> _page<T>(RouteSettings settings, WidgetBuilder builder) => PageRouteBuilder<T>(
      settings: settings,
      pageBuilder: (context, _, __) => builder(context),
    );

/// An app with a navigator and a screen that counts its own taps, the chat
/// placed around it as the README says.
Widget app({bool visible = true}) => WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: _page,
      home: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => appTaps++,
        child: const SizedBox.expand(),
      ),
      builder: (context, child) => AffiliateoChat(visible: visible, child: child!),
    );

Finder get bubble => find.bySemanticsLabel('Chat');
Finder get theX => find.bySemanticsLabel('Hide chat bubble');
Finder get chatPage => find.byKey(const ValueKey<String>('chat-page'));
Finder get jiggle => find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_ChatJiggle');
Finder get wiggle => find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_ChatWiggle');

double _degrees(Matrix4 m) => atan2(m.entry(1, 0), m.entry(0, 0)) * 180 / pi;

/// Hide mode's rock right now, in degrees.
double rockOf(WidgetTester tester) =>
    _degrees(tester.widgetList<Transform>(find.descendant(of: jiggle, matching: find.byType(Transform))).first.transform);

/// The attention wiggle's turn right now, in degrees, and its size (1 at rest).
(double, double) turnOf(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(find.descendant(of: wiggle, matching: find.byType(Transform))).toList();
  return (_degrees(transforms[0].transform), transforms[1].transform.entry(0, 0));
}

/// Lets the phone's storage and the chat's own steps answer.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

/// A finger down on the bubble, kept still for the whole second: hide mode.
/// The finger is still down.
Future<TestGesture> holdBubble(WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(bubble));
  await tester.pump(holdToHideDuration);
  await tester.pump();
  return gesture;
}

/// Hide mode, the finger lifted.
Future<void> startHideMode(WidgetTester tester) async {
  final gesture = await holdBubble(tester);
  await gesture.up();
  await tester.pump();
  expect(theX, findsOneWidget);
}

Future<bool?> remembered() async => (await SharedPreferences.getInstance()).getBool(hiddenKey);

/// The chat opened from the bubble and is on screen.
Future<void> chatOpens(WidgetTester tester) async {
  await settle(tester);
  await tester.pump(const Duration(milliseconds: 300));
  expect(chatPage, findsOneWidget);
  expect(Affiliateo.chatState.value.isOpen, isTrue);
  Affiliateo.closeChat();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await settle(tester);
  expect(chatPage, findsNothing);
}

/// A widget test with a chat nobody has used yet, configured, on a phone
/// whose secure store holds no thread key. The chat is shown on [app].
void hideTest(String description, Future<void> Function(WidgetTester tester) body, {bool configured = true}) {
  testWidgets(description, (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}');
      return null;
    });
    final semantics = tester.ensureSemantics();
    LiveChat.instance.debugReset();
    if (configured) LiveChat.instance.debugConfigured(env());
    await body(tester);
    semantics.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final chat = LiveChat.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    WebViewPlatform.instance = _FakeWebViewPlatform();
    logs.clear();
    haptics.clear();
    appTaps = 0;
  });

  group('the hold', () {
    hideTest('a one second hold shows the X with a tick, and that touch neither opens nor drags', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer(online: true);
      await settle(tester);
      final place = tester.getTopLeft(bubble);

      final gesture = await tester.startGesture(tester.getCenter(bubble));
      await tester.pump(const Duration(milliseconds: 900));
      expect(theX, findsNothing);
      expect(haptics, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // At once, with the finger still down.
      expect(theX, findsOneWidget);
      expect(haptics, ['HapticFeedbackType.mediumImpact']);

      // The rest of the touch: moving does not drag, lifting does not open.
      await gesture.moveBy(const Offset(-60, -80));
      await tester.pump();
      await gesture.up();
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(chatPage, findsNothing);
      expect(Affiliateo.chatState.value.isOpen, isFalse);
      // Level for the comparison: hide mode is still on, and rocking.
      expect(theX, findsOneWidget);
      await tester.pump(hideModeDuration);
      await tester.pump();
      expect(tester.getTopLeft(bubble), place);
      expect(await remembered(), isNull);
    });

    hideTest('a drag past the slop before the second still drags, and no X', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      final place = tester.getTopLeft(bubble);

      final gesture = await tester.startGesture(tester.getCenter(bubble));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveBy(const Offset(-30, -40));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(-20, -20));
      await tester.pump();
      // Past the hold's second, still down: a drag stays a drag.
      await tester.pump(const Duration(milliseconds: 1200));
      expect(theX, findsNothing);
      expect(haptics, isEmpty);
      await gesture.up();
      await settle(tester);
      final moved = tester.getTopLeft(bubble);
      expect(moved.dx, lessThan(place.dx));
      expect(moved.dy, lessThan(place.dy));
      expect((await SharedPreferences.getInstance()).getString('affiliateo_chat_pos_$appId'), isNotNull);
      expect(chatPage, findsNothing);
    });

    hideTest('a quick tap still opens the chat', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      await tester.tap(bubble);
      await chatOpens(tester);
      expect(theX, findsNothing);
      expect(haptics, isEmpty);
    });

    hideTest('a press of most of a second, still, is still a tap', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      final gesture = await tester.startGesture(tester.getCenter(bubble));
      await tester.pump(const Duration(milliseconds: 800));
      await gesture.up();
      await chatOpens(tester);
      expect(theX, findsNothing);
    });
  });

  group('the X', () {
    hideTest('a tap on it hides the bubble, remembers it, and calls the app once', (tester) async {
      var calls = 0;
      Affiliateo.onChatBubbleHidden(() => calls++);
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      await startHideMode(tester);

      await tester.tap(theX);
      await settle(tester);
      expect(bubble, findsNothing);
      expect(theX, findsNothing);
      expect(calls, 1);
      expect(haptics, ['HapticFeedbackType.mediumImpact', 'HapticFeedbackType.lightImpact']);
      expect(await remembered(), isTrue);
      expect(await Affiliateo.isChatBubbleHiddenByUser(), isTrue);

      // A fresh config, the app channel, a sign-out: it stays away, and the
      // app hears of it once.
      chat.debugAnswer(online: true);
      await settle(tester);
      expect(bubble, findsNothing);
      await chat.forget();
      await settle(tester);
      expect(bubble, findsNothing);
      expect(await remembered(), isTrue);
      expect(calls, 1);
      // The chat itself still opens from the app's own button.
      expect(await Affiliateo.chatAvailable(), isTrue);
    });

    hideTest('null clears the callback', (tester) async {
      var calls = 0;
      Affiliateo.onChatBubbleHidden(() => calls++);
      Affiliateo.onChatBubbleHidden(null);
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      await startHideMode(tester);
      await tester.tap(theX);
      await settle(tester);
      expect(bubble, findsNothing);
      expect(calls, 0);
    });

    hideTest('sits on the top-left, over the circle\'s edge, in a 36 point target', (tester) async {
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      // Level, so the places can be measured.
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpWidget(app());
      chat.debugAnswer(online: true, unread: 3);
      await settle(tester);
      final circle = tester.getTopLeft(find.bySemanticsLabel('Chat, 3 unread'));

      final gesture = await tester.startGesture(tester.getCenter(find.bySemanticsLabel('Chat, 3 unread')));
      await tester.pump(holdToHideDuration);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // The 36 point target, 9 past the 18 point square on each side.
      expect(tester.getTopLeft(theX), circle + const Offset(-12, -12));
      expect(tester.getSize(theX), const Size(36, 36));
      final square = find.descendant(of: theX, matching: find.byType(CustomPaint));
      expect(tester.getTopLeft(square), circle + const Offset(-3, -3));
      expect(tester.getSize(square), const Size(18, 18));
      expect(
        tester.getSemantics(theX),
        isSemantics(label: 'Hide chat bubble', isButton: true, hasTapAction: true),
      );
      // The red number is still read out; the circle is where it was.
      expect(tester.getTopLeft(find.bySemanticsLabel('Chat, 3 unread')), circle);
    });

    hideTest('takes the green dot\'s place; the red number stays', (tester) async {
      dynamic painter() => tester.widget<CustomPaint>(find.descendant(of: wiggle, matching: find.byType(CustomPaint))).painter;
      await tester.pumpWidget(app());
      chat.debugAnswer(online: true);
      await settle(tester);
      expect(painter().online, isTrue);
      await startHideMode(tester);
      expect(painter().online, isFalse);
      chat.debugAnswer(online: true, unread: 3);
      await tester.pump();
      expect(theX, findsOneWidget);
      expect(painter().badge, '3');
      chat.debugAnswer(online: true);
      await tester.pump();
      // Hide mode over: the green dot is back.
      await tester.tapAt(const Offset(100, 100));
      await tester.pump();
      expect(painter().online, isTrue);
    });
  });

  group('what ends hide mode without hiding', () {
    hideTest('a tap anywhere else, and the app still gets it', (tester) async {
      var calls = 0;
      Affiliateo.onChatBubbleHidden(() => calls++);
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      await startHideMode(tester);

      await tester.tapAt(const Offset(100, 100));
      await settle(tester);
      expect(theX, findsNothing);
      expect(bubble, findsOneWidget);
      expect(appTaps, 1);
      expect(calls, 0);
      expect(await remembered(), isNull);
      expect(await Affiliateo.isChatBubbleHiddenByUser(), isFalse);
      expect(rockOf(tester), 0);
    });

    hideTest('a tap on the bubble itself, which then does not open the chat', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      await startHideMode(tester);

      await tester.tap(bubble);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(theX, findsNothing);
      expect(bubble, findsOneWidget);
      expect(chatPage, findsNothing);
      expect(appTaps, 0);
      expect(await remembered(), isNull);

      // The next tap opens it as always.
      await tester.tap(bubble);
      await chatOpens(tester);
    });

    hideTest('five seconds with no tap on the X', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      await startHideMode(tester);

      await tester.pump(const Duration(milliseconds: 4800));
      expect(theX, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(theX, findsNothing);
      expect(bubble, findsOneWidget);
      expect(rockOf(tester), 0);
      expect(await remembered(), isNull);
    });

    hideTest('the bubble going away: the chat switched off, the app at the back, visible: false', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);

      await startHideMode(tester);
      chat.debugAnswer(showBubble: false);
      await settle(tester);
      expect(bubble, findsNothing);
      chat.debugAnswer();
      await settle(tester);
      expect(bubble, findsOneWidget);
      expect(theX, findsNothing);

      await startHideMode(tester);
      chat.debugActive(false);
      await settle(tester);
      expect(theX, findsNothing);
      expect(bubble, findsOneWidget);
      chat.debugActive(true);
      await settle(tester);

      await startHideMode(tester);
      await tester.pumpWidget(app(visible: false));
      await settle(tester);
      expect(bubble, findsNothing);
      await tester.pumpWidget(app());
      await settle(tester);
      expect(bubble, findsOneWidget);
      expect(theX, findsNothing);
      expect(await remembered(), isNull);
    });
  });

  group('remembered on the phone', () {
    hideTest('a placed bubble shows nothing, until restoreChatBubble()', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{hiddenKey: true});
      chat.debugConfigured(env());
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      expect(bubble, findsNothing);
      expect(await Affiliateo.isChatBubbleHiddenByUser(), isTrue);
      expect(logs.where((l) => l == 'chat: the person hid the chat bubble; restoreChatBubble() brings it back').length, 1);
      // More redraws say it no more often.
      chat.debugAnswer(unread: 2);
      await settle(tester);
      expect(logs.where((l) => l.contains('restoreChatBubble() brings it back')).length, 1);

      Affiliateo.restoreChatBubble();
      await settle(tester);
      expect(find.bySemanticsLabel('Chat, 2 unread'), findsOneWidget);
      expect(await remembered(), isNull);
      expect(await Affiliateo.isChatBubbleHiddenByUser(), isFalse);
    }, configured: false);

    hideTest('restoreChatBubble() before configure() is done once it is', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{hiddenKey: true});
      Affiliateo.restoreChatBubble();
      expect(await Affiliateo.isChatBubbleHiddenByUser(), isFalse);
      chat.debugConfigured(env());
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      expect(bubble, findsOneWidget);
      expect(await remembered(), isNull);
    }, configured: false);

    hideTest('isChatBubbleHiddenByUser is false before configure()', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{hiddenKey: true});
      expect(await Affiliateo.isChatBubbleHiddenByUser(), isFalse);
      chat.debugConfigured(env());
      expect(await Affiliateo.isChatBubbleHiddenByUser(), isTrue);
    }, configured: false);
  });

  group('the rock', () {
    hideTest('the whole bubble rocks 2.5 degrees each way, 130 ms a swing, ease-in-out', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      expect(rockOf(tester), 0);
      final gesture = await holdBubble(tester);
      // The first frame of the rock is level; then a half swing to the right.
      expect(rockOf(tester), 0);
      final angles = <double>[];
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 65));
        angles.add(rockOf(tester));
      }
      expect(angles[0], closeTo(2.5, 0.05));
      expect(angles[1], closeTo(0, 0.05));
      expect(angles[2], closeTo(-2.5, 0.05));
      expect(angles[3], closeTo(0, 0.05));
      // Eased: a quarter of a swing past level it is most of the way out.
      await tester.pump(const Duration(microseconds: 32500));
      expect(rockOf(tester), closeTo(jiggleAngle(Curves.easeInOut.transform(0.75)), 0.05));
      expect(rockOf(tester), greaterThan(1.8));
      // Never past 2.5, and around the circle's own center, which stays put
      // while its corners move.
      final center = tester.getCenter(bubble);
      final corner = tester.getTopLeft(bubble);
      var cornerMoved = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 7));
        expect(rockOf(tester).abs(), lessThanOrEqualTo(2.5 + 1e-9));
        expect(tester.getCenter(bubble), offsetMoreOrLessEquals(center, epsilon: 1e-6));
        if ((tester.getTopLeft(bubble) - corner).distance > 0.5) cornerMoved = true;
      }
      expect(cornerMoved, isTrue);
      await gesture.up();
      await tester.tapAt(const Offset(100, 100));
      await tester.pump();
      expect(rockOf(tester), 0);
    });

    hideTest('no rock with Remove animations or Reduce Motion, but the X shows', (tester) async {
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      for (final features in const [
        FakeAccessibilityFeatures(disableAnimations: true),
        FakeAccessibilityFeatures(reduceMotion: true),
      ]) {
        tester.platformDispatcher.accessibilityFeaturesTestValue = features;
        await tester.pump();
        await startHideMode(tester);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          expect(rockOf(tester), 0);
        }
        expect(theX, findsOneWidget);
        await tester.tapAt(const Offset(100, 100));
        await tester.pump();
      }
    });

    hideTest('the attention wiggle rests in hide mode, and one under way is cut', (tester) async {
      await tester.pumpWidget(app());
      chat.debugAnswer(bubble: const ChatBubbleConfig(wiggleSeconds: 3));
      await settle(tester);
      // The hold starts half a second before the wiggle is due.
      await tester.pump(const Duration(milliseconds: 2500));
      final gesture = await tester.startGesture(tester.getCenter(bubble));
      // The wiggle starts at 3 s (its first frame is at rest) and is under way at 3.2 s.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(turnOf(tester).$1, isNot(0));
      // 3.5 s: the hold is done, mid-wiggle.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(theX, findsOneWidget);
      expect(turnOf(tester), (0.0, 1.0));
      await gesture.up();
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(turnOf(tester), (0.0, 1.0));
      }
      // Hide mode over: a full wait, then it wiggles again.
      await tester.pump(const Duration(milliseconds: 600));
      expect(theX, findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 100));
      expect(turnOf(tester).$1, isNot(0));
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('screen readers', () {
    hideTest('the bubble has a "Hide chat bubble" action that hides it at once', (tester) async {
      var calls = 0;
      Affiliateo.onChatBubbleHidden(() => calls++);
      await tester.pumpWidget(app());
      chat.debugAnswer();
      await settle(tester);
      const action = CustomSemanticsAction(label: 'Hide chat bubble');
      expect(
        tester.getSemantics(bubble),
        isSemantics(label: 'Chat', isButton: true, customActions: const [action]),
      );

      tester.semantics.customAction(find.semantics.byLabel('Chat'), action);
      await settle(tester);
      expect(bubble, findsNothing);
      expect(theX, findsNothing);
      expect(calls, 1);
      expect(await remembered(), isTrue);
    });
  });
}
