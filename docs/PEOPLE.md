# People, contacts and invitations (Microsoft Teams parity)

## Finding people
Every "Add people" box (new chat, add to a team or channel, call someone, invite to a meeting) searches everyone on your server by **name, username, email, phone, job title or department**. Before you type, it shows your **contact groups** ("Add all" adds every member) and your **contacts**, favourites first.

## Your contact card
People → **My contact details**: work email, phone, job title, department and office. Colleagues find you by these, and they appear on your card. An email address that is not valid is refused, and phone numbers are stored as digits.

## Contacts and contact groups
People → **Contacts**: add people you work with often, mark favourites, remove contacts, or start a chat. People → **Groups**: named groups of contacts (for example "Optical team") that you can add to a chat, team, call or meeting in one step, or turn into a group chat. Contacts and groups are private to you.

## Inviting someone who has no account
Type an email address or phone number in any "Add people" box and choose **Invite … to Amer Teams**, or use People → **Invite someone new**.
- The server creates a **one-time sign-up link**, valid for 14 days (`PEOPLE_INVITE_DAYS`). If SMTP is configured (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`), the link is emailed. Either way, the app shows a ready message to copy and send by email, WhatsApp or SMS.
- The person opens the link in any browser (`/welcome`), chooses a username and password, and the account is created. The link cannot be used a second time.
- They become your contact and you become theirs, and their email goes on their profile.
- If you invited them from a team or chat, **your app adds them** to that team (with its channels) or chat as soon as they have joined. The app checks on start and every 2 minutes. The invitation comes from you, so it stays end-to-end encrypted.
- People → **Invitations** shows each invitation as pending, joined or expired. You can cancel a pending one.
- You can only invite people into teams and chats you belong to. An email that already has an account is refused ("search for them instead"). There is a limit of 50 invitations per person per day. To allow only admins to invite, set `PEOPLE_INVITE=admins`.
- Every invitation and every sign-up is recorded in the audit log.

Tests: `tests/people_test.py` (10 checks on the real stack).
