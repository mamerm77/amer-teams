# Team settings (Microsoft Teams owner, member and guest rules)

Team owners open **Team settings** from the team's menu. On Save, each setting is written to the team (`com.amerteams.team`) and applied to every channel's Matrix power levels. That way **the server enforces it** wherever Matrix allows:

| Setting | Default (as in Teams) | Enforced by |
|---|---|---|
| Members can create channels | On | Server: the team's `m.space.child` permission (0 or 50) |
| Members can add, remove and change tabs | On | Server: each channel's `com.amerteams.channel` permission |
| Members can use @channel | On | Server: each channel's `notifications.room` level (Synapse checks every @room) |
| Members can edit and delete their messages | On | App (Matrix always lets people redact their own messages) |
| Archive the team | Off | Server: every channel's `events_default` 100 (read-only except owners); restore sets it back to 0 |

Owners can also edit the team's name and description and change its picture. Members cannot change the settings: the server refuses the change.

Tests: `tests/team_settings_test.py` (4 checks on the real stack, using a real member account).

## Join a team with a code
Owners open the team menu → **Team code** for a 7-character code: a Matrix alias `#team-<code>:server`, with the team set to accept join requests (knock). Anyone enters the code in Teams → **Join with a code**. The request appears at the top of the team for owners, with **Approve** (adds them to the team and its standard channels) or **Decline**. Once approved, the requester's app joins the team and its channels by itself. Only owners can approve: private teams are created so that only owners add people (`invite` power level 50), as in Teams. Tests: `tests/team_code_test.py` (5 checks on the real stack).
