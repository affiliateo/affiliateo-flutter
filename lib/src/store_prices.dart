/// The store's own price for the app's products, as this phone sees it
/// (4.15.4, as in the other SDKs since 4.13).
///
/// The app's product cards on Affiliateo show each product's US price. An app
/// on RevenueCat or Adapty alone gives Affiliateo no way to read the store's
/// price list, so the phones report it: once a day, in the background, only on
/// a phone whose store is the US one, and only for the products Affiliateo
/// asks about (the app's own store products). A price shows once enough
/// phones agree, so one phone never decides it.
///
/// Flutter reads store prices through a plugin, and the SDK adds none: the
/// app hands over a reader (`Affiliateo.configure(storePrices: ...)`) that
/// asks its own plugin (purchases_flutter, in_app_purchase, Adapty). Without
/// one, nothing is reported.
///
/// Nothing about the person is sent: the product ids, their prices and
/// currency, and the store's country. Display only: commission is always
/// computed off the amount paid.
library;

/// One product as the app's store plugin sees it.
class AffiliateoStoreProduct {
  const AffiliateoStoreProduct({
    required this.id,
    required this.price,
    required this.currencyCode,
  });

  /// The store's product id (for a Google Play subscription, either the plain
  /// id or "id:base-plan").
  final String id;

  /// The regular price in major units (6.99), not a trial or intro price.
  final double price;

  /// The price's currency ("USD").
  final String currencyCode;
}

/// What the app's reader found: the store's country and its products.
class AffiliateoStorePrices {
  const AffiliateoStorePrices({required this.countryCode, required this.products});

  /// The store's country for this phone ("US" or "USA"). Anything else is
  /// not reported.
  final String countryCode;
  final List<AffiliateoStoreProduct> products;
}

/// Reads the store's prices for [productIds] with the app's own store plugin.
/// Return null when it cannot tell.
typedef AffiliateoStorePriceReader = Future<AffiliateoStorePrices?> Function(List<String> productIds);

/// At most once a day per app on this phone.
const Duration storePricesInterval = Duration(hours: 24);

String storePricesCheckedKey(String campaignId) => 'affiliateo_store_prices_checked_at:$campaignId';

/// Whether a day has passed since this app's last check. A clock set back
/// does not lock it out.
bool storePricesDue(int? lastCheckedMs, int nowMs) {
  return lastCheckedMs == null ||
      nowMs - lastCheckedMs >= storePricesInterval.inMilliseconds ||
      nowMs < lastCheckedMs;
}

/// The asked id a store product answers for: itself, or a plain Play id with
/// one base plan.
String? _askedIdFor(String identifier, List<String> asked, List<String> all) {
  if (asked.contains(identifier)) return identifier;
  final at = identifier.indexOf(':');
  if (at <= 0) return null;
  final plain = identifier.substring(0, at);
  if (!asked.contains(plain)) return null;
  return all.where((id) => id.startsWith('$plain:')).length == 1 ? plain : null;
}

/// The US dollar prices for the asked ids, as the report's `prices`: only
/// when the store is the US one. Null when there is nothing to report.
List<Map<String, Object>>? storePriceReport(AffiliateoStorePrices? read, List<String> asked) {
  if (read == null) return null;
  final country = read.countryCode.trim().toUpperCase();
  if (country != 'US' && country != 'USA') return null;
  final all = read.products.map((p) => p.id).where((id) => id.isNotEmpty).toList();
  final out = <String, Map<String, Object>>{};
  for (final product in read.products) {
    final id = product.id.isEmpty ? null : _askedIdFor(product.id, asked, all);
    if (id == null || out.containsKey(id)) continue;
    if (product.currencyCode.trim().toUpperCase() != 'USD') continue;
    if (!product.price.isFinite) continue;
    final cents = (product.price * 100).round();
    if (cents <= 0) continue;
    out[id] = {'product_id': id, 'price_cents': cents, 'currency': 'USD'};
  }
  return out.isEmpty ? null : out.values.toList();
}
