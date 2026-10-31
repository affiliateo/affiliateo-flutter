import 'dart:convert';

// Live Chat's rules that need no screen (4.15.4), the same as the Swift,
// Kotlin and React Native SDKs' ChatRules and the website's
// lib/live-chat/bubble-options.ts: KEEP THEM IN STEP. Plain Dart, so the
// tests run them without a phone.

/// The corner the bubble starts in.
enum AffiliateoChatCorner { bottomRight, bottomLeft, topRight, topLeft }

/// The bubble's look: a solid circle, or see-through glass.
enum AffiliateoChatBubbleStyle { solid, glass }

/// Which screens the bubble shows on: all of them, only the listed ones, or
/// all but the listed ones (matched against the name passed to
/// `Affiliateo.page`).
enum ChatPageMode { all, only, except }

/// What /api/live-chat/config says about the bubble.
class ChatBubbleConfig {
  const ChatBubbleConfig({
    this.corner = AffiliateoChatCorner.bottomRight,
    this.size = 56,
    this.sizePhone = 56,
    this.pageMode = ChatPageMode.all,
    this.pageRules = const <String>[],
    this.greetingId,
    this.color = defaultColor,
    this.iconColor = defaultIconColor,
    this.style = AffiliateoChatBubbleStyle.solid,
  });

  static const String defaultColor = '#1754d8';
  static const String defaultIconColor = '#ffffff';

  final AffiliateoChatCorner corner;

  /// The circle on a tablet, in points.
  final double size;

  /// The circle on a phone (smaller than [size] for the owner's "auto").
  final double sizePhone;
  final ChatPageMode pageMode;
  final List<String> pageRules;

  /// Set when the greeting counts as one unread message until the chat is opened.
  final String? greetingId;

  /// The owner's circle and icon colors, as #rrggbb.
  final String color;
  final String iconColor;
  final AffiliateoChatBubbleStyle style;

  ChatBubbleConfig copyWith({
    AffiliateoChatCorner? corner,
    double? size,
    double? sizePhone,
    String? color,
    String? iconColor,
    AffiliateoChatBubbleStyle? style,
  }) {
    return ChatBubbleConfig(
      corner: corner ?? this.corner,
      size: size ?? this.size,
      sizePhone: sizePhone ?? this.sizePhone,
      pageMode: pageMode,
      pageRules: pageRules,
      greetingId: greetingId,
      color: color ?? this.color,
      iconColor: iconColor ?? this.iconColor,
      style: style ?? this.style,
    );
  }
}

final RegExp _hex6 = RegExp(r'^#[0-9a-f]{6}$', caseSensitive: false);

double? _sizeIn(Object? value) {
  if (value is! num) return null;
  final v = value.toDouble();
  return v >= 40 && v <= 80 ? v : null;
}

/// The `bubble` object of the config answer, with anything missing or odd
/// read as the old fixed bubble.
ChatBubbleConfig readBubbleConfig(Object? raw) {
  final b = raw is Map ? raw : const <String, Object?>{};
  final corner = switch (b['position']) {
    'bottom-left' => AffiliateoChatCorner.bottomLeft,
    'top-right' => AffiliateoChatCorner.topRight,
    'top-left' => AffiliateoChatCorner.topLeft,
    _ => AffiliateoChatCorner.bottomRight,
  };
  final size = _sizeIn(b['size_points']) ?? 56;
  final phone = _sizeIn(b['size_points_phone']) ?? size;
  final pageMode = switch (b['page_mode']) {
    'only' => ChatPageMode.only,
    'except' => ChatPageMode.except,
    _ => ChatPageMode.all,
  };
  final rules = b['page_rules'];
  final greeting = b['greeting_id'];
  final color = b['color'];
  final iconColor = b['icon_color'];
  return ChatBubbleConfig(
    corner: corner,
    size: size,
    sizePhone: phone,
    pageMode: pageMode,
    pageRules: rules is List ? rules.whereType<String>().toList() : const <String>[],
    greetingId: greeting is String && greeting.isNotEmpty ? greeting : null,
    color: color is String && _hex6.hasMatch(color) ? color : ChatBubbleConfig.defaultColor,
    iconColor: iconColor is String && _hex6.hasMatch(iconColor) ? iconColor : ChatBubbleConfig.defaultIconColor,
    style: b['style'] == 'glass' ? AffiliateoChatBubbleStyle.glass : AffiliateoChatBubbleStyle.solid,
  );
}

/// What the app's own code asks for (the AffiliateoChat widget's settings);
/// each one set wins over the dashboard's choice.
class ChatLook {
  const ChatLook({
    this.color,
    this.iconColor,
    this.sendColor,
    this.placeholder,
    this.style,
    this.corner,
    this.size,
  });

  /// Colors as #rrggbb.
  final String? color;
  final String? iconColor;

  /// The chat's send button and the person's own messages.
  final String? sendColor;

  /// The message box text, in the app's own words and language.
  final String? placeholder;
  final AffiliateoChatBubbleStyle? style;
  final AffiliateoChatCorner? corner;

  /// One size for phones and tablets alike, in points.
  final double? size;

  @override
  bool operator ==(Object other) =>
      other is ChatLook &&
      other.color == color &&
      other.iconColor == iconColor &&
      other.sendColor == sendColor &&
      other.placeholder == placeholder &&
      other.style == style &&
      other.corner == corner &&
      other.size == size;

  @override
  int get hashCode => Object.hash(color, iconColor, sendColor, placeholder, style, corner, size);
}

/// A color as code may write it ("#7C3AED", "7c3aed", "#fa0") as #rrggbb,
/// lowercase; null for anything else.
String? hexColor(String? value) {
  if (value == null) return null;
  var v = value.trim().toLowerCase();
  if (v.startsWith('#')) v = v.substring(1);
  if (RegExp(r'^[0-9a-f]{6}$').hasMatch(v)) return '#$v';
  if (RegExp(r'^[0-9a-f]{3}$').hasMatch(v)) return '#${v[0]}${v[0]}${v[1]}${v[1]}${v[2]}${v[2]}';
  return null;
}

/// The dashboard's bubble with the app's own choices on top.
ChatBubbleConfig applyChatLook(ChatBubbleConfig bubble, ChatLook look) {
  final size = look.size == null ? null : look.size!.clamp(40, 80).toDouble();
  return bubble.copyWith(
    color: hexColor(look.color),
    iconColor: hexColor(look.iconColor),
    style: look.style,
    corner: look.corner,
    size: size,
    sizePhone: size,
  );
}

/// A path or name compared without case and without a trailing slash ("/" stays).
String _comparable(String value) {
  final v = value.trim().toLowerCase();
  return v.length > 1 && v.endsWith('/') ? v.substring(0, v.length - 1) : v;
}

/// Whether one rule matches the current screen (the name the app passed to
/// `Affiliateo.page`). `*` matches any run of characters; a rule ending in
/// "/*" also matches the part in front of it.
bool pageRuleMatches(String rule, String place) {
  final r = _comparable(rule);
  if (r.isEmpty) return false;
  final p = _comparable(place);
  if (r.endsWith('/*')) {
    final front = r.substring(0, r.length - 2);
    if (_comparable(front.isEmpty ? '/' : front) == p) return true;
  }
  final pattern = r.split('*').map(RegExp.escape).join('.*');
  return RegExp('^$pattern\$').hasMatch(p);
}

/// Whether the bubble shows on this screen. An unknown screen (null) shows
/// nothing under "only" and the bubble under "except".
bool bubbleShowsOn(ChatPageMode mode, List<String> rules, String? place) {
  if (mode == ChatPageMode.all) return true;
  final hit = place != null && rules.any((rule) => pageRuleMatches(rule, place));
  return mode == ChatPageMode.only ? hit : !hit;
}

/// The red number and the green dot for a circle of [size] points, scaled
/// from the 56-point bubble's (the website's badgeMetrics; the same numbers).
class BadgeMetrics {
  BadgeMetrics(double size)
      : pillHeight = (20 * size / 56).roundToDouble(),
        pillFont = (11 * size / 56 * 2).round() / 2,
        pillPadding = (5 * size / 56).roundToDouble(),
        pillOffset = (4 * size / 56).roundToDouble(),
        dot = (16 * size / 56).roundToDouble(),
        dotOffset = (2 * size / 56).roundToDouble(),
        border = size / 56 < 1 ? 1.5 : 2;

  final double pillHeight;
  final double pillFont;
  final double pillPadding;
  final double pillOffset;
  final double dot;
  final double dotOffset;
  final double border;
}

/// The red number on the bubble: up to 9, then "9+"; null for none.
String? badgeText(int unread) {
  if (unread <= 0) return null;
  return unread > 9 ? '9+' : '$unread';
}

/// The API address without a slash at its end.
String _base(String apiBase) => apiBase.replaceFirst(RegExp(r'/+$'), '');

/// The hosted chat page for this app, the address the other SDKs build, with
/// everything it is told in the URL fragment, which never reaches a server
/// log. The ids are labels for the business's inbox, left out while the
/// person has opted out of tracking. The token goes in only when there is
/// one; without one, fresh=1 tells the page to drop a token it kept itself
/// (the last person's, after a sign-out) and start a new thread.
///
/// links=post: Flutter's web view never says whether a navigation was a tap,
/// so the page names each link the person taps in a team message
/// (affiliateo:chat-link) and the SDK opens only those (review S18).
String chatPageUrl({
  required String apiBase,
  required String appId,
  required bool android,
  required String language,
  required bool optedOut,
  String? deviceId,
  String? visitorId,
  String? userId,
  String? token,
  String? sendColor,
  String? placeholder,
}) {
  final frag = <String>['p=${android ? 'android' : 'ios'}', 'close=1', 'sheet=1'];
  void add(String key, String? value) {
    if (value != null && value.isNotEmpty) frag.add('$key=${Uri.encodeComponent(value)}');
  }

  if (!optedOut) {
    add('d', deviceId);
    add('v', visitorId);
    add('u', userId);
  }
  if (token != null && token.isNotEmpty) {
    add('t', token);
  } else {
    frag.add('fresh=1');
  }
  add('sc', hexColor(sendColor));
  final ph = placeholder?.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (ph != null && ph.isNotEmpty) add('ph', ph.length > 60 ? ph.substring(0, 60) : ph);
  frag.add('links=post');
  return '${_base(apiBase)}/embed/chat/${Uri.encodeComponent(appId)}'
      '?lang=${Uri.encodeComponent(language)}#${frag.join('&')}';
}

/// The bubble's spoken words in the person's language, the 16 Affiliateo
/// speaks, English for any other: the chat, closing it, and the unread count
/// ({n}). The same words as chat.js and the other SDKs.
const Map<String, List<String>> _chatWords = {
  'en': ['Chat', 'Close chat', 'Chat, {n} unread'],
  'ar': ['الدردشة', 'إغلاق الدردشة', 'الدردشة، {n} غير مقروءة'],
  'de': ['Chat', 'Chat schließen', 'Chat, {n} ungelesen'],
  'es': ['Chat', 'Cerrar chat', 'Chat, {n} sin leer'],
  'fr': ['Chat', 'Fermer le chat', 'Chat, {n} non lus'],
  'hi': ['चैट', 'चैट बंद करें', 'चैट, {n} अपठित'],
  'it': ['Chat', 'Chiudi chat', 'Chat, {n} non letti'],
  'ja': ['チャット', 'チャットを閉じる', 'チャット、未読 {n} 件'],
  'ko': ['채팅', '채팅 닫기', '채팅, 읽지 않음 {n}개'],
  'nl': ['Chat', 'Chat sluiten', 'Chat, {n} ongelezen'],
  'pl': ['Czat', 'Zamknij czat', 'Czat, nieprzeczytane: {n}'],
  'pt': ['Chat', 'Fechar chat', 'Chat, {n} não lidas'],
  'ru': ['Чат', 'Закрыть чат', 'Чат, непрочитанных: {n}'],
  'tr': ['Sohbet', 'Sohbeti kapat', 'Sohbet, {n} okunmamış'],
  'vi': ['Trò chuyện', 'Đóng trò chuyện', 'Trò chuyện, {n} chưa đọc'],
  'zh': ['聊天', '关闭聊天', '聊天，{n} 条未读'],
};

/// The bubble's words for a language tag ("pt-BR", "zh_Hans"): its first two
/// letters, English when unknown.
List<String> chatWords(String language) {
  final tag = (language.isEmpty ? 'en' : language).toLowerCase();
  return _chatWords[tag.length >= 2 ? tag.substring(0, 2) : tag] ?? _chatWords['en']!;
}

/// Whether a link may go to the browser: web addresses only. Any other scheme
/// (another app's, intent:, file:, javascript:) opens nothing.
bool opensOutside(String url) => RegExp(r'^https?://', caseSensitive: false).hasMatch(url);

/// The origin (scheme://host[:port], lowercase, the default port left out)
/// and path of an http(s) address. Null for any other scheme, and for an
/// address with a user name or a backslash before its path, which browsers
/// and this code could read differently.
({String origin, String path})? _addressParts(String url) {
  final match = RegExp(r'^(https?)://([^/?#]*)([^?#]*)', caseSensitive: false).firstMatch(url);
  if (match == null) return null;
  final scheme = match.group(1)!.toLowerCase();
  final authority = match.group(2)!.toLowerCase();
  final path = match.group(3)!;
  if (authority.isEmpty || RegExp(r'[@\\\s]').hasMatch(authority) || path.contains(r'\')) return null;
  final hostPort = RegExp(r'^([a-z0-9._-]+|\[[0-9a-f:.]+\])(?::(\d{1,5}))?$').firstMatch(authority);
  if (hostPort == null) return null;
  final host = hostPort.group(1)!;
  final port = hostPort.group(2);
  final defaultPort = (scheme == 'https' && port == '443') || (scheme == 'http' && port == '80');
  final origin = port != null && !defaultPort ? '$scheme://$host:$port' : '$scheme://$host';
  return (origin: origin, path: path.isEmpty ? '/' : path);
}

/// The chat's origin (the API address's scheme, host and port), or null.
String? chatOrigin(String apiBase) => _addressParts(_base(apiBase))?.origin;

/// A path with its %-escapes read once; null when one is broken.
String? _decodedPath(String path) {
  try {
    return Uri.decodeComponent(path);
  } catch (_) {
    return null;
  }
}

/// Whether the address is on the chat's origin.
bool isChatOrigin(String url, String apiBase) {
  final api = chatOrigin(apiBase);
  final other = _addressParts(url);
  return api != null && other != null && api == other.origin;
}

/// Whether this is THIS app's own chat page: on the chat's origin, at exactly
/// /embed/chat/{appId}. Another app's chat page is not, so it never loads in
/// the sheet and never hands over a key that would replace this person's.
bool isChatPage(String url, String apiBase, String appId) {
  if (appId.isEmpty || !isChatOrigin(url, apiBase)) return false;
  final expected = _addressParts('${_base(apiBase)}/embed/chat/${Uri.encodeComponent(appId)}');
  final path = _addressParts(url)?.path;
  if (expected == null || path == null) return false;
  final want = _decodedPath(expected.path);
  final got = _decodedPath(path);
  return want != null && (got == want || got == '$want/');
}

/// A web address this code reads the same way the web view does.
bool _webLink(String url) => opensOutside(url) && _addressParts(url) != null;

/// Cloudflare's own challenge frame, which shows only while Cloudflare checks
/// a visitor before serving the chat page.
bool isCloudflareChallenge(String url) =>
    _addressParts(url)?.origin == 'https://challenges.cloudflare.com';

/// Whether the chat sheet loads a navigation (review S18):
/// - the page itself loads only this app's own chat page;
/// - a frame inside it loads only from the chat's origin (and Cloudflare's
///   challenge frame);
/// - nothing else loads, and nothing leaves the sheet this way: Flutter's
///   web view never says whether the person tapped, so links leave only by
///   the page's own message (affiliateo:chat-link, [linkToOpen]).
///
/// A new window (target="_blank", window.open) comes here first as a frame
/// and then, when the web view moves it to the page, as the page.
bool chatLoads(String url, {required bool isMainFrame, required String apiBase, required String appId}) {
  if (!isMainFrame) {
    return url == 'about:blank' ||
        url == 'about:srcdoc' ||
        isChatOrigin(url, apiBase) ||
        isCloudflareChallenge(url);
  }
  return url == 'about:blank' || isChatPage(url, apiBase, appId);
}

/// The longest link the page may name in one message.
const int _linkMax = 2048;

/// The web link in the page's affiliateo:chat-link message, or null for
/// anything else: not a web address, too long, or with spaces in it.
String? linkToOpen(Object? url) {
  if (url is! String || url.length > _linkMax || RegExp(r'\s').hasMatch(url)) return null;
  return _webLink(url) ? url : null;
}

final RegExp _tokenRe = RegExp(r'^lct_[A-Za-z0-9_-]{43}$');

/// True for a string shaped like a key the server minted.
bool isChatToken(Object? value) => value is String && _tokenRe.hasMatch(value);

/// One message from the chat page.
sealed class ChatHostMessage {
  const ChatHostMessage();
}

class ChatTokenMessage extends ChatHostMessage {
  const ChatTokenMessage(this.token);
  final String token;
}

class ChatReadMessage extends ChatHostMessage {
  const ChatReadMessage();
}

class ChatCloseMessage extends ChatHostMessage {
  const ChatCloseMessage();
}

class ChatLinkMessage extends ChatHostMessage {
  const ChatLinkMessage(this.url);
  final String url;
}

/// A message the page sent, a JSON string such as
/// {"type":"affiliateo:chat-token","token":"lct_..."}; null for anything the
/// SDK does not act on.
ChatHostMessage? parseHostMessage(String text) {
  Object? json;
  try {
    json = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (json is! Map) return null;
  switch (json['type']) {
    case 'affiliateo:chat-token':
      final token = json['token'];
      return isChatToken(token) ? ChatTokenMessage(token as String) : null;
    case 'affiliateo:chat-read':
      return const ChatReadMessage();
    case 'affiliateo:chat-close':
      return const ChatCloseMessage();
    case 'affiliateo:chat-link':
      final url = linkToOpen(json['url']);
      return url == null ? null : ChatLinkMessage(url);
  }
  return null;
}

/// The name the page looks for to know an app opened it.
const String chatBridgeName = 'AffiliateoChatBridge';

/// The channel that carries the page's messages, with the key in front.
/// Flutter's web view puts it in every frame, so only a message that starts
/// with the key the SDK gave the chat page's own frame counts.
const String chatKeyedBridgeName = '__affiliateoChatNative';

/// The script that hands the chat page's frame the key (review S18): from
/// then on its window.AffiliateoChatBridge sends every message down the
/// keyed channel with the key in front. Null when the API address has no
/// origin.
String? chatBridgeScript(String key, String apiBase) {
  if (key.isEmpty || !RegExp(r'^[0-9a-f]+$').hasMatch(key)) {
    throw ArgumentError.value(key, 'key', 'the bridge key is hex');
  }
  final origin = chatOrigin(apiBase);
  if (origin == null) return null;
  return '(function(){if(location.origin!==${_jsString(origin)})return;'
      "var k='$key',b=window.$chatKeyedBridgeName;if(!b)return;"
      'window.$chatBridgeName={postMessage:function(m){b.postMessage(k+String(m))}};'
      'try{localStorage.clear()}catch(e){}})();';
}

/// The page's message without the key in front, or null when it does not
/// carry the key (a frame inside the page).
String? unkeyedMessage(String raw, String key) {
  if (key.isEmpty || raw.length < key.length) return null;
  var diff = 0;
  for (var i = 0; i < key.length; i++) {
    diff |= raw.codeUnitAt(i) ^ key.codeUnitAt(i);
  }
  return diff == 0 ? raw.substring(key.length) : null;
}

/// A JavaScript string literal: letters and digits as they are, everything
/// else escaped.
String _jsString(String value) {
  final out = StringBuffer("'");
  for (final c in value.codeUnits) {
    final isPlain = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    out.write(isPlain ? String.fromCharCode(c) : '\\u${c.toRadixString(16).padLeft(4, '0')}');
  }
  out.write("'");
  return out.toString();
}
