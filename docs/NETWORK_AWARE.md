# Network-aware calls

Every video tile shows a signal icon for that person's connection (excellent, good, poor, lost), with a spoken label.

**Automatic mode** (default; call menu → Network):
1. After 10 seconds of poor connection on your side: **data saver**, with others' video in low quality.
2. After 30 seconds poor, or a lost connection: **audio only**. Others' camera video is paused and yours is switched off. Screen share stays on, since it's usually why you're in the meeting.
3. After 30 seconds of good connection again: back to **full quality**, and your camera comes back on if it was on before.

Each change is shown and announced to screen readers. You can also choose Full quality, Data saver or Audio only yourself, which stops the automatic changes.

This builds on LiveKit's adaptive streaming and dynacast (layers sized to the tile, unused layers paused) and its connection-quality score per participant.

## Open gaps
- Not yet tested on a throttled network in CI; the thresholds (10 s, 30 s) may need tuning from real call traces.
- No pre-call network test, and no "your network is weak" advice before joining.
