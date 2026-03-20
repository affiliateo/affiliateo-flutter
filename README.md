# Affiliateo Flutter SDK

Mobile affiliate attribution and session tracking for Flutter apps (iOS & Android).

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  affiliateo:
    git:
      url: https://github.com/NicoGrajales/affiliateo-flutter
      ref: 1.0.0
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

## What it does

- **Identifies the device** using IDFV (iOS) or Android ID (no permissions needed)
- **Tracks sessions** automatically (app foreground / background)
- **Matches affiliate referrals** via fingerprint matching
- **Sets RevenueCat attributes** automatically if RevenueCat is installed

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
