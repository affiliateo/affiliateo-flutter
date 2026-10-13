# Affiliateo Flutter SDK

Mobile affiliate attribution and session tracking for Flutter apps (iOS & Android).

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  affiliateo:
    git:
      url: https://github.com/affiliateo/affiliateo-flutter
      ref: 4.9.0
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

## What it does

- **Identifies the device** using IDFV (iOS) or Android ID (no permissions needed)
- **Tracks sessions** automatically (app foreground)
- **Matches affiliate referrals** via fingerprint matching
- **IAP attribution** via Apple `appAccountToken` and Google `obfuscatedAccountId`

## RevenueCat Integration

If you use RevenueCat, add the attributes manually after configure.
`affiliateo_visitor_id` should be set for EVERY user (matched or organic) —
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

### Giving affiliates free access

App owners can switch complimentary access on for an individual affiliate from
their Affiliateo dashboard, which grants a promotional entitlement in their own
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
- No email or other PII is sent, same as `identify()`.

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

Pass `trackingAllowed: null` if your app never asks. On Android, pass
whether ads personalisation is on and the Google advertising id, and add the
`com.google.android.gms.permission.AD_ID` permission to your manifest.

**Send each network your sales one way only.** If your app also reports
purchases to Meta, TikTok or Snapchat with that network's own SDK (Meta's SDK
does it by itself while its automatic purchase logging is on), turn that
purchase reporting off, or leave **Send app sales** off for that network.
Otherwise the network counts every sale twice: it only matches two reports of
one sale when both carry the same id, and its own SDK doesn't send the store's
transaction id. Affiliateo's own two ways are matched on it and go out once.

## Requirements

- Flutter 3.10+
- Dart 3.0+
- iOS 12+ / Android API 21+
