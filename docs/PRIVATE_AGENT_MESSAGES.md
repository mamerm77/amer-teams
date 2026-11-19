# Agent messages visible to one user

Messages in a chat are encrypted to every member, so a private agent answer can't sit in the shared chat. Instead it is stored in your own end-to-end encrypted room, **"Amer · only you"**, whose only member is you, so only your devices hold its keys. Each note records which chat it belongs to.

In that chat, it shows inline above the messages as **"Amer · only you can see this"**, on every one of your devices, with **Share in chat** (posts it as a normal message) and **Dismiss** (redacts the note). `/ask` answers go there.

The app refuses to write a note if your private room has gained another member or lost encryption.

## Open gaps
- Meeting answers ("Ask Amer" in a call), pre-mortems and skill results still open as private sheets on the asking device; they aren't yet saved as notes.
- At most three notes show per chat, newest first.
