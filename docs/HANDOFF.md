# Multi-device handoff

While you are in a meeting or group call, your account data records which device has it (`com.amerteams.active_call`: room, call, device, start time; no content). Your other signed-in devices show **"You are in a meeting on Pixel 8 — Move it here"**.

**Move it here** joins from the new device. The media server allows one connection per person in a call, so the old device is disconnected straight away; it says "This call moved to your other device" (spoken for screen readers too) and closes the call screen. The new device gets the call key the normal way: keys are wrapped to each of your devices' published quantum-safe keys, and a newly announced device triggers a rekey.

Leaving the call clears the record; it is ignored after six hours if a device crashed.

## Open gaps
- 1:1 calls (ringing protocol) aren't handed over yet: meetings and group calls only.
- Not tested with two real devices in CI. The mechanism, LiveKit's duplicate-identity disconnect, is standard behaviour.
- Chat drafts don't follow you to another device (read position does, via Matrix read markers).
