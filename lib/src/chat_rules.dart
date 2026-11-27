import 'dart:convert';
import 'dart:math';

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
    this.wiggleSeconds = 0,
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

  /// Seconds between two wiggles of the bubble (4.17.0); 0 is no wiggle.
  final int wiggleSeconds;

  ChatBubbleConfig copyWith({
    AffiliateoChatCorner? corner,
    double? size,
    double? sizePhone,
    String? color,
    String? iconColor,
    AffiliateoChatBubbleStyle? style,
    int? wiggleSeconds,
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
      wiggleSeconds: wiggleSeconds ?? this.wiggleSeconds,
    );
  }
}

// ── The wiggle (4.17.0): the website's rules, lib/live-chat/bubble-options.ts ──
//
// One wiggle (version 2): the whole bubble, with its red number and green
// dot, turns around its own center through three left-right swings that die
// down, growing a touch on the way, and ends exactly at rest. A curve, drawn
// on every frame from the two formulas below, never a few turns with jumps in
// between (that looked glitchy).

/// The shortest wait between two wiggles; a smaller number counts as this.
const int minWiggleSeconds = 3;

/// The longest wait read from a config or from code (a day).
const int maxWiggleSeconds = 86400;

/// How long one wiggle lasts.
const Duration wiggleDuration = Duration(milliseconds: 900);

/// The widest the turn could ever be, in degrees (the first swing reaches about 14).
const double wiggleMaxDegrees = 16;

/// How many full left-right swings one wiggle makes.
const int wiggleSwings = 3;

/// How much the bubble grows at the middle of the wiggle (0.06 is 6%).
const double wiggleGrow = 0.06;

/// How fast the swings die down.
const double wiggleDecay = 1.2;

/// The turn in degrees at progress [p] (0 to 1):
/// 16 * sin(6 * PI * p) * (1 - p)^1.2, and 0 at both ends and outside them.
double wiggleAngle(double p) {
  if (!(p > 0) || p >= 1) return 0;
  return wiggleMaxDegrees * sin(2 * wiggleSwings * pi * p) * pow(1 - p, wiggleDecay);
}

/// The size at progress [p] (0 to 1): 1 + 0.06 * sin(PI * p), and 1 at both
/// ends and outside them.
double wiggleScale(double p) {
  if (!(p > 0) || p >= 1) return 1;
  return 1 + wiggleGrow * sin(pi * p);
}

/// `bubble.wiggle_seconds` of the config: whole seconds, at least
/// [minWiggleSeconds]; 0 (no wiggle) for a config without the field (an older
/// server) or with anything that is not a number above zero.
int readWiggleSeconds(Object? value) {
  if (value is! num || !value.isFinite || value <= 0) return 0;
  return min(maxWiggleSeconds, max(minWiggleSeconds, value.floor()));
}

/// What the app's own code asks for (`AffiliateoChat(wiggleSeconds: ...)`):
/// whole seconds, at least [minWiggleSeconds]; 0 or less is off; null is "not
/// set" (the dashboard decides).
int? wiggleOverride(int? seconds) => seconds == null ? null : readWiggleSeconds(seconds);

/// Whether the bubble may wiggle right now: it is on screen, the chat is
/// closed, the app is in front, nobody is dragging it, the phone does not ask
/// for less motion, it is not in hide mode (4.19.0), and there is a wait to
/// count.
bool mayWiggle({
  required int seconds,
  required bool visible,
  required bool chatOpen,
  required bool appActive,
  required bool dragging,
  required bool reduceMotion,
  bool hideMode = false,
}) =>
    seconds > 0 && visible && !chatOpen && appActive && !dragging && !reduceMotion && !hideMode;

// ── Hold to hide (4.19.0): the same rules in every SDK that draws the bubble ──
//
// A finger kept still on the bubble for a second starts hide mode: the bubble
// rocks like the Affiliateo app's revenue cards in edit mode and a red X
// shows on its top-left. A tap on the X hides the bubble and remembers it on
// this phone; a touch anywhere else, or five seconds, ends hide mode.

/// How long a finger stays still on the bubble before hide mode starts.
const Duration holdToHideDuration = Duration(milliseconds: 1000);

/// How long hide mode lasts with no tap on the X.
const Duration hideModeDuration = Duration(milliseconds: 5000);

/// How far the bubble rocks each way in hide mode, in degrees.
const double jiggleDegrees = 2.5;

/// One swing of the rock, from one side to the other (ease-in-out).
const Duration jiggleSwingDuration = Duration(milliseconds: 130);

/// The turn in degrees for one swing's eased progress [t] (0 to 1): from
/// -[jiggleDegrees] at 0, through level at 0.5, to +[jiggleDegrees] at 1.
/// Anything outside 0 to 1 counts as the nearer end; not a number is level.
double jiggleAngle(double t) {
  if (t.isNaN) return 0;
  return -jiggleDegrees + 2 * jiggleDegrees * t.clamp(0.0, 1.0);
}

/// The X's rounded square, in points: its side and corner radius.
const double hideXSize = 18;
const double hideXRadius = 6;

/// Where the X's square starts, from the circle's top-left corner, in points
/// (both ways): a little over the circle's edge.
const double hideXOffset = -3;

/// The X's touch target, in points (both ways), around its square.
const double hideXTarget = 36;

/// The X's fill: the red of the unread number.
const int hideXColor = 0xFFEF4444;

/// The white cross inside the X: each stroke's length and width, in points.
const double hideXCrossLength = 8;
const double hideXCrossWidth = 2;

/// Where the phone remembers that the person hid the bubble, next to the
/// bubble's dragged place (Flutter's SharedPreferences).
String chatHiddenKey(String appId) => 'affiliateo_chat_hidden_$appId';

/// Whether the bubble stays away because the person hid it: while the hide
/// is [remembered], and also while the SDK is [configured] but has not yet
/// [read] the phone's note (no bubble that shows for a moment and goes).
bool bubbleHiddenByUser({required bool remembered, required bool read, required bool configured}) =>
    remembered || (configured && !read);

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
    wiggleSeconds: readWiggleSeconds(b['wiggle_seconds']),
  );
}

/// What /api/live-chat/config answered, from a read or the app channel.
class ChatConfig {
  const ChatConfig({
    this.enabled = false,
    this.showBubble = false,
    this.online = false,
    this.bubble = const ChatBubbleConfig(),
    this.name,
    this.logoUrl,
    this.greeting,
    this.greetings = const <String, String>{},
  });

  static const ChatConfig off = ChatConfig();

  /// The business has the chat on for this app.
  final bool enabled;

  /// The bubble should show (on, and not hidden by "only while someone is online").
  final bool showBubble;

  /// Someone on the business's team is online right now.
  final bool online;

  /// The owner's corner, size, screens and colors for the bubble.
  final ChatBubbleConfig bubble;

  /// Whose chat it is, for the banner (4.17.0): the Live Chat app's name, the
  /// business's when the app has none.
  final String? name;

  /// The business logo, an https address or nothing.
  final String? logoUrl;

  /// The owner's greeting, as the chat window shows it first.
  final String? greeting;

  /// The greeting in the other languages the owner wrote one in, by
  /// two-letter language.
  final Map<String, String> greetings;
}

/// One short text of the config: trimmed, null when it is not text or empty.
String? _configText(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

/// The first two letters of a language tag ("pt-BR", "zh_Hans"), lowercase.
String _languageCode(String? language) {
  final tag = (language == null || language.isEmpty ? 'en' : language).toLowerCase();
  return tag.length > 2 ? tag.substring(0, 2) : tag;
}

/// The config answer, read the same way wherever it comes from (a GET of
/// /api/live-chat/config or a frame on the app channel): anything but
/// `enabled: true` is off.
ChatConfig readChatConfig(Object? json) {
  if (json is! Map || json['enabled'] != true) return ChatConfig.off;
  final app = json['app'];
  final business = json['business'];
  final logo = business is Map ? _configText(business['logo_url']) : null;
  final versions = json['greetings'];
  final greetings = <String, String>{};
  if (versions is Map) {
    for (final entry in versions.entries) {
      final key = entry.key;
      final text = _configText(entry.value);
      if (key is String && key.isNotEmpty && text != null) greetings[_languageCode(key)] = text;
    }
  }
  return ChatConfig(
    enabled: true,
    showBubble: json['show_bubble'] == true,
    online: json['online'] == true,
    bubble: readBubbleConfig(json['bubble']),
    name: (app is Map ? _configText(app['name']) : null) ?? (business is Map ? _configText(business['name']) : null),
    // Only an https picture is drawn.
    logoUrl: logo != null && RegExp(r'^https://', caseSensitive: false).hasMatch(logo) ? logo : null,
    greeting: _configText(json['greeting']),
    greetings: greetings,
  );
}

/// The app's own live channel, for everyone with the bubble on screen: a
/// change of the owner's on/off switch or of a teammate's Online switch
/// arrives on it at once as a `config` frame. It needs no key.
String appChannelUrl(String apiBase, String appId) =>
    '${_base(apiBase).replaceFirst(RegExp('^http'), 'ws')}/api/live-chat/app-stream?app=${Uri.encodeComponent(appId)}';

/// A `config` frame from the app channel, its `config` read with
/// [readChatConfig]; null for any other frame ("pong" included).
ChatConfig? readAppFrame(Object? data) {
  if (data is! String) return null;
  final Object? frame;
  try {
    frame = jsonDecode(data);
  } catch (_) {
    return null;
  }
  if (frame is! Map || frame['kind'] != 'live_chat' || frame['event'] != 'config') return null;
  final config = frame['config'];
  return config is Map ? readChatConfig(config) : null;
}

/// Whether the app channel should be open: a bubble is placed, the app is in
/// front, the chat is on, and the server has not refused it since the last
/// config read.
bool appChannelWanted({required bool bubblePlaced, required bool active, required bool enabled, required bool refused}) =>
    bubblePlaced && active && enabled && !refused;

/// A refusal of the app channel (no such app, or its chat is off): it is not
/// tried again until a config read says the chat is on. A full server (429)
/// or a timeout (408) is tried again later.
bool refusesAppChannel(int? status) => status != null && status >= 400 && status < 500 && status != 408 && status != 429;

/// The HTTP status a failed upgrade names ("..., HTTP status code: 404", as
/// newer Dart versions say it); null when it names none.
int? upgradeStatus(String error) {
  final match = RegExp(r'HTTP status code: (\d{3})').firstMatch(error);
  return match == null ? null : int.parse(match.group(1)!);
}

/// The wait before try number [tries] (1 and up) to reach the app channel
/// again: 2 s doubling up to 60 s, plus up to a quarter more ([jitter] 0 to
/// 1), so phones do not all come back at once.
Duration appChannelDelay(int tries, double jitter) {
  final base = min(60000, 2000 << (tries.clamp(1, 7) - 1));
  return Duration(milliseconds: base + (base * 0.25 * jitter.clamp(0.0, 1.0)).round());
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
    this.wiggleSeconds,
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

  /// Seconds between two wiggles (4.17.0): 3 or more; 0 for none; null, the
  /// dashboard's.
  final int? wiggleSeconds;

  @override
  bool operator ==(Object other) =>
      other is ChatLook &&
      other.color == color &&
      other.iconColor == iconColor &&
      other.sendColor == sendColor &&
      other.placeholder == placeholder &&
      other.style == style &&
      other.corner == corner &&
      other.size == size &&
      other.wiggleSeconds == wiggleSeconds;

  @override
  int get hashCode => Object.hash(color, iconColor, sendColor, placeholder, style, corner, size, wiggleSeconds);
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
    wiggleSeconds: wiggleOverride(look.wiggleSeconds),
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
/// speaks, English for any other: the chat, closing it, the unread count
/// ({n}), and hiding the bubble (4.19.0: the X and the screen reader's
/// action). The same words as chat.js and the other SDKs.
const Map<String, List<String>> _chatWords = {
  'en': ['Chat', 'Close chat', 'Chat, {n} unread', 'Hide chat bubble'],
  'ar': ['الدردشة', 'إغلاق الدردشة', 'الدردشة، {n} غير مقروءة', 'إخفاء فقاعة الدردشة'],
  'de': ['Chat', 'Chat schließen', 'Chat, {n} ungelesen', 'Chat-Blase ausblenden'],
  'es': ['Chat', 'Cerrar chat', 'Chat, {n} sin leer', 'Ocultar burbuja de chat'],
  'fr': ['Chat', 'Fermer le chat', 'Chat, {n} non lus', 'Masquer la bulle de chat'],
  'hi': ['चैट', 'चैट बंद करें', 'चैट, {n} अपठित', 'चैट बबल छिपाएँ'],
  'it': ['Chat', 'Chiudi chat', 'Chat, {n} non letti', 'Nascondi la bolla della chat'],
  'ja': ['チャット', 'チャットを閉じる', 'チャット、未読 {n} 件', 'チャットバブルを非表示'],
  'ko': ['채팅', '채팅 닫기', '채팅, 읽지 않음 {n}개', '채팅 버블 숨기기'],
  'nl': ['Chat', 'Chat sluiten', 'Chat, {n} ongelezen', 'Chatbubbel verbergen'],
  'pl': ['Czat', 'Zamknij czat', 'Czat, nieprzeczytane: {n}', 'Ukryj dymek czatu'],
  'pt': ['Chat', 'Fechar chat', 'Chat, {n} não lidas', 'Ocultar balão do chat'],
  'ru': ['Чат', 'Закрыть чат', 'Чат, непрочитанных: {n}', 'Скрыть значок чата'],
  'tr': ['Sohbet', 'Sohbeti kapat', 'Sohbet, {n} okunmamış', 'Sohbet balonunu gizle'],
  'vi': ['Trò chuyện', 'Đóng trò chuyện', 'Trò chuyện, {n} chưa đọc', 'Ẩn bong bóng trò chuyện'],
  'zh': ['聊天', '关闭聊天', '聊天，{n} 条未读', '隐藏聊天气泡'],
};

/// The bubble's words for a language tag ("pt-BR", "zh_Hans"): its first two
/// letters, English when unknown.
List<String> chatWords(String language) {
  final tag = (language.isEmpty ? 'en' : language).toLowerCase();
  return _chatWords[tag.length >= 2 ? tag.substring(0, 2) : tag] ?? _chatWords['en']!;
}

/// The words for hiding the bubble (4.19.0), the X's label and the screen
/// reader's action, for a language tag: the same lookup as [chatWords].
String hideBubbleWords(String language) => chatWords(language)[3];

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

// ── Notifications (4.17.0) ───────────────────────────────────────────────
// A reply from the team reaches the phone as a push. The app's own push
// plugin asks for the token and the phone draws the notification; the SDK
// registers the phone with Affiliateo and says which notifications are the
// chat's. The website's lib/live-chat/visitor-push.ts sends them.

/// A push token as the server takes it: an iPhone's is Apple's device token
/// in hex (lowercased here; spaces and the < > of an old description are
/// dropped), an Android phone's is Firebase's registration token exactly as
/// given. Null for anything else, a Firebase token on an iPhone included:
/// Affiliateo sends an iPhone's through Apple.
String? chatPushToken(Object? token, String platform) {
  if (token is! String) return null;
  if (platform == 'ios') {
    final hex = token.replaceAll(RegExp(r'[\s<>]'), '').toLowerCase();
    return RegExp(r'^[0-9a-f]{32,512}$').hasMatch(hex) ? hex : null;
  }
  final fcm = token.trim();
  return RegExp(r'^[A-Za-z0-9:_-]{32,2048}$').hasMatch(fcm) ? fcm : null;
}

/// The body of POST /api/live-chat/push-devices, or null when it would be
/// refused anyway: no usable token, no device id (the reply is matched to
/// the phone by it), or an iPhone with no bundle id (Apple needs it to
/// deliver).
///
/// display "system": this SDK cannot draw a system notification, so the
/// phone draws it itself while the app is closed or in the background
/// (Android's push then carries a notification block; the iPhone's is an
/// alert anyway). With the app open, the SDK's own banner shows it.
Map<String, String>? chatPushBody({
  required String appId,
  required String platform,
  required String token,
  required String? deviceId,
  String? bundleId,
  String? environment,
  String? visitorId,
  String? userId,
  String? language,
}) {
  if (platform != 'ios' && platform != 'android') return null;
  final pushToken = chatPushToken(token, platform);
  final device = (deviceId ?? '').trim();
  final bundle = (bundleId ?? '').trim();
  if (appId.isEmpty || pushToken == null || device.isEmpty) return null;
  if (platform == 'ios' && bundle.isEmpty) return null;
  return <String, String>{
    'app': appId,
    'platform': platform,
    'token': pushToken,
    'device_id': device,
    'language': language == null || language.isEmpty ? 'en' : language,
    'display': 'system',
    if (bundle.isNotEmpty) 'bundle_id': bundle,
    if (platform == 'ios') 'environment': environment == 'sandbox' ? 'sandbox' : 'production',
    if (visitorId != null && visitorId.isNotEmpty) 'visitor_id': visitorId,
    if (userId != null && userId.isNotEmpty) 'user_id': userId,
  };
}

/// What became of a request to /api/live-chat/push-devices.
enum ChatPushAnswer {
  /// `200 { "ok": true }`: stored (or forgotten).
  ok,

  /// `200 { "ok": false }`: an app the server does not know, one whose chat
  /// is off, or something it cannot use. Nothing is stored.
  notTaken,

  /// Any other answer (429, 5xx, a server from before the route): left until
  /// the next launch.
  failed,

  /// No answer at all (offline, a time out): tried again later.
  noAnswer,
}

/// Reads the server's answer: [status] null is no answer at all.
ChatPushAnswer chatPushAnswer(int? status, String? body) {
  if (status == null) return ChatPushAnswer.noAnswer;
  if (status != 200) return ChatPushAnswer.failed;
  Object? json;
  try {
    json = jsonDecode(body ?? '');
  } catch (_) {
    json = null;
  }
  return json is Map && json['ok'] == true ? ChatPushAnswer.ok : ChatPushAnswer.notTaken;
}

/// A request that got no answer (the phone was offline) is not sent again
/// sooner than this.
const Duration chatPushRetryAfter = Duration(minutes: 5);

/// The token the server last confirmed for this phone, kept so a sign-out or
/// an opt-out knows which one the server is to forget.
String chatPushKey(String appId) => 'affiliateo_chat_push_$appId';

/// A token the server has yet to forget (a sign-out or opt-out made offline).
String chatPushForgetKey(String appId) => 'affiliateo_chat_push_forget_$appId';

/// Set by a sign-out: the phone is not registered again until the next
/// person has a thread of their own.
String chatPushHeldKey(String appId) => 'affiliateo_chat_push_held_$appId';

/// The chat's part of a notification: the conversation and the message it is
/// about (and, on Android, the title and text the phone drew).
class ChatNotificationData {
  const ChatNotificationData({this.app, this.conversationId, this.messageId, this.title, this.body});

  final String? app;
  final String? conversationId;
  final String? messageId;
  final String? title;
  final String? body;

  @override
  bool operator ==(Object other) =>
      other is ChatNotificationData &&
      other.app == app &&
      other.conversationId == conversationId &&
      other.messageId == messageId &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(app, conversationId, messageId, title, body);

  @override
  String toString() =>
      'ChatNotificationData(app: $app, conversationId: $conversationId, messageId: $messageId, title: $title, body: $body)';
}

/// The chat's part of a notification, or null when the notification is not a
/// chat reply. [data] is what the app's push plugin hands over as the
/// notification's data: Apple's payload carries an `affiliateo_chat` object,
/// Firebase's data an `affiliateo_chat: "1"`. The whole message works too
/// (its `data` is read).
ChatNotificationData? chatNotificationData(Object? data) {
  String? text(Object? value) => value is String && value.isNotEmpty ? value : null;
  ChatNotificationData? read(Object? node) {
    if (node is! Map) return null;
    Object? mark = node['affiliateo_chat'];
    // Some plugins hand a nested object over as its JSON text.
    if (mark is String && mark.trim().startsWith('{')) {
      try {
        mark = jsonDecode(mark);
      } catch (_) {
        // A plain mark.
      }
    }
    if (mark == null || mark == false || mark == '' || mark == '0') return null;
    final from = mark is Map ? mark : node;
    return ChatNotificationData(
      app: text(from['app']),
      conversationId: text(from['conversation_id']),
      messageId: text(from['message_id']),
      title: text(node['title']),
      body: text(node['body']),
    );
  }

  return read(data) ?? read(data is Map ? data['data'] : null);
}

/// Whether a notification is a Live Chat reply from Affiliateo.
bool isChatNotification(Object? data) => chatNotificationData(data) != null;

// ── The in-app banner (4.17.0) ───────────────────────────────────────────
// With the app open, a reply (and the greeting, once) shows as a banner the
// SDK draws itself at the top of the screen: a card with the business logo,
// the Live Chat app's name and the message. Flutter has no way of its own to
// post a system notification, and this needs no plugin.

/// How long the banner stays before it slides away.
const Duration chatBannerStay = Duration(seconds: 5);

/// The most characters of a message the banner (and a notification) carries.
const int chatBannerBodyMax = 180;

/// The body for a message with no text, in the 16 languages Affiliateo
/// speaks: the website's words for the same push.
const Map<String, String> _sentYouAMessage = {
  'en': 'Sent you a message',
  'es': 'Te envió un mensaje',
  'fr': 'Vous a envoyé un message',
  'pt': 'Enviou uma mensagem para você',
  'de': 'Hat dir eine Nachricht gesendet',
  'ja': 'メッセージが届きました',
  'it': 'Ti ha inviato un messaggio',
  'nl': 'Heeft je een bericht gestuurd',
  'ko': '메시지를 보냈습니다',
  'zh': '给你发了一条消息',
  'ru': 'Вам пришло сообщение',
  'ar': 'أرسل لك رسالة',
  'hi': 'आपको एक संदेश भेजा',
  'pl': 'Masz nową wiadomość',
  'tr': 'Size bir mesaj gönderdi',
  'vi': 'Đã gửi cho bạn một tin nhắn',
};

/// The words of a banner: the message on one line (runs of spaces and line
/// breaks become one space), cut to [chatBannerBodyMax] characters with an
/// ellipsis when longer, never through the middle of an emoji. A message
/// with no text says "Sent you a message" in the phone's language. The same
/// rule as the website's push (lib/live-chat/visitor-push.ts).
String chatBannerText(Object? text, String? language) {
  final line = (text is String ? text : '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (line.isEmpty) return _sentYouAMessage[_languageCode(language)] ?? _sentYouAMessage['en']!;
  final characters = line.runes.toList();
  if (characters.length <= chatBannerBodyMax) return line;
  return '${String.fromCharCodes(characters.take(chatBannerBodyMax - 1)).trimRight()}…';
}

/// The greeting as the chat window would show it to this phone: the version
/// in the phone's language when the owner wrote one, else the main greeting,
/// else nothing.
String? chatGreetingText(ChatConfig? config, String? language) {
  if (config == null) return null;
  return config.greetings[_languageCode(language)] ?? config.greeting;
}

/// What a banner is about.
enum ChatBannerKind { reply, greeting }

/// One banner: what it is about and what it says.
class ChatBanner {
  const ChatBanner({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.logoUrl,
    this.greetingId,
  });

  /// The message's id, or the greeting's: a newer banner with another id
  /// replaces the one on screen.
  final String id;
  final ChatBannerKind kind;

  /// The Live Chat app's name; "Chat" in the phone's language when the config
  /// names none.
  final String title;
  final String body;

  /// The business logo; null draws the bubble's chat icon.
  final String? logoUrl;

  /// Set on the greeting's banner: which greeting it was, to remember it.
  final String? greetingId;

  @override
  bool operator ==(Object other) =>
      other is ChatBanner &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.body == body &&
      other.logoUrl == logoUrl &&
      other.greetingId == greetingId;

  @override
  int get hashCode => Object.hash(id, kind, title, body, logoUrl, greetingId);

  @override
  String toString() => 'ChatBanner($id, $kind, $title, $body, logo: $logoUrl, greeting: $greetingId)';
}

/// What every banner needs to hold before it may show: a place to draw it
/// ([enabled]: an AffiliateoChat is placed with `inAppBanner` on), the chat
/// closed (its own window shows the message), the app in front, the chat on.
bool _bannerMayShow({
  required ChatConfig? config,
  required bool enabled,
  required bool chatOpen,
  required bool appActive,
}) =>
    enabled && !chatOpen && appActive && config != null && config.enabled;

/// The banner for a frame from the thread's socket (the decoded JSON): a
/// message the team wrote, while the app is in front and the chat is closed.
/// Null for anything else (the person's own message, a read receipt, "Chat
/// closed" lines, a frame that is not the chat's).
ChatBanner? replyBanner(
  Object? frame, {
  required ChatConfig? config,
  required bool enabled,
  required bool chatOpen,
  required bool appActive,
  required String language,
}) {
  if (!_bannerMayShow(config: config, enabled: enabled, chatOpen: chatOpen, appActive: appActive)) return null;
  if (frame is! Map || frame['kind'] != 'live_chat' || frame['event'] != 'message') return null;
  final message = frame['message'];
  if (message is! Map || message['sender'] != 'team') return null;
  final id = message['id'];
  return ChatBanner(
    id: id is String && id.isNotEmpty ? id : 'reply',
    kind: ChatBannerKind.reply,
    title: config!.name ?? chatWords(language)[0],
    body: chatBannerText(message['body'], language),
    logoUrl: config.logoUrl,
  );
}

/// The greeting as a banner, ONCE: after the app said notifications are
/// allowed (chatNotificationsAllowed), while the greeting is still pending
/// (the rule behind the red 1: the config has a greeting id, nobody on this
/// phone opened the chat since, and there is no thread yet) and this greeting
/// was not shown this way before ([notifiedId] is what the phone remembers).
/// Its `greetingId` says which greeting it was, so the caller can remember it.
ChatBanner? greetingBanner({
  required ChatConfig? config,
  required bool enabled,
  required bool chatOpen,
  required bool appActive,
  required String language,
  required bool allowed,
  required bool greetingPending,
  required String? notifiedId,
}) {
  if (!allowed || !greetingPending) return null;
  if (!_bannerMayShow(config: config, enabled: enabled, chatOpen: chatOpen, appActive: appActive)) return null;
  final greetingId = config!.bubble.greetingId;
  if (greetingId == null || greetingId == notifiedId) return null;
  final text = chatGreetingText(config, language);
  if (text == null) return null;
  return ChatBanner(
    id: 'greeting-$greetingId',
    kind: ChatBannerKind.greeting,
    title: config.name ?? chatWords(language)[0],
    body: chatBannerText(text, language),
    logoUrl: config.logoUrl,
    greetingId: greetingId,
  );
}

/// The greeting a phone already showed as a banner (its id), so it shows once.
String chatGreetingNotifiedKey(String appId) => 'affiliateo_chat_greeting_notified_$appId';
