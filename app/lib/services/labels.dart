import 'package:matrix/matrix.dart';

/// Sensitivity labels with inheritance (docs/LABELS.md). A chat's own label wins; a chat without one inherits the
/// strictest label of the team (space) it belongs to. Files and forwarded messages carry the label of the chat they
/// came from, and cannot be forwarded into a chat with a lower label.
const kLabelState = 'com.amerteams.sensitivity', kLabelKey = 'com.amerteams.label';
const labelRank = {'general': 0, 'internal': 1, 'confidential': 2, 'restricted': 3};

String? ownLabel(Room r) => r.getState(kLabelState)?.content['label'] as String?;
int rankOf(String? l) => labelRank[l?.toLowerCase()] ?? 0;

/// The label that applies to [r]: its own, else the strictest of its parent spaces.
String? labelOf(Room r) {
  final own = ownLabel(r); if (own != null) return own;
  String? best;
  for (final p in r.states[EventTypes.SpaceParent]?.keys ?? const <String>[]) {
    final parent = r.client.getRoomById(p); final l = parent == null ? null : ownLabel(parent);
    if (l != null && (best == null || rankOf(l) > rankOf(best))) best = l;
  }
  return best;
}
bool inherited(Room r) => ownLabel(r) == null && labelOf(r) != null;

/// Label an event carries (set when it was sent or forwarded), else the label of the chat it is in.
String? labelOfEvent(Event e) => (e.content[kLabelKey] as String?) ?? labelOf(e.room);

/// Why [e] may not go to [to], or null if it may.
String? forwardBlock(Event e, Room to) {
  final from = labelOfEvent(e); if (from == null) return null;
  final dest = labelOf(to);
  if (rankOf(from) > rankOf(dest)) {
    return 'This is labelled $from; ${to.getLocalizedDisplayname()} is ${dest ?? 'not labelled'}. Forward it only to a chat with the same label or higher.';
  }
  return null;
}
