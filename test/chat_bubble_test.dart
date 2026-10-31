import 'dart:async';

import 'package:affiliateo/affiliateo.dart';
import 'package:affiliateo/src/chat.dart';
import 'package:affiliateo/src/chat_rules.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app({Widget Function(Widget child)? wrap}) => WidgetsApp(
      color: const Color(0xFF000000),
      builder: (context, _) => (wrap ?? (child) => AffiliateoChat(child: child))(const SizedBox.expand()),
    );

void main() {
  final chat = LiveChat.instance;

  testWidgets('nothing shows until the server says the chat is on', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(app());
    expect(find.bySemanticsLabel('Chat'), findsNothing);

    chat.debugAnswer(enabled: false);
    await tester.pump();
    expect(find.bySemanticsLabel('Chat'), findsNothing);

    chat.debugAnswer(showBubble: false);
    await tester.pump();
    expect(find.bySemanticsLabel('Chat'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the bubble shows, says its unread count, and follows the page rules', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(app());
    chat.debugAnswer(online: true);
    await tester.pump();
    expect(find.bySemanticsLabel('Chat'), findsOneWidget);
    expect(Affiliateo.chatState.value.online, isTrue);

    chat.debugAnswer(unread: 12, bubble: const ChatBubbleConfig(style: AffiliateoChatBubbleStyle.glass));
    await tester.pump();
    expect(find.bySemanticsLabel('Chat, 12 unread'), findsOneWidget);
    expect(Affiliateo.chatState.value.unread, 12);

    chat.debugAnswer(bubble: const ChatBubbleConfig(pageMode: ChatPageMode.only, pageRules: ['home']));
    chat.screen.value = 'settings';
    await tester.pump();
    expect(find.bySemanticsLabel('Chat'), findsNothing);
    chat.screen.value = 'Home';
    await tester.pump();
    expect(find.bySemanticsLabel('Chat'), findsOneWidget);
    chat.screen.value = null;
    semantics.dispose();
  });

  testWidgets('visible: false hides it; the app\'s own look draws', (tester) async {
    final semantics = tester.ensureSemantics();
    chat.debugAnswer();
    await tester.pumpWidget(app(wrap: (child) => AffiliateoChat(visible: false, child: child)));
    expect(find.bySemanticsLabel('Chat'), findsNothing);

    await tester.pumpWidget(app(
      wrap: (child) => AffiliateoChat(
        color: const Color(0xFF7C3AED),
        iconColor: const Color(0xFF000000),
        bubbleStyle: AffiliateoChatBubbleStyle.solid,
        corner: AffiliateoChatCorner.topLeft,
        size: 44,
        child: child,
      ),
    ));
    final bubble = find.bySemanticsLabel('Chat');
    expect(bubble, findsOneWidget);
    expect(tester.getSize(bubble), const Size(44, 44));
    // Top left: 20 points in from the top and left edges.
    expect(tester.getTopLeft(bubble), const Offset(20, 20));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('the app channel: off takes the bubble away, a new config applies at once', (tester) async {
    final semantics = tester.ensureSemantics();
    chat.debugAnswer();
    await tester.pumpWidget(app());
    expect(find.bySemanticsLabel('Chat'), findsOneWidget);

    chat.debugAppFrame('{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":false,"show_bubble":false}}');
    await tester.pump();
    expect(find.bySemanticsLabel('Chat'), findsNothing);
    expect(Affiliateo.chatState.value.enabled, isFalse);

    // Anything else on the channel changes nothing.
    chat.debugAppFrame('pong');
    await tester.pump();
    expect(find.bySemanticsLabel('Chat'), findsNothing);

    chat.debugAppFrame('{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":true,"show_bubble":true,'
        '"online":true,"bubble":{"position":"top-left","size_points":44}}}');
    await tester.pump();
    final bubble = find.bySemanticsLabel('Chat');
    expect(bubble, findsOneWidget);
    expect(tester.getSize(bubble), const Size(44, 44));
    expect(tester.getTopLeft(bubble), const Offset(20, 20));
    expect(Affiliateo.chatState.value.online, isTrue);
    semantics.dispose();
  });

  group('the app\'s own sheets and pop-ups cover it', () {
    PageRoute<T> page<T>(RouteSettings settings, WidgetBuilder builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, __) => builder(context),
        );

    Widget withNavigator(Widget home) => WidgetsApp(
          color: const Color(0xFF000000),
          pageRouteBuilder: page,
          home: home,
          builder: (context, child) => AffiliateoChat(child: child!),
        );

    Future<void> openDialog(BuildContext context, {bool root = true}) => showGeneralDialog<void>(
          context: context,
          useRootNavigator: root,
          transitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (context, _, __) => const SizedBox(width: 100, height: 100),
        );

    testWidgets('a dialog or sheet hides it until it has slid away', (tester) async {
      final semantics = tester.ensureSemantics();
      chat.debugAnswer();
      late BuildContext home;
      await tester.pumpWidget(withNavigator(Builder(builder: (context) {
        home = context;
        return const SizedBox.expand();
      })));
      await tester.pump();
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);

      unawaited(openDialog(home));
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('Chat'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Chat'), findsNothing);

      Navigator.of(home).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Still sliding away: still covered.
      expect(find.bySemanticsLabel('Chat'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a full-screen pop-up covers it, a plain page does not', (tester) async {
      final semantics = tester.ensureSemantics();
      chat.debugAnswer();
      late BuildContext home;
      await tester.pumpWidget(withNavigator(Builder(builder: (context) {
        home = context;
        return const SizedBox.expand();
      })));
      unawaited(Navigator.of(home).push(PageRouteBuilder<void>(pageBuilder: (_, __, ___) => const SizedBox.expand())));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);
      Navigator.of(home).pop();
      await tester.pumpAndSettle();

      unawaited(Navigator.of(home).push(PageRouteBuilder<void>(
        fullscreenDialog: true,
        pageBuilder: (_, __, ___) => const SizedBox.expand(),
      )));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Chat'), findsNothing);
      Navigator.of(home).pop();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a sheet on a tab\'s own navigator covers it too', (tester) async {
      final semantics = tester.ensureSemantics();
      chat.debugAnswer();
      late BuildContext tab;
      await tester.pumpWidget(withNavigator(Navigator(
        onGenerateRoute: (settings) => page<void>(settings, (context) {
          tab = context;
          return const SizedBox.expand();
        }),
      )));
      await tester.pump();
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);

      unawaited(openDialog(tab, root: false));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Chat'), findsNothing);
      Navigator.of(tab).pop();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Chat'), findsOneWidget);
      semantics.dispose();
    });
  });
}
