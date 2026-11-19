/// Encrypted AI router (docs/ENCRYPTED_AI.md), the routing table of the spec, decided on the device per request.
/// Where an answer ran is always shown. Encrypted content never silently goes to the plain server: that path is
/// used only when the organisation's policy ("ai_plain_server") allows it, and never for Confidential or
/// Restricted chats.
library;

enum AiRoute { device, enclave, server, refuse }

class AiDecision {
  const AiDecision(this.route, this.why);
  final AiRoute route; final String why;
  bool get allowed => route != AiRoute.refuse;
  /// The line shown with every AI answer.
  String get where => switch (route) {
    AiRoute.device => '🔒 Ran on this device', AiRoute.enclave => '🔒 Ran in the attested enclave',
    AiRoute.server => 'Ran on your organisation\'s AI service (not end-to-end encrypted)', AiRoute.refuse => why };
}

/// [label]: the chat's sensitivity label. [small]: translate, classify or a short summary (under ~4k tokens).
AiDecision routeAi({required bool encrypted, String? label, bool small = false, bool deviceModel = false, bool enclaveAttested = false, bool plainServerAllowed = false, int batteryPct = 100}) {
  final l = (label ?? '').toLowerCase();
  if (!encrypted) return const AiDecision(AiRoute.server, 'Not end-to-end encrypted content');
  if (l == 'restricted') {
    return deviceModel ? const AiDecision(AiRoute.device, 'Restricted: on this device only')
        : const AiDecision(AiRoute.refuse, 'This chat is Restricted: AI may only run on this device, and no on-device model is installed.');
  }
  if (small && deviceModel && batteryPct > 20) return const AiDecision(AiRoute.device, 'Small task on this device');
  if (enclaveAttested) return const AiDecision(AiRoute.enclave, 'Enclave attestation verified');
  if (l == 'confidential') return const AiDecision(AiRoute.refuse, 'This chat is Confidential: AI may only run in an attested enclave, and none is available. Try again later.');
  if (plainServerAllowed) return const AiDecision(AiRoute.server, 'Organisation policy allows the AI service for General chats');
  return const AiDecision(AiRoute.refuse, 'No on-device model or attested enclave is available, and your organisation does not allow encrypted chats to go to the AI service.');
}
