# Webinars and town halls: registration and Q&A

- **Attendees cannot publish:** webinar mode was already enforced in the media token.
- **Registration:** a host chooses **Webinar registration page**. Anyone with the page (`/join?w=<slug>`) registers with a name and email, up to the capacity (default 500), and gets a personal join link (ten uses). They join from the browser as attendees, through the same lobby and key hand-over as guests (GUESTS.md). The host can list registrations (`GET /v1/webinars/{slug}/registrations`) and close registration. The audit log keeps the email domain only.
- **Q&A:** everyone, in the app or the browser, asks questions and votes them up. Hosts mark them answered. The list shows unanswered questions first, by votes.

## Open gaps
- The join link is shown on screen after registering. Sending it by email waits for a mail connector.
- No HLS or large-scale streaming: attendees join the media server directly, so practical size is what one LiveKit node carries (hundreds, not tens of thousands).
- No Q&A moderation queue (hide, or approve before showing).
