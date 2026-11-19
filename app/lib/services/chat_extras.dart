import 'dart:async';
import 'package:matrix/matrix.dart';
import 'call_manager.dart';
import 'matrix_service.dart';
import '../config.dart';
export 'later.dart' show ScheduledSender, Reminders;
import 'quick_views.dart';
import 'group_mentions.dart';

const kStarredType = 'com.amerteams.starred';
const kChecklistEvent = 'com.amerteams.checklist';
const kChecklistTick = 'com.amerteams.checklist.tick';

/// Reactions are fully end-to-end encrypted (docs/FEATURE_LOGIC.md). The SDK sends m.reaction in cleartext
/// (emoji, sender and target visible to the server), so Amer Teams sends `com.amerteams.reaction` with the
/// target and emoji inside the encrypted content. Cleartext m.reaction from other clients is still counted.
const kReactionEvent = 'com.amerteams.reaction';
Future<void> sendEncryptedReaction(Room room, String eventId, String key) =>
    room.sendEvent({'com.amerteams.reaction': {'event_id': eventId, 'key': key}, 'body': key}, type: kReactionEvent);
/// (target, key) of a reaction event, in either form; null if it is not a reaction.
(String, String)? reactionOf(Event e) {
  if (e.type == kReactionEvent) {
    final r = e.content.tryGetMap<String, Object?>('com.amerteams.reaction');
    final t = r?['event_id'], k = r?['key'];
    return t is String && k is String ? (t, k) : null;
  }
  if (e.type == EventTypes.Reaction) {
    final r = e.content.tryGetMap<String, Object?>('m.relates_to');
    final t = r?['event_id'], k = r?['key'];
    return t is String && k is String ? (t, k) : null;
  }
  return null;
}
/// Reaction counts per emoji for one message: one per person per emoji, redacted reactions ignored.
Map<String, int> reactionsFor(Iterable<Event> timeline, String eventId) {
  final seen = <String, Set<String>>{};
  for (final e in timeline) {
    if (e.redacted) continue;
    final r = reactionOf(e); if (r == null || r.$1 != eventId) continue;
    (seen[r.$2] ??= <String>{}).add(e.senderId);
  }
  return {for (final k in seen.keys) k: seen[k]!.length};
}

/// @mentions are sent as Matrix pills: [Name](https://matrix.to/#/@user:server) plus m.mentions.
final mentionLink = RegExp(r'\[([^\]]+)\]\(https://matrix\.to/#/(@[^)]+)\)');
String mentionMarkdown(String name, String userId) => '[$name](https://matrix.to/#/$userId)';
String plainMentions(String body) => body.replaceAllMapped(mentionLink, (m) => '@${m[1]}');
bool mentionsMe(Event e, String me) {
  final ids = (e.content.tryGetMap<String, Object?>('m.mentions')?['user_ids'] as List?)?.cast<String>() ?? const [];
  return ids.contains(me) || e.body.contains(me) || mentionsRoom(e.content, e.body);   // @channel / @here arrive as @room
}

/// Saved / starred messages, kept in the user's (server-side, per-account) account data.
class StarService {
  StarService(this.m);
  final MatrixService m;
  Map<String, List<String>> get all {
    final c = m.client.accountData[kStarredType]?.content ?? {};
    return {for (final e in c.entries) e.key: (e.value as List).cast<String>()};
  }
  bool isStarred(String roomId, String eventId) => all[roomId]?.contains(eventId) ?? false;
  Future<void> toggle(String roomId, String eventId) async {
    final a = all; final l = a[roomId] ?? [];
    l.contains(eventId) ? l.remove(eventId) : l.add(eventId);
    a[roomId] = l;
    await m.client.setAccountData(m.client.userID!, kStarredType, a);
  }
  Future<List<Event>> load() async {
    final out = <Event>[];
    for (final e in all.entries) {
      final r = m.client.getRoomById(e.key); if (r == null) continue;
      for (final id in e.value) { final ev = await r.getEventById(id); if (ev != null) out.add(ev); }
    }
    out.sort((a, b) => b.originServerTs.compareTo(a.originServerTs));
    return out;
  }
}

/// One line in the Activity feed.
class Activity {
  Activity(this.kind, this.room, this.event, this.text);
  final String kind;   // mention, reply, reaction, missed_call
  final Room room; final Event event; final String text;
}

class ActivityService {
  ActivityService(this.m);
  final MatrixService m;
  Future<List<Activity>> load({int perRoom = 80}) async {
    final me = m.client.userID!; final out = <Activity>[];
    for (final r in m.rooms) {
      final tl = await r.getTimeline();
      try {
        final mine = tl.events.where((e) => e.senderId == me).map((e) => e.eventId).toSet();
        final joined = tl.events.where((e) => e.type == kCallJoinedEvent && e.senderId == me).map((e) => e.content['call_id']).toSet();
        for (final e in tl.events.take(perRoom)) {
          if (e.senderId == me) continue;
          final who = e.senderFromMemoryOrFallback.calcDisplayname();
          final rel = e.content.tryGetMap<String, Object?>('m.relates_to');
          final rx = reactionOf(e);
          if (rx != null && mine.contains(rx.$1)) {
            out.add(Activity('reaction', r, e, '$who reacted ${rx.$2}'));
          } else if (e.type == kCallInviteEvent && e.content['version'] == 2) {
            final sm = CallSummary.of(tl.events, e.content['call_id'] as String, e.originServerTs);
            if (sm.outcome == 'missed' || sm.outcome == 'busy') out.add(Activity('missed_call', r, e, 'Missed ${e.content['media'] == 'audio' ? 'voice' : 'video'} call from $who'));
          } else if (e.type == kCallInviteEvent && !(e.content['call_id'] as String? ?? '').startsWith('meet-') && !joined.contains(e.content['call_id'])) {
            out.add(Activity('missed_call', r, e, 'Missed ${e.content['media'] == 'audio' ? 'voice' : 'video'} call from $who'));
          } else if (e.type == EventTypes.Message) {
            final replyTo = rel?.tryGetMap<String, Object?>('m.in_reply_to')?['event_id'];
            if (mentionsMe(e, me)) { out.add(Activity('mention', r, e, '$who mentioned you: ${plainMentions(e.body)}')); }
            else if (replyTo != null && mine.contains(replyTo) && !(e.relationshipType == RelationshipTypes.thread && Threads.mode(r.client, r.id, '${e.relationshipEventId}') == 'mute')) { out.add(Activity('reply', r, e, '$who replied: ${plainMentions(e.body).split('\n').where((l) => !l.startsWith('> ')).join(' ')}')); }
          }
        }
      } finally { tl.cancelSubscriptions(); }
    }
    out.sort((a, b) => b.event.originServerTs.compareTo(a.event.originServerTs));
    return out.take(200).toList();
  }
}

