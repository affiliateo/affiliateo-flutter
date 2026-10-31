import 'package:affiliateo/src/chat_rules.dart';
import 'package:flutter_test/flutter_test.dart';

const api = 'https://affiliateo.com';
const app = 'app_123';
final token = 'lct_${'a' * 43}';

void main() {
  group('readBubbleConfig', () {
    test('reads the owner\'s choices', () {
      final b = readBubbleConfig({
        'position': 'top-left',
        'size_points': 64,
        'size_points_phone': 48,
        'page_mode': 'only',
        'page_rules': ['home', 3, 'settings/*'],
        'greeting_id': 'g1',
        'color': '#7C3AED',
        'icon_color': '#000000',
        'style': 'glass',
      });
      expect(b.corner, AffiliateoChatCorner.topLeft);
      expect(b.size, 64);
      expect(b.sizePhone, 48);
      expect(b.pageMode, ChatPageMode.only);
      expect(b.pageRules, ['home', 'settings/*']);
      expect(b.greetingId, 'g1');
      expect(b.color, '#7C3AED');
      expect(b.iconColor, '#000000');
      expect(b.style, AffiliateoChatBubbleStyle.glass);
    });

    test('anything missing or odd is the old fixed bubble', () {
      final b = readBubbleConfig({'position': 'middle', 'size_points': 200, 'color': 'red', 'greeting_id': ''});
      expect(b.corner, AffiliateoChatCorner.bottomRight);
      expect(b.size, 56);
      expect(b.sizePhone, 56);
      expect(b.pageMode, ChatPageMode.all);
      expect(b.greetingId, isNull);
      expect(b.color, ChatBubbleConfig.defaultColor);
      expect(readBubbleConfig(null).style, AffiliateoChatBubbleStyle.solid);
    });

    test('the phone size follows the tablet size when missing', () {
      expect(readBubbleConfig({'size_points': 72}).sizePhone, 72);
    });
  });

  group('look', () {
    test('hexColor reads the ways code writes a color', () {
      expect(hexColor('#7C3AED'), '#7c3aed');
      expect(hexColor('7c3aed'), '#7c3aed');
      expect(hexColor('#fa0'), '#ffaa00');
      expect(hexColor('blue'), isNull);
      expect(hexColor(null), isNull);
    });

    test('the app\'s choices win, and its size is kept between 40 and 80', () {
      final b = applyChatLook(
        const ChatBubbleConfig(size: 64, sizePhone: 48),
        const ChatLook(color: '#ff0000', size: 100, corner: AffiliateoChatCorner.topRight),
      );
      expect(b.color, '#ff0000');
      expect(b.iconColor, ChatBubbleConfig.defaultIconColor);
      expect(b.size, 80);
      expect(b.sizePhone, 80);
      expect(b.corner, AffiliateoChatCorner.topRight);
    });

    test('nothing set keeps the dashboard\'s choice', () {
      final b = applyChatLook(const ChatBubbleConfig(size: 64, sizePhone: 48), const ChatLook());
      expect(b.size, 64);
      expect(b.sizePhone, 48);
    });
  });

  group('page rules', () {
    test('match without case, trailing slash, with * and /*', () {
      expect(pageRuleMatches('Home', 'home/'), isTrue);
      expect(pageRuleMatches('settings/*', 'settings'), isTrue);
      expect(pageRuleMatches('settings/*', 'settings/profile'), isTrue);
      expect(pageRuleMatches('*checkout*', 'cart_checkout_step'), isTrue);
      expect(pageRuleMatches('a.b', 'axb'), isFalse);
      expect(pageRuleMatches('', 'home'), isFalse);
    });

    test('an unknown screen shows nothing under only, the bubble under except', () {
      expect(bubbleShowsOn(ChatPageMode.all, const [], null), isTrue);
      expect(bubbleShowsOn(ChatPageMode.only, const ['home'], null), isFalse);
      expect(bubbleShowsOn(ChatPageMode.except, const ['home'], null), isTrue);
      expect(bubbleShowsOn(ChatPageMode.only, const ['home'], 'home'), isTrue);
      expect(bubbleShowsOn(ChatPageMode.except, const ['home'], 'home'), isFalse);
    });
  });

  test('badge numbers scale with the circle, as on the website', () {
    final m = BadgeMetrics(56);
    expect([m.pillHeight, m.pillFont, m.pillPadding, m.pillOffset, m.dot, m.dotOffset, m.border], [20, 11, 5, 4, 16, 2, 2]);
    expect(BadgeMetrics(40).border, 1.5);
    expect(badgeText(0), isNull);
    expect(badgeText(3), '3');
    expect(badgeText(12), '9+');
  });

  group('chatPageUrl', () {
    test('everything in the fragment, links=post always', () {
      final url = chatPageUrl(
        apiBase: '$api/',
        appId: app,
        android: true,
        language: 'pt-BR',
        optedOut: false,
        deviceId: 'dev 1',
        visitorId: 'v1',
        userId: 'u@1',
        token: token,
        sendColor: '#F00',
        placeholder: '  Ask   us anything  ',
      );
      expect(
        url,
        '$api/embed/chat/$app?lang=pt-BR#p=android&close=1&sheet=1&d=dev%201&v=v1&u=u%401&t=$token'
        '&sc=%23ff0000&ph=Ask%20us%20anything&links=post',
      );
    });

    test('no token asks for a fresh thread; opted out leaves the ids out', () {
      final url = chatPageUrl(
        apiBase: api,
        appId: app,
        android: false,
        language: 'en',
        optedOut: true,
        deviceId: 'd',
        visitorId: 'v',
        userId: 'u',
      );
      expect(url, '$api/embed/chat/$app?lang=en#p=ios&close=1&sheet=1&fresh=1&links=post');
    });

    test('the placeholder is cut at 60 characters', () {
      final url = chatPageUrl(apiBase: api, appId: app, android: false, language: 'en', optedOut: true, placeholder: 'x' * 80);
      expect(url, contains('ph=${'x' * 60}&'));
    });
  });

  test('chatWords: first two letters, English otherwise', () {
    expect(chatWords('de-AT')[1], 'Chat schließen');
    expect(chatWords('xx')[0], 'Chat');
    expect(chatWords('')[0], 'Chat');
  });

  group('what the chat sheet loads (review S18)', () {
    bool page(String url) => chatLoads(url, isMainFrame: true, apiBase: api, appId: app);
    bool frame(String url) => chatLoads(url, isMainFrame: false, apiBase: api, appId: app);

    test('the page loads only this app\'s own chat page', () {
      expect(page('$api/embed/chat/$app?lang=en#t=x'), isTrue);
      expect(page('$api/embed/chat/$app/'), isTrue);
      expect(page('https://AFFILIATEO.com:443/embed/chat/$app'), isTrue);
      expect(page('about:blank'), isTrue);
      expect(page('$api/embed/chat/other_app'), isFalse);
      expect(page('$api/embed/chat/$app/more'), isFalse);
      expect(page('$api/dashboard'), isFalse);
      expect(page('https://evil.com/embed/chat/$app'), isFalse);
      expect(page('http://affiliateo.com/embed/chat/$app'), isFalse);
      expect(page('https://affiliateo.com@evil.com/embed/chat/$app'), isFalse);
      expect(page('https://affiliateo.com\\@evil.com/embed/chat/$app'), isFalse);
      expect(page('https://affiliateo.com:8443/embed/chat/$app'), isFalse);
    });

    test('nothing leaves the sheet by navigating, not even a web link', () {
      expect(page('https://example.com/pricing'), isFalse);
      expect(page('mailto:a@b.co'), isFalse);
      expect(page('intent://x#Intent;end'), isFalse);
      expect(page('javascript:alert(1)'), isFalse);
    });

    test('a frame loads only from the chat\'s origin or Cloudflare\'s check', () {
      expect(frame('$api/anything'), isTrue);
      expect(frame('about:srcdoc'), isTrue);
      expect(frame('https://challenges.cloudflare.com/cdn-cgi/x'), isTrue);
      expect(frame('https://evil.com/'), isFalse);
      expect(frame('https://challenges.cloudflare.com.evil.com/'), isFalse);
    });

    test('an encoded app id matches once decoded, a broken escape never', () {
      expect(chatLoads('$api/embed/chat/a%20b', isMainFrame: true, apiBase: api, appId: 'a b'), isTrue);
      expect(chatLoads('$api/embed/chat/%E0%A4%A', isMainFrame: true, apiBase: api, appId: app), isFalse);
    });
  });

  group('messages from the page', () {
    test('a token, read, close and a tapped web link', () {
      expect((parseHostMessage('{"type":"affiliateo:chat-token","token":"$token"}') as ChatTokenMessage).token, token);
      expect(parseHostMessage('{"type":"affiliateo:chat-read"}'), isA<ChatReadMessage>());
      expect(parseHostMessage('{"type":"affiliateo:chat-close"}'), isA<ChatCloseMessage>());
      expect(
        (parseHostMessage('{"type":"affiliateo:chat-link","url":"https://example.com/a?b=1"}') as ChatLinkMessage).url,
        'https://example.com/a?b=1',
      );
    });

    test('anything else does nothing', () {
      expect(parseHostMessage('{"type":"affiliateo:chat-token","token":"nope"}'), isNull);
      expect(parseHostMessage('{"type":"affiliateo:chat-link","url":"javascript:alert(1)"}'), isNull);
      expect(parseHostMessage('{"type":"affiliateo:chat-link","url":"https://a.com/ b"}'), isNull);
      expect(parseHostMessage('{"type":"affiliateo:chat-link","url":"https://user@a.com/"}'), isNull);
      expect(parseHostMessage('{"type":"affiliateo:chat-link","url":"https://a.com/${'x' * 2100}"}'), isNull);
      expect(parseHostMessage('{"type":"affiliateo:chat-ready"}'), isNull);
      expect(parseHostMessage('not json'), isNull);
      expect(parseHostMessage('[1]'), isNull);
    });
  });

  group('the keyed bridge (review S18)', () {
    const key = '0123456789abcdef0123456789abcdef';

    test('the script works only on the chat\'s origin and empties the page\'s storage', () {
      final script = chatBridgeScript(key, '$api/')!;
      expect(script, contains("if(location.origin!=='https\\u003a\\u002f\\u002faffiliateo\\u002ecom')return;"));
      expect(script, contains("var k='$key',b=window.__affiliateoChatNative"));
      expect(script, contains('window.AffiliateoChatBridge={postMessage:function(m){b.postMessage(k+String(m))}}'));
      expect(script, contains('localStorage.clear()'));
    });

    test('the key must be hex', () {
      expect(() => chatBridgeScript("x'", api), throwsArgumentError);
      expect(() => chatBridgeScript('', api), throwsArgumentError);
      expect(chatBridgeScript(key, 'not a url'), isNull);
    });

    test('only a message with the key counts', () {
      expect(unkeyedMessage('$key{"type":"x"}', key), '{"type":"x"}');
      expect(unkeyedMessage('{"type":"x"}', key), isNull);
      expect(unkeyedMessage('${'f' * 32}{"type":"x"}', key), isNull);
      expect(unkeyedMessage('short', key), isNull);
    });
  });

  test('isChatToken', () {
    expect(isChatToken(token), isTrue);
    expect(isChatToken('lct_short'), isFalse);
    expect(isChatToken(null), isFalse);
  });

  group('the app channel', () {
    const onFrame = '{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":true,"show_bubble":true,'
        '"online":true,"bubble":{"position":"top-left","size_points":64,"size_points_phone":48,"page_mode":"only",'
        '"page_rules":["Home"],"greeting_id":"g2","style":"glass","color":"#7c3aed","icon_color":"#000000"}}}';
    const offFrame = '{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":false,"show_bubble":false}}';

    test('its address names the app and carries no key', () {
      expect(appChannelUrl('$api/', 'my app&1'), 'wss://affiliateo.com/api/live-chat/app-stream?app=my%20app%261');
      expect(appChannelUrl('http://localhost:3000', 'a1'), 'ws://localhost:3000/api/live-chat/app-stream?app=a1');
    });

    test('a config frame reads as a fresh config read', () {
      final config = readAppFrame(onFrame)!;
      expect(config.enabled, isTrue);
      expect(config.showBubble, isTrue);
      expect(config.online, isTrue);
      expect(config.bubble.corner, AffiliateoChatCorner.topLeft);
      expect(config.bubble.size, 64);
      expect(config.bubble.sizePhone, 48);
      expect(config.bubble.pageMode, ChatPageMode.only);
      expect(config.bubble.pageRules, ['Home']);
      expect(config.bubble.greetingId, 'g2');
      expect(config.bubble.style, AffiliateoChatBubbleStyle.glass);
      expect(config.bubble.color, '#7c3aed');
      // The same reader as the GET.
      final read = readChatConfig({'enabled': true, 'show_bubble': false, 'online': false});
      expect([read.enabled, read.showBubble, read.online], [true, false, false]);
    });

    test('off is off, as a GET would read it', () {
      final off = readAppFrame(offFrame)!;
      expect([off.enabled, off.showBubble, off.online], [false, false, false]);
      expect(readChatConfig({'enabled': false, 'show_bubble': true}).showBubble, isFalse);
      expect(readChatConfig(null).enabled, isFalse);
      expect(readAppFrame('{"kind":"live_chat","event":"config","config":{}}')!.enabled, isFalse);
    });

    test('other frames are not config', () {
      expect(readAppFrame('pong'), isNull);
      expect(readAppFrame('not json'), isNull);
      expect(readAppFrame(null), isNull);
      expect(readAppFrame('{"kind":"live_chat","event":"message","config":{"enabled":true}}'), isNull);
      expect(readAppFrame('{"kind":"message","event":"config","config":{"enabled":true}}'), isNull);
      expect(readAppFrame('{"kind":"live_chat","event":"config","config":true}'), isNull);
    });

    test('when it is open', () {
      expect(appChannelWanted(bubblePlaced: true, active: true, enabled: true, refused: false), isTrue);
      expect(appChannelWanted(bubblePlaced: false, active: true, enabled: true, refused: false), isFalse);
      expect(appChannelWanted(bubblePlaced: true, active: false, enabled: true, refused: false), isFalse);
      expect(appChannelWanted(bubblePlaced: true, active: true, enabled: false, refused: false), isFalse);
      expect(appChannelWanted(bubblePlaced: true, active: true, enabled: true, refused: true), isFalse);
    });

    test('a refusal waits for the next config read', () {
      expect(refusesAppChannel(404), isTrue);
      expect(refusesAppChannel(403), isTrue);
      expect(refusesAppChannel(429), isFalse);
      expect(refusesAppChannel(408), isFalse);
      expect(refusesAppChannel(503), isFalse);
      expect(refusesAppChannel(null), isFalse);
      expect(upgradeStatus("WebSocketException: Connection to 'x' was not upgraded to websocket, HTTP status code: 404"), 404);
      expect(upgradeStatus("WebSocketException: Connection to 'x' was not upgraded to websocket"), isNull);
    });

    test('backoff doubles from 2 s to a minute, plus jitter', () {
      expect([for (var i = 1; i <= 8; i++) appChannelDelay(i, 0).inMilliseconds], [2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000]);
      expect(appChannelDelay(1, 1).inMilliseconds, 2500);
      expect(appChannelDelay(9, 1).inMilliseconds, 75000);
      expect(appChannelDelay(0, 0).inMilliseconds, 2000);
    });
  });
}
