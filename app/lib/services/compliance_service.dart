import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'api_service.dart';

/// Business tenants with compliance archiving (docs/COMPLIANCE.md): the organisation's archiving account must be a
/// member of the user's conversations so it receives the keys like any participant. Public users: nothing happens.
class ComplianceService extends ChangeNotifier {
  ComplianceService._();
  static final instance = ComplianceService._();

  bool enabled = false; String? archiver, orgName; int retentionDays = 0;
  Timer? _t; Client? _client; ApiService? _api;

  Future<void> start(Client client, ApiService api) async {
    _client = client; _api = api;
    await _refresh();
    _t?.cancel(); _t = Timer.periodic(const Duration(minutes: 5), (_) => _refresh());
  }
  void stop() { _t?.cancel(); _t = null; enabled = false; archiver = null; notifyListeners(); }

  Future<void> _refresh() async {
    try {
      final j = await _api!.myCompliance();
      enabled = j['compliance_enabled'] == true; archiver = j['compliance_user'] as String?;
      orgName = j['name'] as String?; retentionDays = (j['retention_days'] as num?)?.toInt() ?? 0;
      notifyListeners();
      if (enabled && archiver != null) await _ensureMember();
    } catch (_) { /* offline: try again next time */ }
  }

  /// Adds the archiving account to every conversation this user can invite into.
  Future<void> _ensureMember() async {
    final c = _client!, a = archiver!;
    for (final r in c.rooms) {
      if (r.isSpace || r.membership != Membership.join) continue;
      final m = r.getState(EventTypes.RoomMember, a)?.content['membership'];
      if (m == 'join' || m == 'invite' || m == 'ban') continue;
      if (!r.canInvite) continue;
      try { await r.invite(a); } catch (_) {}
    }
  }

  /// True when this conversation is archived (the archiving account is in it).
  bool archives(Room r) {
    if (archiver == null) return false;
    final m = r.getState(EventTypes.RoomMember, archiver!)?.content['membership'];
    return m == 'join' || m == 'invite';
  }
}
