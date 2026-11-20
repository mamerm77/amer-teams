/// Group mentions (Phase 3, rich text): @channel / @here notify everyone in the chat, @moderators and
/// @admins notify members by role (power level). Pure logic so it can be unit-tested without a client.
///
/// - @channel and @here are sent as Matrix `@room` (m.mentions.room = true). Only members whose power
///   level reaches the room's `notifications.room` level (default 50) may send it; others see it refused.
/// - Role mentions expand on send into one pill per member holding the role, so they reach each person
///   through the normal per-user mention path (m.mentions.user_ids) and never reveal anything new.
class GroupMention {
  const GroupMention(this.tag, this.label, this.minPower, {this.everyone = false});
  final String tag;       // typed after @
  final String label;     // shown in the picker
  final int minPower;     // role threshold (members at or above), or the power needed to send @room
  final bool everyone;
}

const kGroupMentions = [
  GroupMention('channel', 'Everyone in this chat', 50, everyone: true),
  GroupMention('here', 'Everyone in this chat', 50, everyone: true),
  GroupMention('team', 'Everyone in this team (in a team channel)', 50, everyone: true),   // Teams' @team: a standard channel holds the whole team
  GroupMention('moderators', 'Moderators and owners', 50),
  GroupMention('admins', 'Owners', 100),
];

/// Group tags matching what the user has typed after @ (empty query lists all).
List<GroupMention> groupCandidates(String query) =>
    kGroupMentions.where((g) => g.tag.startsWith(query.toLowerCase())).toList();

final _groupTag = RegExp(r'(^|\s)@(channel|here|team|moderators|admins)\b', caseSensitive: false);

/// Which group tags a message uses.
Set<String> groupTagsIn(String text) =>
    _groupTag.allMatches(text).map((m) => m.group(2)!.toLowerCase()).toSet();

/// Power needed to notify the whole room, from the m.room.power_levels content.
int roomNotifyLevel(Map<String, Object?>? powerLevels) {
  final n = powerLevels?['notifications'];
  final v = n is Map ? n['room'] : null;
  return v is int ? v : 50;
}

class ExpandResult {
  ExpandResult(this.text, {this.refused});
  final String text;
  final String? refused;   // a reason when the sender may not use @channel/@here
}

/// Rewrites group tags before sending. [members] maps user id -> (display name, power level);
/// [pill] builds a user mention (mentionMarkdown). The sender is never added to their own role mention.
ExpandResult expandGroupMentions(String text, {required String me, required int myPower, required int notifyLevel,
    required Map<String, (String, int)> members, required String Function(String name, String id) pill}) {
  final tags = groupTagsIn(text);
  if (tags.isEmpty) return ExpandResult(text);
  if ((tags.contains('channel') || tags.contains('here') || tags.contains('team')) && myPower < notifyLevel) {
    return ExpandResult(text, refused: 'Only members with power level $notifyLevel or more can notify everyone with @channel.');
  }
  var out = text.replaceAllMapped(_groupTag, (m) {
    final tag = m.group(2)!.toLowerCase();
    final g = kGroupMentions.firstWhere((g) => g.tag == tag);
    if (g.everyone) return '${m.group(1)}@room';
    final who = members.entries.where((e) => e.key != me && e.value.$2 >= g.minPower).toList()
      ..sort((a, b) => a.value.$1.compareTo(b.value.$1));
    if (who.isEmpty) return '${m.group(1)}@$tag';    // nobody holds the role: leave the text as typed
    return '${m.group(1)}${who.map((e) => pill(e.value.$1, e.key)).join(' ')}';
  });
  return ExpandResult(out);
}

/// True when an event notifies the whole room (m.mentions.room or a legacy @room in the body).
bool mentionsRoom(Map<String, Object?> content, String body) {
  final m = content['m.mentions'];
  if (m is Map && m['room'] == true) return true;
  return RegExp(r'(^|\s)@room\b').hasMatch(body);
}
