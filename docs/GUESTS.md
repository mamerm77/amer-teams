# Browser join for guests

A guest without an Amer Teams account joins a meeting from any current browser (Chrome, Edge, Firefox, Safari 17+).

1. A host chooses **Guest link (browser)** in the meeting's More menu. The link is `https://<server>/join#<code>`. The code sits after `#`, so it is never sent in a request line or logged by a proxy. It lasts 24 hours (configurable, at most 30 days), up to 50 uses, and is stored hashed.
2. The guest types a name. The server gives a media token with an identity starting `guest-` and the name shown as "Name (guest)".
3. **Lobby and encryption:** the page makes a one-time X25519 key pair and announces the public key over the meeting's data channel. The host sees "Sara is waiting in the lobby" with **Let in** and **Remove**. Let in wraps the call key to the guest's key (X25519 → HKDF-SHA256 with salt `epk‖guest_pk`, info `amer-guest-v1` → AES-256-GCM) and sends it. The server never has the call key. Until a host lets them in, the guest can decode no audio or video. When the key rotates, the host's app sends the new one to each admitted guest.

Tested on the real local stack (`tests/guest_test.py`, 12/12). That run uses a real LiveKit server, a real Chromium on the `/join` page, and a host holding the end-to-end call key. The guest decodes nothing while in the lobby, then shows the host's encrypted video after being let in.

## Open gaps
- The Flutter host's admit path uses the same wire format as the test host, but hasn't yet been run against a browser guest in CI.
- Guests can't use the meeting chat, whiteboard or captions; they get video, audio and Q&A.
- Q&A and lobby messages use the meeting data channel, like the in-meeting chat. The call key is wrapped; the question text is not separately encrypted.
- A guest needs a host present to be let in.
