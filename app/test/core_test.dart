import 'package:fantikpay/core/format.dart';
import 'package:fantikpay/core/ids.dart';
import 'package:fantikpay/core/pin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('ru'));

  test('wallet ids match the server (uuid5)', () {
    // Values computed with app.services.ledger on the server.
    expect(persistentWalletId('11111111-1111-1111-1111-111111111111'), '9c87503f-2e67-5485-9657-4df3ecbe1acf');
    expect(sessionWalletId('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111'), '4891c2e1-e3e5-5fbb-910a-94e7771784d2');
    expect(systemWalletId('33333333-3333-3333-3333-333333333333', 'bank'), 'bca96871-882d-5851-a980-87986f6ae5ea');
  });

  test('PIN hash is compatible with the server (PBKDF2-SHA256)', () {
    const pin = PinHash(salt: 'MDEyMzQ1Njc4OWFiY2RlZg==', hash: 'lthrw4diKhMqjsP6Pb8Ut8JakDM53i2wZ0MKCGR8gn4=', iterations: 1000);
    expect(pin.verify('1234'), isTrue);
    expect(pin.verify('4321'), isFalse);
  });

  test('russian plurals and names', () {
    expect(coins(1), '1 монета');
    expect(coins(3), '3 монеты');
    expect(coins(11), '11 монет');
    expect(coins(1500), '1 500 монет');
    expect(players(3), '3 игрока');
    expect(genitive('Маша'), 'Маши');
    expect(genitive('Тимур'), 'Тимура');
    expect(genitive('Соня'), 'Сони');
    expect(dative('Тимур'), 'Тимуру');
    expect(dative('Соня'), 'Соне');
    expect(signed(-200), '−200');
  });
}
