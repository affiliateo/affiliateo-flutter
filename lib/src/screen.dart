import 'dart:collection';

import 'package:flutter/widgets.dart';

import 'affiliateo.dart';

/// One-line screen tracking widget. Replaces the old pattern of:
///
///   @override
///   void initState() {
///     super.initState();
///     Affiliateo.page('HomeScreen');
///   }
///
/// With:
///
///   return TrackedScreen(
///     name: 'HomeScreen',
///     child: YourScreenContent(),
///   );
///
/// Mirrors the @affiliateo/react-native useAffiliateoScreen hook, the
/// Swift .trackedScreen() ViewModifier, and the Kotlin AffiliateoScreen
/// composable. The page() call fires once when this widget is first
/// inserted into the tree, and again if the [name] or [metadata] change
/// (so navigating from `TrackedScreen(name: 'User#42')` to
/// `TrackedScreen(name: 'User#99')` is correctly counted as a new visit).
///
/// Metadata equality uses a [DeepCollectionEquality]-style hash via
/// jsonEncode so a caller passing a fresh map literal each rebuild
/// doesn't re-fire — only a logically-different payload triggers a
/// fresh page() call. Cheap on small maps.
class TrackedScreen extends StatefulWidget {
  const TrackedScreen({
    super.key,
    required this.name,
    this.metadata,
    required this.child,
  });

  /// Screen name passed to [Affiliateo.page]. Matches the funnel step
  /// types `screen` server-side.
  final String name;

  /// Optional metadata payload (plan tier, A/B variant, etc).
  final Map<String, dynamic>? metadata;

  /// The screen content to render. TrackedScreen is fully transparent —
  /// it doesn't impose any layout or styling, just wraps the firing.
  final Widget child;

  @override
  State<TrackedScreen> createState() => _TrackedScreenState();
}

class _TrackedScreenState extends State<TrackedScreen> {
  @override
  void initState() {
    super.initState();
    _fire();
  }

  @override
  void didUpdateWidget(covariant TrackedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-fire when either the screen name OR the metadata's logical shape
    // changes. Cheap stringify-compare for metadata; full equality would
    // require a deep-collection check that's not built into Flutter's
    // core libraries.
    if (oldWidget.name != widget.name || _metaKey(oldWidget.metadata) != _metaKey(widget.metadata)) {
      _fire();
    }
  }

  void _fire() {
    if (widget.name.isEmpty) return;
    // Fire-and-forget: Affiliateo.page returns a Future but the queue
    // owns delivery + retry, so the caller never awaits.
    Affiliateo.page(widget.name, widget.metadata);
  }

  String _metaKey(Map<String, dynamic>? meta) {
    if (meta == null) return '';
    try {
      // Sort keys for stability — `{a:1, b:2}` and `{b:2, a:1}` are the
      // same logical payload, shouldn't trigger a re-fire.
      final sorted = SplayTreeMap<String, dynamic>.from(meta);
      return sorted.toString();
    } catch (_) {
      return meta.toString();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
