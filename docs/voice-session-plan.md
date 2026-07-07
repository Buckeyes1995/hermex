# Voice Session — Implementation Plan

Closes #36.

## New files
- `HermesMobile/Features/Voice/VoiceSessionViewModel.swift`
- `HermesMobile/Features/Voice/VoiceSessionView.swift`

## Modified files
- `HermesMobile/Features/SessionList/SessionListView.swift` — add mic button FAB alongside the existing Chat FAB
- `HermesMobile.xcodeproj/project.pbxproj` — register new files

---

## State machine (`VoiceSessionViewModel`)

```
idle → listening → sending → streaming → speaking → idle (loop)
         ↓                                              ↑
       cancel ────────────────────────────────────────→ idle
```

- **idle** — tap mic to begin
- **listening** — `SFSpeechRecognizer` running; `isFinal == true` fires auto-send (silence detection is built into Apple's recognizer); mic button tap also stops and sends
- **sending** — transcript POSTed to server (`createSession` on first turn, then reuse); spinner shown
- **streaming** — SSEClient accumulating `.token` events into `currentResponseText`; `.done` fires transition to speaking
- **speaking** — `AVAudioPlayer` playing TTS audio; tap mic button skips ahead to idle
- **error** — banner shown, returns to idle after 3s

---

## `VoiceSessionViewModel` responsibilities

1. Hold `APIClient` (built from the passed-in `server: URL`)
2. Hold `ComposerVoiceInputController` for STT (reuse existing, no new recording plumbing)
3. `sessionID: String?` — nil on first turn, created via `client.createSession(...)` on first send; thereafter reused for the session lifetime
4. `turns: [(user: String, assistant: String)]` — full conversation for transcript display
5. `currentResponseText: String` — accumulates SSE tokens during streaming state
6. `func tapMic()` — main action: starts listening if idle, stops+sends if listening, skips TTS if speaking
7. `func dismiss()` — cancel any in-flight work and close
8. After `SSEEvent.done`: call `synthesizeSpeech`, play audio; on `AVAudioPlayerDelegate.didFinishPlaying` → back to idle

Session creation: call `client.createSession(workspace: nil, model: nil, modelProvider: nil, profile: nil)` on the first send to get a `sessionID`, then pass it to every `startChat` call. The session survives closing the sheet (visible in session list).

---

## `VoiceSessionView` layout

```
┌─────────────────────────┐
│  ✕          Voice       │  ← toolbar
│─────────────────────────│
│                         │
│  [transcript scroll]    │  ← user bubbles right, assistant left
│                         │
│  [streaming text…]      │  ← live response while streaming
│                         │
│  "Listening…"           │  ← status label
│                         │
│       ◉ mic             │  ← large circle button
│                         │
└─────────────────────────┘
```

Mic button visual states:
- **idle** — white mic on dark circle, "Tap to speak"
- **listening** — red, pulsing ring animation, "Listening…"
- **sending/streaming** — spinner replacing icon, "Thinking…"
- **speaking** — waveform icon, "Speaking…", tap to skip

---

## Session list change

Add a second FAB (mic circle icon) to the left of the existing Chat FAB in `SessionListView`. Tapping sets `isPresentingVoiceSession = true` → `.fullScreenCover`.

---

## Out of scope (v1)

- Barge-in / interrupting TTS mid-sentence
- Wake word
- Streaming TTS (play while generating — needs chunked audio API)
- Voice selection / settings toggle
