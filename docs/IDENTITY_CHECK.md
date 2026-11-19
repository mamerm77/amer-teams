# Impersonation protection in calls (deepfake defence)

No app can reliably tell synthetic video or voice from real by looking at it, and Amer doesn't claim to. It protects identity in two other ways.

1. **Who is really connected.** Media identities are Matrix user ids. The media server admits only people holding a token for a member of this encrypted chat, and media is end-to-end encrypted with keys wrapped to members' own devices. Every tile and the participant list show an identity badge:
   - **Verified:** all of that person's devices are verified.
   - **Partly verified** or **Not verified:** compare safety codes to verify.
   - **Browser guest:** not an Amer Teams account.
2. **Live check** (participant list → shield button). Amer sends three random words, end-to-end encrypted, to that person's own account in your direct chat, and you ask them to read the words aloud. Someone injecting a fake face or voice into the call can't see the code, so can't say it. The real person also gets a warning: "if you are not in a meeting right now, someone may be impersonating you". The result is recorded in the meeting ("passed a live check").

## Open gaps
- The check proves the speaker controls the person's account. If the account itself is compromised, it proves nothing; verified devices reduce that risk.
- No automatic synthetic-media detection model.
