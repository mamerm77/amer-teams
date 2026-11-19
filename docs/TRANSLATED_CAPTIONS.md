# Live translated captions

In a call: More → **Translated captions** → choose a language: English, Arabic, French, Hindi, Urdu, Bengali, Tagalog, Spanish, Chinese or Russian.

- Speech becomes text on each speaker's own device (on-device speech recognition). Captions are shared with the meeting, over the encrypted data channel, only while Amer is on in that meeting.
- Each listener chooses their own language. Translation is for that listener only.
- Translation goes through the encrypted-AI router: the chat's sensitivity label is honoured (Confidential or Restricted is refused), and encrypted meetings use the enclave path when it is available. The caption bar says which language it shows; Arabic and Urdu lines are right-to-left.
- If translation falls behind speech, the oldest lines are dropped, so it stays live.

## Open gaps
- Translation runs on the AI engine, one line at a time, so it lags speech by about a second or two. There is no on-device translation model yet.
- Others' captions need Amer on in the meeting, by design: no captions leave a device without that.
- Recognition quality depends on the device's speech engine and the speaker's language setting.
