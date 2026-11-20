import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Urgent messages (Teams delivery option): the recipient is alerted at once and again every 2 minutes for
/// 20 minutes, until the chat is read. The alert is a banner over the app with a sound-free vibration of the UI.
class Urgent {
  Urgent._();
  static final instance = Urgent._();
  final pending = ValueNotifier<List<Event>>([]);
  StreamSubscription? _sub; Timer? _t; Client? _c;
  final _first = <String, DateTime>{};

  void start(Client c) {
    _sub?.cancel(); _t?.cancel(); _c = c;
    _sub = c.onTimelineEvent.stream.listen((e) {
      if (e.type != EventTypes.Message || e.senderId == c.userID || !e.body.startsWith('URGENT! ')) return;
      if (DateTime.now().difference(e.originServerTs) > const Duration(minutes: 20)) return;
      _first[e.eventId] = DateTime.now(); _refresh();
    });
    _t = Timer.periodic(const Duration(minutes: 2), (_) => _refresh(realert: true));
  }
  void stop() { _sub?.cancel(); _t?.cancel(); }

  bool _read(Event e) => e.room.notificationCount == 0;   // the chat has been opened and read

  void _refresh({bool realert = false}) {
    final now = DateTime.now();
    _first.removeWhere((id, t) => now.difference(t) > const Duration(minutes: 20));
    final evs = <Event>[];
    for (final r in _c?.rooms ?? const <Room>[]) {
      final last = r.lastEvent;
      if (last != null && _first.containsKey(last.eventId) && !_read(last)) evs.add(last);
    }
    pending.value = [...evs];   // a new list each time, so the banner shows again (re-alert) even if unchanged
  }

  void dismiss(Event e) { _first.remove(e.eventId); pending.value = pending.value.where((x) => x.eventId != e.eventId).toList(); }
}
