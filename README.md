# Affiliateo Flutter SDK

Mobile affiliate attribution, session tracking and Live Chat for Flutter apps (iOS & Android).

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  affiliateo:
    git:
      url: https://github.com/affiliateo/affiliateo-flutter
      ref: 4.18.0
```

Then run `flutter pub get`.

## Usage

Initialize at app startup:

```dart
import 'package:affiliateo/affiliateo.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Affiliateo.configure(appId: 'YOUR_APP_ID');
  runApp(MyApp());
}
```

Access the attribution state anywhere:

```dart
final state = Affiliateo.state;
if (state.isMatched) {
  print('Referred by: ${state.refCode}');
}
```

## Track screens (manual)

Screens are tracked when you call `Affiliateo.page(name)` per screen. This matches the Mixpanel / Amplitude model. predictable, no ghost events polluting funnels.

```dart
class HomeScreen extends StatefulWidget {
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    Affiliateo.page('HomeScreen');
  }

  @override
  Widget build(BuildContext context) => YourScreenUI();
}
```

## Track custom events

For buttons or other moments that matter (signup, trial start, etc.):

```dart
ElevatedButton(
  onPressed: () async {
    await Affiliateo.track('signup_completed');
    onNext();
  },
  child: Text('Continue'),
)
```

## Sign-in and sign-out

Say who is signed in after sign-in (and on launch while someone is), and call
`logout()` on sign-out:

```dart
// after sign-in (email is optional, see Giving affiliates free access)
await Affiliateo.identify(user.id, email: user.email);

// on sign-out
await Affiliateo.logout();
```

The same person then counts as one customer across their devices. After
`logout()` the phone counts as a new anonymous customer, so whoever signs in
next (or nobody) isn't counted as the person who just left; everything already
recorded stays with them. Tracking carries on as before: same device, same
visitor id, same purchase tag, no restart needed. If a different user signs in
without a sign-out in between, the phone switches to them on its own.

The SDK remembers the signed-in id and sends it again once per launch, and an
`identify()` made before `configure()` has finished is kept and sent once it
has. Ids that mean "nobody" (`"null"`, `"guest"`, `"0"`, an empty string,
RevenueCat's `$RCAnonymousID:...`, anything over 128 characters) are skipped,
and nothing is sent while the person has opted out. **No email address is
ever sent:** when you pass `email`, the SDK sends only its SHA-256 (see below),
and nothing else about the person.

### What changed in 4.17.0

- The chat bubble wiggles: one short wiggle every few seconds, set by Wiggle
  in the dashboard's Live Chat settings (off, or every 10 to 60 seconds), by
  `Affiliateo.setChatBubbleWiggle(seconds: 20)` or by
  `AffiliateoChat(wiggleSeconds: 20)`. Never with Reduce Motion on.
- Notifications for replies, with nothing extra to install: the phone shows a
  reply while the app is closed (`Affiliateo.registerChatPushToken(token,
  platform)` hands the SDK the push token, and
  `Affiliateo.handleChatNotification(data)` opens the chat from a tapped
  notification), and `AffiliateoChat` shows its own banner while the app is
  open (`inAppBanner`). `Affiliateo.chatNotificationsAllowed()` brings the
  greeting as a banner once, in the phone's language when you wrote the
  greeting in it. `Affiliateo.isChatNotification(data)` tells you a
  notification is a chat reply. See Notifications under Live Chat.
- Fixed: calling `Affiliateo.page(name)` from a screen's `initState()` while
  the bubble was placed logged "setState() or markNeedsBuild() called during
  build" in debug builds. The bubble now follows the new screen right after
  that frame.
- No new packages, and nothing to change in code you already have.

### What changed in 4.16.2

- Tracking events wait instead of being lost. When the server is busy or out
  of reach, the events stay on the phone and are sent again after 5 seconds,
  then 10, 20 and so on up to about 5 minutes, never sooner than the server
  asks. They used to be dropped after three tries. Only events the server
  refuses are dropped, with one line in the debug log.
- The events still waiting are sent as the app leaves the screen, and a
  request with no answer is given up after 20 seconds. Nothing to change in
  your code.

### What changed in 4.16.1

- Tracking sends less: the events waiting in the queue (screen views,
  `track()` events, session pings) of one flush now go to the server in one
  request instead of one request per event. They still leave on the same
  timer, with no extra wait, and each keeps its own id and time. Purchases
  and ad ids still go one by one, and Live Chat is unchanged.

### What changed in 4.16.0

- Switching Live Chat off in your dashboard, or someone on your team going
  online or offline, reaches the bubble at once while the app is open: off,
  the bubble goes and an open chat closes; otherwise the new look, corner,
  size, screens, greeting and green dot apply right away. The SDK keeps a
  small live channel open for it while a bubble is placed and the app is in
  front.

### What changed in 4.15.5

- Sheets, dialogs and full-screen pop-ups your app opens cover the chat
  bubble, as in the other SDKs. It used to float over them.

### What changed in 4.15.4

The Flutter SDK catches up with the Swift, Kotlin and React Native SDKs
(the numbers 4.13 to 4.15.3 were never used here):

- **Live Chat** (see Live Chat below): the `AffiliateoChat` bubble,
  `Affiliateo.openChat(context)`, `chatAvailable()` and `chatState`.
- **Store prices** (see Store prices below): `configure(storePrices: ...)`.
- New dependencies: `webview_flutter`, `flutter_secure_storage` and
  `url_launcher`. Their newest versions need iOS 13+ and Android API 24+.

### What changed in 4.12.0

- `identify(userId, email: ...)` takes the signed-in person's email, for free
  access. Only its SHA-256 leaves the phone.
- New `Affiliateo.freeAccess()`, so apps that sell without RevenueCat can give
  affiliates free access (see Giving affiliates free access).
- New dependency: `crypto`, the Dart team's package, for the hash.

### What changed in 4.11.0

- New `logout()`, for sign-out (see above).
- `reset()` is now the same as `logout()`. It used to try to give the phone a
  new device id, which iOS and Android don't allow, and left the purchase tag
  null until the app restarted.
- `identify()` stores the id, re-sends it once per launch, keeps a call made
  before `configure()` finished (it used to be dropped), retries a sign-in
  that raced ahead of the first launch call, and skips placeholder ids.
- A different user signing in on the same phone now switches it to them. It
  used to be refused, so a shared phone stayed its first user forever.

## Tag every purchase

The SDK gives every phone a purchase tag (its Affiliateo visitor id):
`Affiliateo.state.appAccountToken` on iPhone, `Affiliateo.state.obfuscatedAccountId`
on Android. Every user gets one, whether or not they came through an affiliate,
so always pass it to the purchase call. The store stamps it onto the sale and on
every renewal and refund after it, and Affiliateo ties each one to this phone,
and to the affiliate when there is one.

```dart
import 'dart:io';
import 'package:in_app_purchase/in_app_purchase.dart';

final state = Affiliateo.state;
final param = PurchaseParam(
  productDetails: productDetails,
  applicationUserName:
      Platform.isIOS ? state.appAccountToken : state.obfuscatedAccountId,
);
await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
```

It is null only until the SDK's first identify succeeds. Signing out keeps it.

## Affiliate codes (4.18.0)

A coupon code without the coupon. The buyer types an affiliate's code in a box your app shows, and that affiliate gets the sale. There is no discount, the store is not involved, and nothing is matched by IP address for that buyer.

The code is the one each affiliate already has: the end of their link. Turn on **Affiliate codes** for the app in Affiliateo once your app has the box.

```dart
final result = await Affiliateo.setAffiliateCode(codeController.text);

if (result.matched) {
  // Say "Code applied". result.refCode is the affiliate's code.
} else {
  // Say "Code not found". result.reason says why:
  // notFound, invalid, off, notReady or failed.
}

// Then buy as you already do, with Affiliateo.state.appAccountToken
// (iOS) or Affiliateo.state.obfuscatedAccountId (Android).
```

- A typed code beats a link match and is never overwritten by one.
- A later code replaces an earlier one, so a typo can be fixed before buying.
- It never throws, and it waits up to 10 seconds for `configure()`.
- Apps on RevenueCat: set the `affiliateo_ref` attribute again after a match, from `Affiliateo.state.refCode` (see RevenueCat Integration below).

To credit by code only, turn off **Match installs to link clicks** for the app in Affiliateo. Then no install is matched to a link click by IP address.

## What it does

- **Identifies the device** using IDFV (iOS) or Android ID (no permissions needed)
- **Tracks sessions** automatically (app foreground)
- **Matches affiliate referrals** via fingerprint matching
- **IAP attribution** via Apple `appAccountToken` and Google `obfuscatedAccountId`, for every user (see Tag every purchase)

## Giving affiliates free access

App owners can switch free access on for an individual affiliate from the
Affiliates table in their Affiliateo dashboard, choosing a plan and, if they
like, an end date. Apps on RevenueCat: see Giving affiliates free access on
RevenueCat below instead.

### Apps on StoreKit, Google Play Billing, Adapty or Stripe (4.12.0)

Apple and Google have no way for anyone but the person to start a
subscription, so your app asks Affiliateo instead and unlocks itself:

```dart
// after sign-in: pass the email the person signed in with
await Affiliateo.identify(user.id, email: user.email);

// wherever you decide what is unlocked (launch, paywall)
final access = await Affiliateo.freeAccess();
if (access.active) unlockPaidFeatures(access.productId); // null means full access
```

- `active`: unlock when true.
- `productId`: the store product id of the plan the owner chose. `null` means
  full access.
- `expiresAt`: when the free access ends (UTC). `null` means no end date.

The affiliate is recognised by email: the address the owner typed when
switching it on, or else the one the affiliate uses on Affiliateo. **The
address never leaves the phone.** The SDK sends only its SHA-256 (trimmed and
lowercased first), and Affiliateo compares it with the same hash of the
owner's address.

`freeAccess()` never throws. It waits (up to 10 seconds) for `configure()` and
the sign-in to reach Affiliateo first, so calling it right after `identify`
works. Each answer is saved on the phone: when Affiliateo can't be reached,
the saved one is used while its end date is still ahead and it is at most 7
days old, otherwise the answer is no access. `logout()`, or a different user
signing in, forgets it.

## RevenueCat Integration

If you use RevenueCat, add the attributes manually after configure.
`affiliateo_visitor_id` should be set for EVERY user (matched or organic):
it links each purchase back to the tracked visitor, powering per-buyer spend,
funnel journeys, and ad ROAS in your dashboard. `affiliateo_ref` only exists
for affiliate-referred installs:

```dart
import 'package:purchases_flutter/purchases_flutter.dart';

final state = Affiliateo.state;
final attributes = <String, String>{
  if (state.visitorId != null) "affiliateo_visitor_id": state.visitorId!,
  if (state.refCode != null) "affiliateo_ref": state.refCode!,
};
if (attributes.isNotEmpty) {
  await Purchases.setAttributes(attributes);
}
```

### Giving affiliates free access on RevenueCat

App owners can switch free access on for an individual affiliate from their
Affiliateo dashboard, which grants a promotional entitlement in their own
RevenueCat project. To make that possible, tell Affiliateo which RevenueCat
customer this device is:

```dart
// after Purchases.configure(...)
await Affiliateo.setRevenueCatUser(await Purchases.appUserID);
```

**This line is required on Flutter.** The Swift, Kotlin, React Native and
WebView SDKs read the id by themselves as of 4.7.0, but Dart has no way to look
for a package that might not be installed, so on Flutter it stays an explicit
call.

Call it after RevenueCat has configured, and again after `Purchases.logIn()` if
your app has sign-in: RevenueCat issues an anonymous placeholder until then, and
the server accepts exactly one upgrade from that placeholder to the real id.
Sending the same id repeatedly is a no-op.

An affiliate also has to have opened your app through their own referral link at
least once, because that link is what tells us which device is theirs. Until
then the owner sees a disabled switch reading "hasn't opened your app yet".

Notes:

- Separate from `identify()` on purpose. Sign-in and RevenueCat setup happen at
  different moments, and your app may do one without the other.
- Write-once per device. Sending a different ID for a device that is already
  bound is rejected, so a tampered client cannot repoint a device at another
  customer.
- No email or other PII is sent.

## Report purchases to your ad networks

When you run app campaigns on Meta, TikTok or Snapchat through Affiliateo,
Affiliateo tells those networks each time somebody FIRST pays (a
subscription's first charge, or a one-time purchase), so the campaigns learn
who pays rather than who installs. Set it up in Affiliateo: your ad network's
settings, **Send app sales**, then paste the network's id for your app.

There are two ways a payment reaches Affiliateo, and you can use either or
both. Affiliateo sends each payment once.

1. **Your payment provider (nothing to add here).** If RevenueCat, Apple
   In-App Purchase, Google Play or Adapty is connected to your app in
   Affiliateo, first payments are reported on their own.
2. **One line on your paywall.** Right after a purchase succeeds:

```dart
import 'package:purchases_flutter/purchases_flutter.dart';

final result = await Purchases.purchase(PurchaseParams.package(package));
Affiliateo.purchase(
  transactionId: result.storeTransaction.transactionIdentifier,
  productId: result.storeTransaction.productIdentifier,
  price: package.storeProduct.price,
  currency: package.storeProduct.currencyCode,
);
```

`transactionId` is the store's id for the payment (the App Store transaction
id, Google Play's order id), which RevenueCat's `transactionIdentifier` is on
both. Pass `kind: PurchaseKind.oneTime` for a one-time purchase.

The paywall line is quicker and carries the phone's network address, which
the networks match on. It records no sale and moves no money: revenue and
commissions still come only from your payment provider.

**Advertising ids.** The SDK never shows the "Allow tracking?" prompt, and
Dart can't reach the plugins that read the answer, so pass it in if your app
asks (with `app_tracking_transparency`, for example). The advertising id then
goes with Allow, and Apple's vendor id once the answer is known and isn't a
no:

```dart
final status = await AppTrackingTransparency.trackingAuthorizationStatus;
await Affiliateo.setAdIdentifiers(
  trackingAllowed: status == TrackingStatus.authorized
      ? true
      : status == TrackingStatus.notDetermined ? null : false,
  advertisingId: await AppTrackingTransparency.getAdvertisingIdentifier(),
);
```

Pass `trackingAllowed: null` if your app never asks: the prompt isn't
needed. On iPhone, a purchase from someone who didn't tap Allow still goes,
marked as not allowed to track and without Apple's device ids, and each network
uses it only in its limited, privacy-safe way. On Android, pass
whether ads personalisation is on and the Google advertising id, and add the
`com.google.android.gms.permission.AD_ID` permission to your manifest.

**Installs come from the network's own SDK.** Affiliateo sends payments, not
installs. To run app campaigns on Meta, TikTok or Snapchat, add that network's
SDK (or a measurement partner like AppsFlyer) for installs, and keep **Send app
sales** on for payments.

**Send each network your sales one way only.** Keep that SDK's installs but turn
its purchase reporting off, or leave **Send app sales** off for that network.
Otherwise the network counts every sale twice: it only matches two reports of
one sale when both carry the same id, and its own SDK doesn't send the store's
transaction id. Affiliateo's own two ways are matched on it and go out once.

- **Meta:** in your app on Meta for Developers, under Settings > Basic, set the
  switch that logs in-app purchases automatically to No on the iOS and Android
  cards. Leave the SDK's automatic logging on (`FacebookAutoLogAppEventsEnabled`
  on iOS, `com.facebook.sdk.AutoLogAppEventsEnabled` on Android): turning it off
  stops installs too.
- **TikTok:** on iPhone, call `disablePaymentTracking()` on its `TikTokConfig`; on
  Android, don't call `enableAutoIapTrack()` or `trackGooglePlayPurchase()`.
- **Snapchat:** don't send purchases from its SDK.
- **A measurement partner** (AppsFlyer, Adjust, Branch, Singular, Kochava) that
  forwards purchases to the network counts too: stop forwarding them, or leave
  **Send app sales** off for that network.

## Live Chat

Your app's users chat in real time with your team, who answer from the Live
Chat inbox in your Affiliateo dashboard. Switch it on for the app there, then
place the bubble once, around your app's navigator:

```dart
MaterialApp(
  builder: (context, child) => AffiliateoChat(child: child!),
  home: const HomeScreen(),
)
```

Tap the bubble to open the chat; press and move it to drag it, and it
remembers where it was left. It shows the red unread number, and a green dot
while someone on your team is online. Switching the chat off in your
dashboard, or someone on your team going online or offline, reaches it at once
while the app is open. Nothing shows until you place
`AffiliateoChat` or call `openChat()` (an app should not grow a feature its
store reviewer never saw), nor while the chat is off for the app in your
dashboard.

**Your own button** instead of the bubble (or beside it):

```dart
if (await Affiliateo.chatAvailable()) {
  // show the button
}

ValueListenableBuilder<AffiliateoChatState>(
  valueListenable: Affiliateo.chatState,
  builder: (context, chat, _) => TextButton(
    onPressed: () => Affiliateo.openChat(context),
    child: Text(chat.unread > 0 ? 'Chat (${chat.unread})' : 'Chat'),
  ),
)
```

**The look.** Your dashboard sets the bubble's corner, size, colors, style and
the screens it shows on. Anything you set in code wins:

```dart
AffiliateoChat(
  color: const Color(0xFF7C3AED),        // the circle
  iconColor: Colors.white,               // the speech bubble inside it
  sendColor: const Color(0xFF7C3AED),    // the send button and the person's messages
  placeholder: 'Ask us anything',        // the message box text, in your app's language
  bubbleStyle: AffiliateoChatBubbleStyle.glass,
  corner: AffiliateoChatCorner.bottomLeft,
  size: 52,                              // 40 to 80
  bottomPadding: 72,                     // room for a tab bar
  wiggleSeconds: 20,                     // a wiggle every 20 seconds; 0 for none
  child: child!,
)
```

**The wiggle (4.17.0).** Every few seconds the bubble does one short wiggle so
people notice it, then rests. Wiggle in the Live Chat settings of your
dashboard sets how often: off, or every 10 to 60 seconds. Your own number wins
over it: any whole number of seconds, 3 or more, and `0` for no wiggle.

```dart
Affiliateo.setChatBubbleWiggle(seconds: 20);   // from anywhere; 0 or null for no wiggle
AffiliateoChat(wiggleSeconds: 20, child: child!) // or on the widget, which wins when both are set
```

It only wiggles while the bubble is on screen, the chat is closed and the app
is in front, never while it is being dragged, and never on a phone with
Reduce Motion on (Android: "Remove animations").

The bubble is for your app's pages: sheets, dialogs and full-screen pop-ups
(`fullscreenDialog: true`) cover it, on your main navigator or a tab's own
navigator, and it's back once they have closed. Pass `visible: false` to hide
it on a screen where it would cover something.
The dashboard's "show on these screens" rules match the name you last passed
to `Affiliateo.page(name)`, so call it per screen. If your app has its own
navigator key, pass it as `navigatorKey`; otherwise the bubble finds the
navigator itself.

**How it works.** The chat is Affiliateo's hosted chat page in a sheet over
your app, the same page the website bubble and the other SDKs open. The
person's key to their conversation lives in the phone's secure store (the
Keychain on iPhone, the Keystore on Android), on this phone only. `logout()`,
`reset()` and a different user signing in drop it, so the next person on the
phone starts a new conversation. The sheet loads only your app's own chat
page, and a link opens in the browser only when the person taps it in a
message from your team. The device, visitor and user ids go to your inbox as
labels, and are left out while the person has opted out of tracking.

### Notifications (4.17.0)

When you reply, the person sees it like a text message: your app's name and
your message, and a tap opens the chat on top of whatever screen they were on.
Flutter cannot post a system notification by itself, and this SDK does not
make you install a notifications package for it. So it works in two parts:

- **App closed or in the background: the phone shows it.** You hand the SDK
  the push token your app already gets, and Affiliateo sends the reply as a
  push the phone draws by itself (an alert on iPhone, a notification message
  on Android).
- **App open: the SDK shows its own banner.** A card slides down at the top of
  the screen with your logo, the app's name and the message, stays 5 seconds
  and slides away. A tap opens the chat, a swipe up sends it away. Nothing
  shows while the chat itself is open. No package needed, and it also works
  with no push set up at all.

With `firebase_messaging` (any push package works the same way: the SDK only
needs the token and the tapped notification's data):

```dart
import 'dart:io' show Platform;

import 'package:affiliateo/affiliateo.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

Future<void> setUpChatNotifications() async {
  final messaging = FirebaseMessaging.instance;

  // 1. Hand over the phone's push token whenever you get one: at launch once
  //    notifications are allowed, and when it changes.
  //    iPhone: the APNs token. Android: the Firebase token.
  Future<void> handOverToken() async {
    if (Platform.isIOS) {
      final token = await messaging.getAPNSToken();
      if (token != null) Affiliateo.registerChatPushToken(token, 'ios');
    } else {
      final token = await messaging.getToken();
      if (token != null) Affiliateo.registerChatPushToken(token, 'android');
    }
  }

  await handOverToken();
  messaging.onTokenRefresh.listen((_) => handOverToken());

  // 2. When the person taps a notification, hand its data to the SDK. It
  //    returns true and opens the chat when it was a chat reply.
  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    if (Affiliateo.handleChatNotification(message.data)) return;
    // your own notifications
  });

  //    The tap that started the app:
  final first = await messaging.getInitialMessage();
  if (first != null && !Affiliateo.handleChatNotification(first.data)) {
    // your own notifications
  }

  // 3. Right after the person allows notifications (and at each launch when
  //    they already had), say so. A greeting they have not seen yet then
  //    shows once as a banner.
  final settings = await messaging.getNotificationSettings();
  if (settings.authorizationStatus == AuthorizationStatus.authorized) {
    Affiliateo.chatNotificationsAllowed();
  }
}
```

- The banner is part of `AffiliateoChat`, so place it. It shows over any
  screen, also with `visible: false` (an app with its own chat button and no
  bubble). Turn it off with `AffiliateoChat(inAppBanner: false, child: child!)`
  when your app shows chat notifications itself while it is open (for
  example with `setForegroundNotificationPresentationOptions(alert: true)` on
  iPhone, which would show both).
- `Affiliateo.handleChatNotification(data)` works with or without the bubble
  placed, and right after a cold start: it waits until `configure()` has
  finished and your app has a screen. `Affiliateo.isChatNotification(data)`
  only tells you whether a notification is a chat reply.
- On iPhone pass the APNs token (`getAPNSToken()`), which is hex. A Firebase
  token does not work there: Affiliateo sends an iPhone's replies through
  Apple.
- The same code works on iPhone and Android. Affiliateo sends an iPhone's
  reply straight to Apple, with the id `firebase_messaging` looks for
  (`gcm.message_id`), so `onMessageOpenedApp` and `getInitialMessage()` hand
  you the tap there too. On iPhone `message.data['affiliateo_chat']` is a map
  (the conversation and message ids); on Android it is the text `"1"` beside
  `title` and `body`. `handleChatNotification` and `isChatNotification` read
  both, so pass `message.data` as it is.
- If you listen to `FirebaseMessaging.onMessage` (pushes that arrive while the
  app is open), skip chat replies there:
  `if (Affiliateo.isChatNotification(message.data)) return;`. The banner
  already shows them.
- The SDK reads your bundle id (iPhone) or package name (Android) itself.
  When the token belongs to another one, pass it:
  `Affiliateo.registerChatPushToken(token, 'ios', bundleId: 'com.you.app')`.
  `environment: 'sandbox'` or `'production'` (iPhone only) says which of
  Apple's services the token is for; left out, a debug or profile build counts
  as sandbox and a release build as production, and a wrong guess is corrected
  on the server.
- Today the pushes are sent with Affiliateo's own Apple and Firebase keys, so
  they only reach apps set up with Affiliateo. Sending with your own keys
  will come later. The banner in the open app works for every app.
- Nothing is registered while the person has opted out of tracking, and
  `optOut()` takes a registered phone off the list.
- `logout()` and `reset()` take the phone off the list, and it is registered
  again once the next person sends their first message, so a reply to the last
  person's chat never shows up for whoever holds the phone next. Call
  `identify()` before `registerChatPushToken()` when your app has sign-in: a
  reply reaches a phone only when it is registered for the same user the chat
  belongs to.

## Store prices

Your app's product cards on Affiliateo show each product's US price. If you
sell through RevenueCat or Adapty alone, Affiliateo can't read the store's
price list, so phones can report it: once a day, in the background, only on a
phone whose store is the US one, and only for the products Affiliateo asks
about. A price shows once enough phones agree. Nothing about the person is
sent.

Flutter reads store prices through a plugin, and the SDK adds none: hand it a
reader that asks yours. With RevenueCat (`purchases_flutter`):

```dart
await Affiliateo.configure(
  appId: 'YOUR_APP_ID',
  storePrices: (ids) async {
    final storefront = await Purchases.storefront;
    final products = [
      ...await Purchases.getProducts(ids),
      ...await Purchases.getProducts(ids, productCategory: ProductCategory.nonSubscription),
    ];
    return AffiliateoStorePrices(
      countryCode: storefront?.countryCode ?? '',
      products: [
        for (final p in products)
          AffiliateoStoreProduct(
            id: p.identifier,
            // A Google Play subscription's regular price, not its trial.
            price: (p.defaultOption?.fullPricePhase?.price.amountMicros ?? (p.price * 1000000)) / 1000000,
            currencyCode: p.currencyCode,
          ),
      ],
    );
  },
);
```

Give the regular price, not a trial or introductory one. Without a reader,
nothing is reported. Prices are for display only: commission is always worked
out from the amount paid.

## Requirements

- Flutter 3.10+
- Dart 3.0+
- iOS 13+ / Android API 24+ (since 4.15.4, for Live Chat's web view and
  secure store; 4.12.0 ran on iOS 12+ / Android API 21+)
