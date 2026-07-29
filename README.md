# Affiliateo Flutter SDK

Mobile affiliate attribution and session tracking for Flutter apps (iOS & Android).

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  affiliateo:
    git:
      url: https://github.com/affiliateo/affiliateo-flutter
      ref: 4.5.0
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

## Requirements

- Flutter 3.10+
- Dart 3.0+
- iOS 12+ / Android API 21+
