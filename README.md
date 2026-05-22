# Affiliateo Flutter SDK

Mobile affiliate attribution and session tracking for Flutter apps (iOS & Android).

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  affiliateo:
    git:
      url: https://github.com/affiliateo/affiliateo-flutter
      ref: 3.0.0
```

Then run `flutter pub get`.

## Usage

Initialize at app startup:

```dart
import 'package:affiliateo/affiliateo.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Affiliateo.configure(campaignId: 'YOUR_CAMPAIGN_ID');
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

Screens are tracked when you call `Affiliateo.page(name)` per screen. This matches the Mixpanel / Amplitude / Datafast model. predictable, no ghost events polluting funnels.

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

If you use RevenueCat, add the attribute manually after configure:

```dart
import 'package:purchases_flutter/purchases_flutter.dart';

final state = Affiliateo.state;
if (state.refCode != null) {
  await Purchases.setAttributes({"affiliateo_ref": state.refCode!});
}
```

## Requirements

- Flutter 3.10+
- Dart 3.0+
- iOS 12+ / Android API 21+
