# Phone dial-in and inbound call handling

Ordinary phones can't take part in end-to-end encryption, so a phone never joins an encrypted meeting directly. Every phone path is a separate call, labelled **"Encrypted to the phone network (TLS + SRTP), not end-to-end"** (trunks require TLS and SRTP).

## Dial-in to a meeting
- **Opening it:** a host chooses **Phone dial-in** in the meeting menu. The server creates a LiveKit SIP dispatch rule on the company's inbound trunk: the trunk's number plus a **6-digit PIN**, into the meeting's own phone bridge. Opening it again returns the same number and PIN.
- **Joining:** callers dial the number and enter the PIN. People in the app who want to talk with them choose **Join the phone bridge**.
- **Closing:** **Close dial-in** deletes the rule on the media server.

## Inbound calls to the company line (hunt group)
- **Who answers:** an administrator sets the hunt group (`PUT /v1/phone/line`). Calls to the company number arrive in the Phone screen as "Incoming calls", with the caller's number masked.
- **Answering:** LiveKit's webhook tells the server about each call. When several people press **Answer** at once, exactly one gets the call (an atomic database update). Ended calls leave the list.

Tested on the real stack: `tests/phone_lines_test.py`, 9/9. This covers real LiveKit SIP API calls (rule with PIN, deletion) and real LiveKit webhooks. Locally a LiveKit participant named like the SIP gateway's callers stands in for the carrier; placing real PSTN audio needs the `livekit-sip` service and a carrier trunk.

## Voicemail
An administrator chooses the voicemail chat (`PUT /v1/phone/line` with `voicemail_room`) and invites the Connectors account into it. If nobody in the hunt group answers within 30 seconds, the connector service takes the call (from then on nobody else can answer it). It plays a tone and records up to two minutes, until the caller hangs up. The recording is posted as an end-to-end encrypted audio message: "Voicemail from +971•••••••65 (3 s)". If the caller leaves no message, it posts "Missed call". Tested on the real stack: `tests/voicemail_test.py`, 4/4. A person decrypts the WAV and finds the caller's audio in it.

## Open gaps
- There's no spoken greeting, only a tone, because no text-to-speech is deployed.
- **AI call handling** (an AI receptionist that answers, understands the caller and routes or takes a message) needs speech recognition and speech synthesis on the server. Neither is in this deployment, so calls are routed to people (the hunt group), not an AI.
- Dial-in callers and app participants meet in the bridge, not in the encrypted meeting itself; that's the security boundary, by design.
