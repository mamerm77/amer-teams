# Recordings with consent

Meetings are end-to-end encrypted, so the server cannot record them and never tries. The recording is made on the **host's phone or tablet**, from the video and audio that device has already decrypted, and is shared in the meeting chat as an end-to-end encrypted file.

## Consent
1. A host chooses **Record (with consent)**. Everyone in the meeting gets a prompt: *I agree* or *Decline*.
2. Recording starts only when everyone present has agreed. A visible **Recording** chip shows on every screen.
3. Anyone who joins later is asked at once. A decline, or **Withdraw consent** at any time, stops the recording, and the file so far is shared.
4. Each step (requested, consent, decline, withdrawn, started, stopped) goes to the server's hash-chained audit log: `POST /v1/meetings/recording`. Hosts can read the trail: `GET /v1/meetings/recording/{id}?room_id=`.

## Open gaps
- The host must be on Android or iOS (flutter_webrtc `MediaRecorder`). Desktop hosts see "not available".
- What's recorded is one video track (the first remote camera, else the host's own) plus the meeting audio, not a composed grid.
- Consent is enforced by the Amer Teams app. A modified client could record its own screen; no product can stop that.
- Not yet tested on a real device in CI. The video recap with chapters will build on these files and the captions.
