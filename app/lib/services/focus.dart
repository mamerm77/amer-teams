import 'availability.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'api_service.dart';

/// Focus guardian (docs/FOCUS.md). A focus session: the server holds every push except your priority senders
/// (even mentions wait), your status says "Focusing until 11:30", direct messages get one automatic reply each,
/// your free/busy shows the time as busy, and when it ends you get a summary of what waited.
class FocusGuard {
  FocusGuard._();
  static final instance = FocusGuard._();
  static const type = 'com.amerteams.focus';
  Client? c; ApiService? _api; StreamSubscription? _sub; Timer? _end; final _replied = <String>{};
  /// Set when a session ends on its own, so the app can show what waited.
  final ended = ValueNotifier<FocusSummary?>(null);
  DateTime? get until { final u = c?.accountData[type]?.content['until']; final t = u is int ? DateTime.fromMillisecondsSinceEpoch(u) : null; return t != null && t.isAfter(DateTime.now()) ? t : null; }
  DateTime? get started { final s = c?.accountData[type]?.content['start']; return s is int ? DateTime.fromMillisecondsSinceEpoch(s) : null; }
  bool get active => until != null;
  /// Past sessions (start, end) this week, for wellbeing.
  List<(DateTime, DateTime)> get history => [for (final h in (c?.accountData[type]?.content['history'] as List? ?? const []))
    if (h is List && h.length == 2) (DateTime.fromMillisecondsSinceEpoch(h[0] as int), DateTime.fromMillisecondsSinceEpoch(h[1] as int))];

  void attach(Client client, ApiService api) {
    c = client; _api = api; _sub ??= client.onTimelineEvent.stream.listen(_onEvent);
    final u = until; if (u != null) _schedule(u.difference(DateTime.now()));
  }
  void _schedule(Duration d) { _end?.cancel(); _end = Timer(d, () async { if (_api != null) ended.value = await stop(_api!); }); }

  Future<void> start(ApiService api, int minutes) async {
    final now = DateTime.now(), u = now.add(Duration(minutes: minutes));
    await api.postMap('/v1/notify/focus', {'minutes': minutes});
    await c!.setAccountData(c!.userID!, type, {'start': now.millisecondsSinceEpoch, 'until': u.millisecondsSinceEpoch, 'history': _trim([...history.map((h) => [h.$1.millisecondsSinceEpoch, h.$2.millisecondsSinceEpoch])])});
    Availability.instance.overlay(Avail.focusing, 'until ${_hm(u)}');          // presence is decided in one place (availability.dart)
    _api = api; _replied.clear(); _schedule(Duration(minutes: minutes));
  }

  /// Ends now (or records the natural end); returns what waited.
  Future<FocusSummary> stop(ApiService api) async {
    final s = started ?? DateTime.now(), e = DateTime.now();
    try { await api.postMap('/v1/notify/focus', {'minutes': 0}); } catch (_) {}
    await c!.setAccountData(c!.userID!, type, {'until': 0, 'history': _trim([...history.map((h) => [h.$1.millisecondsSinceEpoch, h.$2.millisecondsSinceEpoch]), [s.millisecondsSinceEpoch, e.millisecondsSinceEpoch]])});
    Availability.instance.overlay(null);
    _end?.cancel();
    final rooms = c!.rooms.where((r) => r.notificationCount > 0 && (r.lastEvent?.originServerTs.isAfter(s) ?? false)).toList();
    return FocusSummary(e.difference(s), rooms.length, rooms.fold(0, (n, r) => n + r.notificationCount), rooms.fold(0, (n, r) => n + r.highlightCount), rooms.map((r) => r.getLocalizedDisplayname()).take(5).toList());
  }

  List<List<int>> _trim(List<List<int>> h) { final week = DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch; return h.where((x) => x[1] > week).toList(); }
  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _onEvent(Event e) async {
    final u = until; final me = c?.userID;
    if (u == null || me == null || e.senderId == me || e.type != EventTypes.Message || !e.room.isDirectChat) return;
    if (e.originServerTs.isBefore(started ?? DateTime.now()) || !_replied.add(e.senderId)) return;
    try { await e.room.sendTextEvent('🎧 I am focusing until ${_hm(u)} and will reply then. If it is urgent, please call me.'); } catch (_) {}
  }
}

class FocusSummary {
  FocusSummary(this.length, this.chats, this.messages, this.mentions, this.names);
  final Duration length; final int chats, messages, mentions; final List<String> names;
  String get text => messages == 0 ? 'You focused for ${length.inMinutes} minutes. Nothing waited for you.'
      : 'You focused for ${length.inMinutes} minutes. $messages message${messages == 1 ? '' : 's'} in $chats chat${chats == 1 ? '' : 's'}${mentions > 0 ? ', $mentions mentioning you' : ''}: ${names.join(', ')}.';
}
