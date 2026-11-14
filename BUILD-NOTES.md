# Pip build notes

## 0.5 (7)

What to Test:

1. If Pip's suggestions don't show in other apps, the bar now tells you why. Also see Pip > Account > Keyboard status.

## 0.5 (6)

What to Test:

1. Explain and Draw it: type a question such as "explain compued interest" or "how do mortgages work". The bar shows the answer and a Draw it chip, even with typos. Tap Draw it to open the drawing straight away.
2. Smarter bar: when you stop typing, Pip reads the sentence and picks the right chip: explain, calendar, reminder, note, chart or pay. Plain chat like "hey how are you" shows nothing.
3. Private by default: if a line holds a password, a key, a seed phrase, a code or a card number, nothing goes to the server. The bar shows one quiet line: "Sensitive text detected. AI is off." Typing and sending work as normal.
4. USDT and other token names, ALL-CAPS words, words with numbers and wallet addresses are never autocorrected or "fixed".
5. Fix no longer shows a "Fixed" line. Press delete right after a Fix to undo it.

## 0.3 (4)

What to Test:

1. Setup: open Pip after install. The steps now see on their own when Pip Keyboard is added and when Full Access is on.
2. Panels: every keyboard panel has an X (close) button at the top. Its buttons sit above the globe row, so you can always reach them.
3. Draw it: every explain answer has a Draw it button. Tap it to see the answer drawn.
4. Wallet: on Home, tap "Create your NEAR wallet". One tap makes it. If it fails, Pip says why and offers Retry.
5. Smoother: Home and Shortcuts open and scroll without lag.
6. Pay on NEAR testnet works as before (play money).
7. Cross-chain pay is not in the app yet. It comes in the next build.

## 0.2 (3)

What to Test:

1. New Pip: Pip is now a calm work helper. Home shows helper actions. Meanings are still there as one tool.
2. Calendar: in any chat, tap the calendar button on the Pip bar. You see your day and the month. Try New event and Share a time.
3. Private AI: replies made inside NEAR AI's secure hardware show a small Private mark. Tap Private AI on Home to see the proof.
4. Pay on NEAR testnet (play money): open Pip, tap Pip Pay, then Set up Pip Pay. Pip makes a key on this phone. Copy your account id and get free testnet NEAR from a faucet.
5. Type to pay: in any chat, type "send 0.01 NEAR to <account>.testnet". Tap the pay chip. A new person opens Pip first. Face ID signs the payment on your phone.
6. Mainnet: when the switch shows in Pip Pay, Mainnet means real money. Pip shows a warning. Please do not send real money in this test.
7. Log out keeps your Pip Pay key on this phone. "Remove wallet from this phone" deletes it, after a warning with your balance. There is no backup: a deleted key means lost funds.
8. Rewrite still works: tap rewrite, and each tone shows as soon as it is ready.

## 0.1 (2)

What to Test:

1. Typing: Pip suggests words above the keys and fixes small typos as you type.
2. Haptics: keys tap softly. Turn this on or off on the Home screen.
3. Cursor: hold the space bar and slide to move the cursor.
4. Accents: long-press a letter (like e or a) to pick an accent.
5. New line: hold Return to add a new line.
6. Quick answers: type a sum, a tip, a split, a unit, a time zone or a currency. Try "split 120 4 ways" or "100 usd to inr".
7. Chips: each suggestion chip has a ✕. Tap it to hide the chip.
8. Rewrite: tap rewrite. All tones show, and each one appears as soon as it is ready.
9. Quiet: type "why is the bus late". Pip stays quiet and shows nothing.

## 0.1 (1): first TestFlight

What to Test:

Pip is a keyboard. After install, open the app and follow the steps to add Pip Keyboard and turn on Full Access.

1. Meanings: in any chat, type "btw?" or "tbh?". The meaning shows on the bar at once, even offline.
2. Explain: type "explain log function". Pip draws it step by step in the keyboard.
3. Charts: type "bar chart: rent 1200, food 400". Pip draws the chart. There is no speaker button in this build.
4. One-tap Send: after a drawing, tap Send. Pip types a short caption and a link. The chat shows the link as a picture.
5. Sign in with Apple. Email sign-in is off until the email service is set up.
6. Log out: it wipes everything Pip keeps on the phone, in the app and in the keyboard.
7. Delete account: it removes your account and data from the server. You can sign in again as a new user.
## 0.4

Pip 0.4: pay any top token to any chain from the keyboard, through NEAR Intents.

1. Wallet: open Pip, go to Pip Pay, tap Create wallet. Switch to Mainnet only if you want to try real money (small limits: 2 NEAR or 10 USDC per payment).
2. Same-chain (testnet): in any chat type "send 0.01 NEAR to <name>.testnet". Approve in the keyboard with Face ID.
3. Cross-chain (mainnet only): type "send 1 USDC to 0x... on base". The card shows exactly what they get, the most you pay, the fee, the route and time. Approve with Face ID in the keyboard.
4. New address: you see "First time paying this address" and pick its last 4 characters before Face ID.
5. If the price changes, you see "Price updated" and approve again.
6. After sending: watch "Swapping..." turn into "Sent". If it fails, it says refunded.
7. Also check: the fixes from 0.3 (onboarding, close buttons, Draw it, wallet).
## 0.6

Pip 0.6

1. Voice: open Pip, tap Voice on Home. Pick a voice and tap Play sample (it only plays when you tap). For the best sound, download Ava or Zoe (Premium) in iPhone Settings > Accessibility > Spoken Content > Voices.
2. Payments: typing or pasting an account like name.testnet no longer flips to "Sensitive text detected". Try: send 0.02 near to pipfundmwg9zj4l.testnet
3. A wrong ending like .mainnet now says: NEAR accounts end in .near (mainnet) or .testnet.
4. Passwords and keys still turn AI off (the lock shows after you finish the word).
## 0.7

Pip 0.7: approve payments in the keyboard

1. Open Pip > Pip Pay > Payment PIN. Set a 6-digit PIN (asks Face ID in the app).
2. In Messages: send 0.02 near to pipfundmwg9zj4l.testnet (paste the address). Tap Approve.
3. If Face ID can't run in the keyboard, the card says why and shows Pip's PIN pad. Enter your PIN to send.
4. Or tap "Approve in Pip" to approve in the app with Face ID.
5. Payment card and Sent screen are readable in dark mode now.
6. If it still fails: Pip > Account > Keyboard status, screenshot it.
