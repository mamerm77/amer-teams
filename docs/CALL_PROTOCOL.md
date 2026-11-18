# Amer Teams — Call, Chat and Meeting Flows (protocol v2)

Modelled on the Matrix VoIP specification (`m.call.invite` / `answer` / `reject` / `hangup`, invite lifetime,
party IDs, answered-elsewhere) with media carried by LiveKit instead of SDP. All signalling events are sent in
the end-to-end encrypted room, so the server sees only ciphertext and timing.

## 1. 1:1 call signalling events (`com.amerteams.call.*`)
| Event | Sent by | Content | Meaning |
|---|---|---|---|
| `invite` | caller | `call_id, party_id, media: audio\|video, lifetime_ms: 45000, version: 2` | Start ringing the other side |
| `ringing` | each callee device | `call_id, party_id` | "This device received the invite and is ringing" (delivery receipt) |
| `answer` | the callee device that accepts | `call_id, party_id` | Call accepted on that device |
| `reject` | callee | `call_id, party_id, reason: declined\|busy` | Not accepted |
| `hangup` | either side | `call_id, party_id, reason` | Ends the call. Reasons: `user_hangup`, `invite_timeout`, `cancelled`, `answered_elsewhere`, `failed` |
| `end` | caller (or last to leave) | `call_id, duration_s, outcome` | Final record for call history (`completed, missed, declined, busy, cancelled, failed`) |
| `key` | any member | (post-quantum hybrid call key, see SECURITY.md) | Media key; only after answer |

`party_id` = the sending device ID, so multi-device behaviour is unambiguous.

## 2. Caller state machine
```
idle ──invite──▶ calling ──first `ringing`──▶ ringing ──`answer`──▶ connecting ──remote media joined──▶ connected
                  │                             │                      │                                  │
                  │ lifetime 45 s, no answer ───┴──▶ no_answer          └──▶ failed (media did not          └─ hangup ─▶ ended
                  │ `reject` declined ─────────────▶ declined                  connect within 20 s)
                  │ `reject` busy ─────────────────▶ busy
                  └ caller taps End ───────────────▶ cancelled (sends hangup: cancelled)
```
- The **call timer starts only in `connected`**, when the other person's media actually arrives.
- `calling` means no callee device has confirmed receipt yet (e.g. the person is offline). The screen says
  "Calling… (not reachable yet)". If any device rings, it moves to `ringing` and says "Ringing…".
- On `no_answer`, the caller sends `hangup(invite_timeout)` and `end(outcome: missed)`; the callee sees a missed call.

## 3. Callee state machine (per device)
```
receive invite ─(expired? already answered/hung up? sender is me? blocked?)─▶ ignore
        │
        ├─ already in a call ─▶ send reject(busy) ─▶ idle
        └─ send ringing ─▶ ringing (ringtone + vibration) ──Accept──▶ send answer ─▶ connecting ─▶ connected
                              │ Decline ─▶ send reject(declined) ─▶ idle
                              │ lifetime expires / caller hangup ─▶ missed (notification)
                              └ `answer` from another of MY devices ─▶ stop ringing (answered elsewhere)
```
- Invites are honoured only while `now − origin_server_ts < lifetime_ms`, so opening the app later never rings for an old call; it shows a missed call instead.

## 4. Glare (both call each other at once)
If a device has an outgoing `calling/ringing` call to the same room and receives an `invite`, the call with the
lexicographically **smaller `call_id` wins**; the other side hangs up its own invite (`hangup: cancelled`) and
answers the winning one automatically.

## 5. Group calls and meetings
- No ringing; the room shows **"Meeting in progress · N people"** based on live participants from the media
  server, and **Join** only while N > 0 (otherwise **Start**).
- The meeting timer starts when the local device's media connects; leaving sends nothing unless you were the
  last person (then `end`).
- Waiting room, host controls, webinar mode: see README.

## 6. Message lifecycle
`composing → sending (🕓) → sent (✓, server accepted) → read (✓✓, a recipient's read receipt) | failed (⚠ tap to retry or delete)`
- Matrix has no "delivered to device" receipt for messages; ✓ means stored on the server for all recipients.
- Failed messages are kept locally until retried or deleted; nothing is silently lost.

## 7. Timeouts
| Timer | Value |
|---|---|
| Invite lifetime / ring time | 45 s |
| Media connect after answer | 20 s |
| Caller shows "not reachable" hint | after 6 s without `ringing` |
