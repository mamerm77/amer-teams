# Team apps (Microsoft Teams parity)

Amer Teams includes its own versions of Microsoft's built-in Teams apps. As with a Teams tab, each app opens inside a chat or channel, and everyone in that chat shares it.

**Storage.** Every item is an end-to-end encrypted room event of type `com.amerteams.app`, carrying `app`, `kind` and `item_id`. The newest event for an `item_id` wins, and `deleted: true` removes the item. The server stores only ciphertext. Planner is the exception: it uses the chat's existing tasks (`com.amerteams.task`), so tasks created from messages, by decisions, by agents or on the board are all the same tasks.

| Microsoft app | Amer app | What it does |
|---|---|---|
| Planner / Tasks | Planner | Board with To do, In progress, Blocked and Done columns. Assign tasks, set due dates (overdue in red), and move tasks between columns |
| Lists | Lists | Shared tables with column types: text, number, date, choice, person and yes/no. Templates for issues, assets and risks. Filter, sort, edit and delete |
| Forms | Forms | Choice, text and rating questions. One response per person. Live results with counts and averages. Names can be hidden in the results |
| OneNote / Wiki | Notes | Notebook with sections and pages. Headings, bullets and to-dos. Shows who edited a page last |
| Updates | Updates | Recurring check-ins with questions. Shows who has submitted this week and who has not |
| Praise | Praise | Badge and note for a colleague, also posted in the chat, plus a "most praised" list |
| Viva Goals | Goals | Objectives with key results (target and current value), progress check-ins and overall progress |
| Bookings | Bookings | Services with a length and working hours. Free time slots, booking, and cancellation by the person who booked or the staff member |
| Viva Engage | Communities | Discussions, questions with a "best answer", announcements (also posted in the chat), likes and replies |
| Who / org chart | Who | Profile cards (title, department, office, skills, manager), search, and an org chart going up through managers and down to direct reports |
| Stream | Stream | Video library of a chat (recordings and shared videos), decrypted on your device |
| Places | Places | Office, remote or off for each day, desk booking, and who is in the office |
| Milestones | Milestones | Project timeline with dates and status (On track, At risk, Late, Done) |

Already in Amer Teams before this: Approvals, Shifts, Walkie-talkie, Whiteboard, Polls, Workflows, Tasks across chats, and Meeting rooms.

**Not cloned:** Word, Excel, PowerPoint, Visio, Power BI, Power Apps, Dynamics and Azure DevOps. These are separate Microsoft products, not Teams apps. They can be reached through Connectors.

## Channels (Teams parity)
- **Private channels**: invite-only, and visible only to the people chosen. Adding members to the team does not add them to private channels. Private channels show a lock.
- **Favourites and hidden channels**: per person, kept in account data. Favourites sort to the top; hidden channels move into a "Hidden channels" section with a Show button.
- **Moderation**: the owner or an admin can switch it on. Then only moderators start new posts, and everyone can still reply. This is enforced in the app (the posting box is hidden for everyone else), not by the server.
- **Channel meetings**: the channel menu has "Schedule a channel meeting". The meeting is posted in the channel and appears in every member's calendar.
- **Tabs**: "+" adds Planner, Lists, Notes, Forms, Milestones, Goals, Updates or Praise as a tab next to Posts and Files, for everyone in the channel.

## Video, Immersive Reader and Interpreter (Teams parity)
- **Video playback**: videos in Stream and in chats play inside the app, using `media_kit`. The video is decrypted on your device into a temporary file, which is deleted when the player closes.
- **Immersive Reader**: in a message's menu. It shows large text with adjustable size, line spacing and reading speed, plus line focus and a dark page. Read aloud highlights each word as it is spoken. Arabic is shown right to left and read with an Arabic voice. Speech uses the device's own voices, so nothing leaves the device.
- **Interpreter**: in a meeting's More menu. It speaks other people's translated captions aloud in your language, on your device only. The translation itself is the existing translated-captions path, so the same AI rules and labels apply. Unlike Microsoft's Interpreter, it does not lower the speaker's original audio.
- **Read-aloud on Linux**: the speech package has no Linux voices. On Linux, read-aloud and the Interpreter say so plainly, and captions and text still work.
