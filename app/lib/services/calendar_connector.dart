import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'ics.dart';
import 'ooo.dart';

/// Calendar connectors (docs/CONNECTORS.md). Works with any calendar that publishes an iCalendar address:
/// Outlook / Microsoft 365 ("Publish calendar" → ICS link), Google Calendar ("Secret address in iCal format"),
/// Apple iCloud (public calendar link), Zoho, Exchange on-premises. The secret address stays on this device and the
/// device fetches the calendar itself, so neither the address nor any event title ever reaches the Amer server:
/// only busy start/end times go into find-a-time. An all-day or "out of office" event happening now switches on
/// out-of-office automatically, and switches it off when it ends (unless you set it yourself).
class CalendarConnector {
  CalendarConnector._();
  static final instance = CalendarConnector._();
  List<Map<String, dynamic>> feeds = [];          // {name, url, last_sync, events, error}
  List<IcsEvent> events = [];
  Timer? _t;
  static Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/calendar_feeds.json');

  Future<void> load() async { try { final f = await _f(); if (await f.exists()) feeds = (jsonDecode(await f.readAsString()) as List).cast<Map<String, dynamic>>(); } catch (_) {} }
  Future<void> _save() async { try { await (await _f()).writeAsString(jsonEncode(feeds)); } catch (_) {} }

  void start() { _t ??= Timer.periodic(const Duration(minutes: 15), (_) => sync()); load().then((_) => sync()); }

  static Uri normalise(String url) {
    final u = Uri.parse(url.trim().replaceFirst(RegExp(r'^webcals?://', caseSensitive: false), 'https://'));
    if (u.scheme != 'https') throw const FormatException('The calendar address must start with https:// or webcal://');
    return u;
  }

  Future<String?> add(String name, String url) async {
    final u = normalise(url);
    feeds.removeWhere((f) => f['url'] == '$u');
    feeds.add({'name': name.trim().isEmpty ? u.host : name.trim(), 'url': '$u'});
    await _save(); return (await sync())[('$u')];
  }
  Future<void> remove(String url) async { feeds.removeWhere((f) => f['url'] == url); await _save(); await sync(); }

  /// Fetches every feed; returns url -> error for any that failed.
  Future<Map<String, String>> sync() async {
    final now = DateTime.now(), from = now.subtract(const Duration(days: 1)), to = now.add(const Duration(days: 45));
    final all = <IcsEvent>[]; final errors = <String, String>{};
    for (final f in feeds) {
      try {
        final r = await http.get(Uri.parse(f['url'] as String)).timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) throw HttpException('the calendar server answered ${r.statusCode}');
        final body = utf8.decode(r.bodyBytes, allowMalformed: true);
        if (!body.contains('BEGIN:VCALENDAR')) throw const FormatException('this address does not return a calendar');
        final ev = Ics.parse(body, from, to); all.addAll(ev);
        f..['last_sync'] = now.toIso8601String()..['events'] = ev.length..remove('error');
      } catch (e) { f['error'] = '$e'; errors[f['url'] as String] = '$e'; }
    }
    events = all..sort((a, b) => a.start.compareTo(b.start)); await _save();
    await _applyOutOfOffice(now);
    return errors;
  }

  /// Busy blocks for find-a-time: start and end only.
  List<Map<String, String>> busy() => [for (final e in events.where((e) => e.busy || e.oof))
    {'start': e.start.toUtc().toIso8601String(), 'end': e.end.toUtc().toIso8601String()}];

  Future<void> _applyOutOfOffice(DateTime now) async {
    final o = OutOfOffice.instance; if (o.c == null) return;
    final away = events.where((e) => e.oof && !e.start.isAfter(now) && e.end.isAfter(now)).toList();
    final s = o.settings;
    if (away.isNotEmpty) {
      final end = away.map((e) => e.end).reduce((a, b) => a.isAfter(b) ? a : b);
      if (s == null || s['enabled'] != true || s['source'] == 'calendar') {
        final last = end.subtract(const Duration(minutes: 1));                         // OutOfOffice counts the end date inclusively
        if (s?['end'] != DateTime(last.year, last.month, last.day).toIso8601String() || s?['enabled'] != true) {
          await o.save(enabled: true, start: DateTime(now.year, now.month, now.day), end: DateTime(last.year, last.month, last.day),
              message: (s?['message'] as String?)?.isNotEmpty == true ? s!['message'] : 'I am out of office and will reply when I am back.', delegate: s?['delegate'], source: 'calendar');
        }
      }
    } else if (s != null && s['enabled'] == true && s['source'] == 'calendar') {
      await o.save(enabled: false, start: DateTime.now(), end: DateTime.now(), message: s['message'] ?? '', delegate: s['delegate'], source: 'calendar');
    }
  }
}
