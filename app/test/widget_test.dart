import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/screens/login_screen.dart';

void main() {
  test('password policy matches the server', () {
    expect(LoginScreenPolicy.check('Ab1!'), isNotNull);
    expect(LoginScreenPolicy.check('optical-net#2026'), isNotNull);
    expect(LoginScreenPolicy.check('Optical-Net#2026'), isNull);
  });
}
