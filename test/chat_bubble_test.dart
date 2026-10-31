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
}
