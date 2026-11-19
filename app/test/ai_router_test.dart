import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/ai_router.dart';

/// The spec's routing table, row by row.
void main() {
  test('Restricted: device only, refused without a model', () {
    expect(routeAi(encrypted: true, label: 'Restricted', plainServerAllowed: true, enclaveAttested: true).route, AiRoute.refuse);
    expect(routeAi(encrypted: true, label: 'Restricted', deviceModel: true).route, AiRoute.device);
  });
  test('small task on device when a model is installed and the battery is above 20%', () {
    expect(routeAi(encrypted: true, small: true, deviceModel: true).route, AiRoute.device);
    expect(routeAi(encrypted: true, small: true, deviceModel: true, batteryPct: 15, enclaveAttested: true).route, AiRoute.enclave);
  });
  test('Confidential: enclave after attestation, never the plain server', () {
    expect(routeAi(encrypted: true, label: 'Confidential', enclaveAttested: true).route, AiRoute.enclave);
    expect(routeAi(encrypted: true, label: 'Confidential', plainServerAllowed: true).route, AiRoute.refuse);
  });
  test('enclave down: no silent fallback to the plain server', () {
    expect(routeAi(encrypted: true).route, AiRoute.refuse);
    expect(routeAi(encrypted: true, plainServerAllowed: true).route, AiRoute.server);      // only by explicit policy
  });
  test('unattested proxy: used for General chats when allowed, never for Confidential or Restricted', () {
    expect(routeAi(encrypted: true, unattestedProxy: true, plainServerAllowed: true).route, AiRoute.proxy);
    expect(routeAi(encrypted: true, label: 'Confidential', unattestedProxy: true).route, AiRoute.refuse);
    expect(routeAi(encrypted: true, label: 'Restricted', unattestedProxy: true).route, AiRoute.refuse);
  });
  test('unencrypted content uses the normal path', () {
    expect(routeAi(encrypted: false, label: 'Restricted').route, AiRoute.server);
  });
}
