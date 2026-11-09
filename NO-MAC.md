# Kitchen Copilot without a Mac

You only need your iPhone and a web browser. Two parts:

1. **Server in the cloud.** Set up once from a browser and it runs 24/7. About $5 a month on Railway, plus Claude usage.
2. **An iPhone Shortcut** called "Kitchen" that listens, asks the server, and speaks the answer through your glasses.

The glasses can't run their own apps, so the phone always sits in the middle. A Shortcut is the simplest way to do that.

---

## Part 1: Put the server online (Railway)

1. Go to **railway.com** → sign in with GitHub.
2. **New Project** → **Deploy from GitHub repo** → choose **kitchen-copilot**. Railway finds the `Dockerfile` by itself.
3. Open the service → **Variables** → add:
   - `ANTHROPIC_API_KEY` = your key from console.anthropic.com → API Keys
   - `APP_TOKEN` = a long random password, 24+ characters. On iPhone: Passwords app → **+** → let it suggest a strong password, copy it.
   - `KC_EFFORT` = `low`
4. **Settings** → **Networking** → **Generate Domain**. You get an address like `https://kitchen-copilot-production.up.railway.app`.
5. Check it: open `https://YOUR-ADDRESS/health` in Safari. You should see `"ok":true` and your two store files.

Every time you edit the `store/` files on github.com, Railway redeploys by itself in about a minute.

## Part 2: Build the "Kitchen" Shortcut (on your iPhone)

Open the **Shortcuts** app → **+** (new shortcut) → name it **Kitchen**. Add these 3 actions in order:

1. **Dictate Text**
   - Language: English (US)
   - Stop Listening: **After Pause**

2. **Get Contents of URL**
   - URL: `https://YOUR-ADDRESS/ask/text`
   - Tap **Show More**:
     - Method: **POST**
     - Headers → **Add new header**: Key `Authorization`, Value `Bearer YOUR-APP-TOKEN` (the word Bearer, a space, then the token)
     - Request Body: **JSON** → **Add new field** → **Text**: Key `question`, Value: tap and choose the **Dictated Text** variable

3. **Speak Text**
   - Text: the **Contents of URL** variable (it usually fills this in by itself)
   - Optional: tap the arrow to raise the rate a little so it talks faster

Tap **Done**.

## Using it on shift

- **"Hey Siri, Kitchen"**, then ask your question and pause. The answer plays through whatever Bluetooth audio is connected, which is your glasses when they're paired.
- **Back Tap:** Settings → Accessibility → Touch → **Back Tap** → Double Tap → **Kitchen**. Double-tap the back of your phone in your pocket or apron to ask.
- **Action Button** (iPhone 15 Pro and newer): Settings → Action Button → Shortcut → **Kitchen**.
- **Rush mode:** duplicate the shortcut as **"Kitchen Rush"**. In its JSON body add a field: **Boolean**, key `rush`, value **True**.

### Good to know

- "Hey Meta" still goes to Meta AI. This uses Siri and your Shortcut. Test whether Siri hears you better through the glasses or the phone in a loud kitchen.
- Each question is separate. The Shortcut doesn't remember the previous one, so include the details ("we have 5 people, grill called out").
- The server fills in the current Illinois day and time on every question, so it knows when the rush is coming.
- The full iPhone app in `ios/` (wake word, conversation memory, faster spoken replies) can be built later without a Mac using a cloud build service and TestFlight. That needs an Apple Developer account ($99 a year).
