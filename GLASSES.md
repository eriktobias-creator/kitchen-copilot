# Using the Oakley Meta glasses directly (Meta toolkit)

With this set up:

- **"Hey Meta, start Kitchen Copilot"** opens the app.
- **Press the capture button** on the glasses, then ask your question.
- Or say **"Hey kitchen, ..."** any time the app is open.
- The glasses' own mics and speech recognition hear you. Answers play through the glasses' speakers.

It uses Meta's Wearables Device Access Toolkit v1.0.1. Speech, the capture button, and "Hey Meta" launch are **experimental**: they work with Developer Mode on for your own use, but can't be published for other people yet. The camera ("look at this pan") is a later step.

You need a Mac with **Xcode 26.4 or newer** to build. With a free Apple ID, the app stops opening after 7 days and must be reinstalled from Xcode. A paid Apple Developer account ($99 a year) removes that limit and allows TestFlight and cloud builds.

## One-time setup

### 1. Turn on Developer Mode for your glasses
In the **Meta AI** app: Settings → your glasses → **Developer Mode** → on.

### 2. Register the app with Meta
1. Go to **wearables.developer.meta.com** and sign in.
2. Create a project and add an iOS app with your bundle ID. It's `com.YOURNAME.kitchencopilot.KitchenCopilot` once you change `example` in `ios/project.yml`.
3. Turn on these capabilities for the app: **Speech**, **Inputs**, and **Voice Invocation**. For Voice Invocation, set the spoken app name to **Kitchen Copilot**.

### 3. Build
```bash
cd ~/kitchen-copilot && git pull
```
```bash
cd ios && xcodegen && open KitchenCopilot.xcodeproj
```
Xcode downloads Meta's package the first time, which takes a minute. Pick your Team under Signing & Capabilities, select your iPhone, and press ▶.

### 4. Connect in the app
1. Open Kitchen Copilot → Settings (gear) → **Connect glasses**. It switches to Meta AI. Approve, and it comes back.
2. Tap **Allow glasses microphone** and approve in Meta AI (choose **Allow always**).
3. Status should read **Ready**, and the top of the main screen shows **Glasses mic**.

## On shift
- "Hey Meta, start Kitchen Copilot" → it says "Kitchen Copilot is ready."
- Press the capture button, hear the tone, then ask. It answers when you finish your sentence.
- Press the capture button while it's talking to stop it.
- If the glasses aren't connected or the mic isn't allowed, it falls back to the phone's mic and "Hey kitchen" automatically.

## Building with Claude Code on your Mac
Meta publishes Claude Code plugins with the toolkit's docs. If you use Claude Code on the Mac:
```bash
claude plugin marketplace add meta/meta-wearables-dat-ios
```
```bash
claude plugin install mwdat-ios@mwdat-ios-marketplace
```

## If something's off
- **"Speech and Inputs aren't enabled"**: turn them on for the app in Wearables Developer Center (step 2).
- **Stuck on "Connecting"**: open the glasses' hinges, put them on, and check that Meta AI shows them connected.
- **"The glasses need an update"**: the app opens Meta AI; update the glasses there.
- **The capture button also takes a photo**: Meta's own sample notes this hasn't been confirmed either way on real glasses. Tell me what happens.
