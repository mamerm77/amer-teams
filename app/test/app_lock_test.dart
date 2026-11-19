import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/app_lock.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // RFC 7914 §11 / widely published PBKDF2-HMAC-SHA256 vectors
  test('PBKDF2-HMAC-SHA256, 1 iteration', () {
    expect(hex(AppLock.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1)), '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
  });
  test('PBKDF2-HMAC-SHA256, 2 iterations', () {
    expect(hex(AppLock.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 2)), 'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
  });
  test('PBKDF2-HMAC-SHA256, 4096 iterations', () {
    expect(hex(AppLock.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 4096)), 'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
  });
}
