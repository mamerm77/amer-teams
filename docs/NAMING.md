# Naming and behaviour standard

One name for each thing, and one rule for each kind of action, everywhere in the app. Names follow Microsoft Teams, so people coming from Teams find things where they expect them. This standard came out of an audit of all 1,672 labels in the app and of the rules behind each feature (20 Nov 2026).

## Glossary: one term per concept
| Concept | The one name | No longer used |
|---|---|---|
| Start a 1:1 or group chat | **New chat** (Ctrl+N) | "New encrypted chat", "Start a chat" |
| Start a meeting now | **Meet now** (`/meet`) | "Start a meeting", "Start meeting" |
| Plan a meeting | **New meeting**; in a channel, **Schedule a channel meeting**; by typing, **Schedule with Amer** | "Schedule a meeting" |
| Keep a chat at the top | **Favourites** (capital F, everywhere) | "Pin to top", "Pinned", "favourites" |
| Put a chat aside | **Hide** (comes back with a new message) / **Unhide**; filter "Hidden" | "Archive" (older archived chats now count as hidden) |
| Fewer notifications from a chat | **Mute (only @mentions notify)** / **Unmute** | — |
| People who run a meeting | **Organiser**, **Co-organiser**, **Presenter**, **Attendee** | "Host" |
| People in chats, channels and teams | **Owner** (power 100), **Moderator** (50), **Member** | "Admin" (which meant 100 in chats and 50 in teams) |
| Change someone's role in a chat | **Make owner**, **Make moderator**, **Make member**, **Remove from chat** | "Make admin", "Remove admin", "Remove from group" |
| Your AI team | **Agent office**, in two parts: **Ask** (quick requests to the Chief of Staff and specialists) and **Projects** (longer work with tools, deliverables and a budget) | "My agent office", "My agents", "My agent team" |
| Administrators' view of all agents | **Agent monitoring** | "Agent Ops" |
| The AI assistant itself | **Amer** | "Amer co-pilot" in new text |
| Everyone in the organisation, org chart, contacts | **People** (tabs: Contacts, Groups, Invitations, Organisation) | the separate "Who" app |
| Find someone by what they know | **Find an expert** | "Who knows about…" |
| Your own details | **My contact details** (one card: email, phone, title, department, office, manager) | details kept per chat in "Who" |
| Settings of a team / of meetings | **Team settings** / **Meeting options** (Teams' own words) | — |
| Status you choose | Available (automatic), Busy, Do not disturb, Be right back, **Appear away**, Appear offline | — |
| Status the app sets | Away, In a call, In a meeting, Presenting, Focusing, Out of office | — |

## Behaviour rules
1. **One source for each fact.** Contact details live on the server contact card. People, Organisation, search and the people picker all read it. Presence is decided only in `availability.dart`. Do not disturb, Focus, Out of office, calls and idle time all report there, and it applies Teams' precedence.
2. **One way to do each thing.** Hide replaces Archive. Favourites replaces Pin. Agent office covers both agent features.
3. **Anything that cannot be undone asks first.** It names the thing and says it cannot be undone. This covers deleting a message, removing someone from a chat, deleting a contact group, cancelling a meeting, and leaving a team. Reversible actions (mute, hide, favourite, move to a section) act at once and say what happened.
4. **Server-enforced where possible.** A rule the server can enforce (Matrix power levels or the orchestrator) is enforced there. Where only the app can enforce it, the screen says "Enforced by the app".
5. **Roles by power level, the same everywhere:** 100 Owner, 50 Moderator, otherwise Member (`services/roles.dart`). Meetings use Teams' own roles.
6. **Distinct icons.** No two apps in Apps share an icon.

## Code conventions behind it
- Shared helpers: `roles.dart` (`roleName`, `confirmDestructive`), `availability.dart` (presence), `app_store.dart` (encrypted app items), `people_picker.dart` (every "add people" box).
- New labels use the glossary terms. When a term changes, update this file, the Help and guide, and the in-use test in the same commit.
