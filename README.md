# Kitchen Copilot

A hands-free shift assistant for a Chipotle Kitchen Leader, used through Oakley Meta glasses.

Say **"Hey kitchen, how much chicken do I need for Saturday lunch?"**, pause, and hear the answer in your glasses within a second or two.

```
Oakley Meta glasses ──Bluetooth──▶ iPhone app ──HTTPS──▶ server ──▶ Claude
 (mic + open-ear speakers)         speech→text,           your prompt,
                                   speaks answer          store files, API key
```

- **ios/**: SwiftUI app. Listens on-device for "Hey kitchen" through the glasses' mics, sends the question, and speaks the answer back sentence by sentence as it streams in. Also has a big "Tap to ask" button and voice commands: "rush mode on/off", "start over", "stop".
- **server/**: TypeScript server that holds the system prompt, your store files, and the Claude API key. The key never touches the phone.
- **prompt/system.md**: the assistant's instructions, tuned for being heard rather than read.
- **store/**: your par levels, store profile, and checklists. **Fill in the `[fill in]` placeholders.** This is the biggest thing that makes the AI good for *your* store.

## What makes the answers good

- Uses Claude Opus 5.5 with effort `low` so the first words come fast. Set `KC_EFFORT=medium` if you want deeper prep planning and can wait a little longer.
- The prompt is written for the ear: no lists or symbols, answer first, at most three steps, and kitchen words corrected when speech-to-text mangles them ("bar back over" → barbacoa).
- Store files are injected as the source of truth and cached for an hour, so long questions stay cheap and fast all shift.
- Sends the time of day with every question, so "what should I back up?" knows the lunch rush is coming.
- Food-safety guardrails: it defers to Chipotle standards and Vanessa, and never guesses.
- If a safety filter misfires on a kitchen word (knife, chemical, burn), the request automatically retries on a fallback model instead of failing.

## Setup (on your Mac)

### 1. Run the server locally

```bash
cd server
cp .env.example .env        # then paste your Anthropic API key and set APP_TOKEN
npm install
npm test
npx tsx --env-file=.env src/index.ts
```

Try the AI from the terminal without the phone:

```bash
npx tsx --env-file=.env src/try.ts "someone called out on grill at 11, who moves?"
```

### 2. Build the iPhone app

```bash
brew install xcodegen
cd ios && xcodegen && open KitchenCopilot.xcodeproj
```

In Xcode, choose your Apple ID team under Signing & Capabilities, plug in your iPhone, and press Run. In the app's Settings, enter the server URL and the same `APP_TOKEN`.

For testing on the same Wi-Fi, use your Mac's local name, e.g. `http://Eriks-MacBook-Air.local:8787` (find it in System Settings → General → Sharing → Local hostname). The app allows plain `http` only for `.local` addresses. For real shifts, put the server on HTTPS (step 3), or use Tailscale with `tailscale serve` for a private HTTPS URL.

### 3. Host it for real shifts

The `Dockerfile` runs anywhere (Fly.io, Render, Railway). Set `ANTHROPIC_API_KEY` and `APP_TOKEN` as **secrets** in the host's dashboard. Never commit them.

### 4. On shift

1. Pair your glasses with the iPhone in Bluetooth settings. The app shows the glasses' name at the top when audio is routed to them.
2. Open Kitchen Copilot. You can lock the screen; it keeps listening in the background.
3. Optional: for a much better voice, download a Premium or Enhanced English voice in Settings → Accessibility → Spoken Content → Voices.

## Notes

- "Hey Meta" still goes to Meta AI. This app uses its own wake phrase, "Hey kitchen", heard through the same glasses mics.
- Phase 2 idea: send what the glasses' camera sees ("is this pan low?") using Meta's Wearables Device Access Toolkit. The server already accepts an image (`imageJpegBase64`).
- Ask Vanessa whether using an AI assistant on shift is OK under Chipotle policy. Keep customer and coworker personal info out of `store/`.
