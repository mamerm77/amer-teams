# Arabic and right to left

Phase 3: "Arabic-first experience" and "all strings in ARB files, Arabic and English from day one; layout
mirrors for right-to-left" (docs/PHASE3_REQUIREMENTS.docx).

## Built
- **Security → Language**: System, English, or العربية. The choice is saved on the device.
- **Arabic mirrors the whole app right to left**, through Flutter's localisation: navigation, lists, app bars,
  text fields and icons that have a direction.
- **Flutter's own widgets** (date and time pickers, dialogs, menus, tooltips) appear in Arabic.
- **The app's own text**, translated so far: the navigation, the chat list and its filters, Activity, Catch me
  up, search, sign out and the language setting (`app/lib/services/locale.dart`, `t()`).
- Already in place elsewhere: Arabic decision phrases (DECISIONS.md), prayer-time and Ramadan-aware scheduling
  (FIND_A_TIME.md), Arabic in the translator agent, and messages typed in Arabic render right to left.

## Not yet (open)
- Most screens' own text is still English. Moving every string into ARB files and translating it is a large
  piece of work, done screen by screen. Untranslated text shows in English inside the mirrored layout.
- Hijri dates in the calendar view; Gulf-dialect speech recognition (it depends on the phone's recogniser).

## Tests (in-use, CI)
Switching to Arabic shows the navigation as الأمان and the layout is right to left; switching back to English
restores it.
