import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/dlp.dart';

void main() {
  test('card numbers pass Luhn; random digits do not', () {
    expect(dlpScan('card 4111 1111 1111 1111 please').map((h) => h.kind), ['card number']);
    expect(dlpScan('order 4111 1111 1111 1112'), isEmpty);
    expect(dlpScan('call +971 50 123 4567'), isEmpty);
  });
  test('IBAN with a valid check digit', () {
    expect(dlpScan('pay AE07 0331 2345 6789 0123 456').map((h) => h.kind), contains('bank account (IBAN)'));
    expect(dlpScan('AE08 0331 2345 6789 0123 456').where((h) => h.kind.startsWith('bank')), isEmpty);
  });
  test('Emirates ID', () {
    expect(dlpScan('ID 784-1985-1234567-1').map((h) => h.kind), ['Emirates ID number']);
  });
}
