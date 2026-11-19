import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/group_mentions.dart';

String pill(String n, String id) => '[$n](https://matrix.to/#/$id)';
final members = {'@me:x': ('Me', 100), '@ali:x': ('Ali', 50), '@sara:x': ('Sara', 0), '@boss:x': ('Boss', 100)};

void main() {
  test('picker filters by prefix', () {
    expect(groupCandidates('').length, 4);
    expect(groupCandidates('mo').map((g) => g.tag), ['moderators']);
  });
  test('@channel and @here become @room for allowed senders', () {
    final r = expandGroupMentions('hi @channel and @here', me: '@me:x', myPower: 50, notifyLevel: 50, members: members, pill: pill);
    expect(r.refused, isNull);
    expect(r.text, 'hi @room and @room');
  });
  test('@channel refused below the notify level', () {
    final r = expandGroupMentions('@channel now', me: '@sara:x', myPower: 0, notifyLevel: 50, members: members, pill: pill);
    expect(r.refused, isNotNull);
  });
  test('role mentions expand to pills, sender excluded', () {
    final r = expandGroupMentions('ping @moderators', me: '@me:x', myPower: 100, notifyLevel: 50, members: members, pill: pill);
    expect(r.text, 'ping ${pill('Ali', '@ali:x')} ${pill('Boss', '@boss:x')}');
    final a = expandGroupMentions('@admins', me: '@boss:x', myPower: 100, notifyLevel: 50, members: members, pill: pill);
    expect(a.text, pill('Me', '@me:x'));
  });
  test('no match inside words or emails', () {
    expect(groupTagsIn('mail team@channel.com'), isEmpty);
  });
  test('notify level and room detection', () {
    expect(roomNotifyLevel(null), 50);
    expect(roomNotifyLevel({'notifications': {'room': 0}}), 0);
    expect(mentionsRoom({'m.mentions': {'room': true}}, 'x'), isTrue);
    expect(mentionsRoom({}, 'hey @room'), isTrue);
    expect(mentionsRoom({}, 'hey'), isFalse);
  });
}
