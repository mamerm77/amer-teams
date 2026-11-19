# Modern 3D UI, with 2.5D and flat fallbacks

Settings → Accessibility → **Look**: Automatic, 3D, 2.5D or Flat (`app/lib/ui/depth.dart`).

| Mode | What you see | Used automatically |
|---|---|---|
| **3D** | Cards tilt towards the pointer with real perspective, and a soft highlight follows it; shadows move with the tilt; pages turn in depth when you open them | Desktop and web (pointer) |
| **2.5D** | Layered cards with a directional, offset shadow and no motion | Phones and tablets |
| **Flat** | Outlined cards, no shadows, a plain fade between pages | Whenever reduced motion or high contrast is on (system or app setting), whatever else is chosen |

The depth cards are used for the dashboards and summaries: usage analytics tiles, focus and wellbeing, catch-up, the meeting twin and the Amer co-pilot panel. Card elevation and shape across the app follow the mode through the theme.

## Open gaps
- Chat bubbles and lists stay flat in every mode, for reading speed.
- No WebGL or 3D scenes (for example, a 3D network map); the depth is built with Flutter transforms, so it runs everywhere without a GPU feature check.
- Not yet measured for frame rate on low-end Android in 3D mode (it is 2.5D there by default).
