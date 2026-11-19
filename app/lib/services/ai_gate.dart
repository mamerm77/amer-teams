import 'package:matrix/matrix.dart';
import 'ai_router.dart';
import 'feature_flags.dart';
export 'ai_router.dart';

/// The routing decision for AI on a chat's content, with this deployment's capabilities: no on-device model is
/// installed yet, and the enclave counts only when its attestation verifies (none is deployed yet).
AiDecision aiFor(Room room, {bool small = false}) => routeAi(
    encrypted: room.encrypted, label: room.getState('com.amerteams.sensitivity')?.content['label'] as String?, small: small,
    deviceModel: false, enclaveAttested: false, plainServerAllowed: Flags.instance.on('ai_plain_server'));
