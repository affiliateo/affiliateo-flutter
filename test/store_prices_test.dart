import 'package:affiliateo/src/store_prices.dart';
import 'package:flutter_test/flutter_test.dart';

AffiliateoStoreProduct p(String id, double price, [String currency = 'USD']) =>
    AffiliateoStoreProduct(id: id, price: price, currencyCode: currency);

void main() {
  test('once a day, and a clock set back does not lock it out', () {
    const day = 24 * 60 * 60 * 1000;
    expect(storePricesDue(null, 1000), isTrue);
    expect(storePricesDue(1000, 1000 + day - 1), isFalse);
    expect(storePricesDue(1000, 1000 + day), isTrue);
    expect(storePricesDue(5000, 1000), isTrue);
    expect(storePricesCheckedKey('c1'), 'affiliateo_store_prices_checked_at:c1');
  });

  test('US dollar prices for the asked ids, in cents', () {
    final report = storePriceReport(
      AffiliateoStorePrices(countryCode: 'us', products: [p('pro_yearly', 39.99), p('lifetime', 99.0)]),
      ['pro_yearly', 'lifetime', 'missing'],
    );
    expect(report, [
      {'product_id': 'pro_yearly', 'price_cents': 3999, 'currency': 'USD'},
      {'product_id': 'lifetime', 'price_cents': 9900, 'currency': 'USD'},
    ]);
  });

  test('only the US store, only dollars, only asked ids, no free or broken prices', () {
    final asked = ['a', 'b', 'c', 'd'];
    expect(storePriceReport(AffiliateoStorePrices(countryCode: 'GB', products: [p('a', 1)]), asked), isNull);
    expect(storePriceReport(AffiliateoStorePrices(countryCode: 'USA', products: [p('a', 1)]), asked), isNotNull);
    expect(
      storePriceReport(
        AffiliateoStorePrices(
          countryCode: 'US',
          products: [p('a', 1, 'EUR'), p('b', 0), p('c', double.nan), p('zzz', 5), p('d', 2), p('d', 3)],
        ),
        asked,
      ),
      [
        {'product_id': 'd', 'price_cents': 200, 'currency': 'USD'},
      ],
    );
    expect(storePriceReport(null, asked), isNull);
  });

  test('a Play subscription answers for its plain id when it has one base plan', () {
    expect(
      storePriceReport(AffiliateoStorePrices(countryCode: 'US', products: [p('pro:yearly', 29.99)]), ['pro']),
      [
        {'product_id': 'pro', 'price_cents': 2999, 'currency': 'USD'},
      ],
    );
    // Two base plans: which one is "pro" is not known, so neither.
    expect(
      storePriceReport(
        AffiliateoStorePrices(countryCode: 'US', products: [p('pro:yearly', 29.99), p('pro:monthly', 4.99)]),
        ['pro'],
      ),
      isNull,
    );
  });
}
