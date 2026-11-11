# Changelog

## 1.3.16

- Trackpad swipes that change Space are blocked while a lock quiz is up, including on macOS 26. Map Lock asks for Accessibility access so it can stop the swipe. The previous trackpad setting still comes back when the quiz closes.

## 1.3.15

- While a lock quiz is up, trackpad swipes that change Space or open Mission Control and App Exposé are turned off. The previous setting is saved first and put back when the quiz closes, or the next time Map Lock opens if it quit during the quiz. The switch is in Settings.

## 1.3.14

- Rematch is a shared vote. The results button shows Rematch (1/2) after the first player taps it, either player can cancel, and both start the next race together when everyone has voted. If the other player leaves, the rematch stops.

## 1.3.13

- The lock quiz is an accessory panel, so it can appear on top of a fullscreen app after wake. The Dock icon comes back when the quiz closes.

## 1.3.12

- After wake or unlock, the lock quiz appears on a fullscreen app's Space, not only on the desktop behind it.

## 1.3.11

- Waking the Mac no longer crashes Map Lock while the lock quiz is coming on screen, and finishing the quiz still clears the full-screen cover.

## 1.3.10

- Finishing the lock quiz closes the full-screen cover. It no longer stays on the desktop as a blank window.

## 1.3.9

- Finishing the unlock quiz and choosing Back to desktop leaves the desktop. A dismissed lock cannot come back as an empty white screen.

## 1.3.8

- Microstate dots follow the country they stand for: white once found, the same hover and correct or wrong flash, then green again on the next quiz.
- After the Mac wakes or unlocks, the lock quiz covers the current Space, including a fullscreen app, on every display. Switching Spaces does not leave the quiz behind.

## 1.3.7

- Reset stats is in Settings and in the Stats tab menu. It clears practice and unlock scores, the streak, the unlock round, and personal bests on this Mac and, when you are signed in, on your account. Race history and friends stay.
- Race and friend status notes fade on their own. A success such as an invite turns green and leaves after a few seconds. Errors stay red a little longer.
- The race waiting card is solid, with the code, an equal Copy link and Share, an inline invite list, and Cancel at the bottom. The cursor label hides while that card is up.
- Race is its own sidebar tab for the race card and a one-tap challenge list. Friends and the leaderboard are on Account.
- With a custom set of at least 2 countries, unlock can turn every continent off and quiz only that set. Continents you leave on are included too.
- Home panes no longer scroll underneath the toolbar buttons. The scroll views start below that band.
- The custom country picker can cancel and restore the previous set. Search results only open while you type, and the continent buttons and chips are no longer cut off.
- The custom country picker keeps a fixed size. Search shows a flag, the continent, and a check when a country is already in the set. Chips wrap. Saved sets are a menu. Pick on map fades to the continent you choose.
- Race challenges sit in a 320pt card at the bottom-right, with a countdown bar and equal Accept and Decline buttons. Esc or the close button declines.
- Race waiting, declined, and results screens use the same card, type, and spacing.

## 1.3.6

- Custom place: pick individual countries, or add a whole continent, and save named sets. Practice, speedrun, unlock, and races can use that list. The map fits those countries and dims the rest.
- A race challenge slides in at the bottom-right of whichever window is in front, including during a quiz. Accept joins. Decline cancels the race for the sender when nobody else has joined.
- The custom country picker can also pick on the map: click a country to add or remove it, and fit the map to a continent.

## 1.3.5

- Challenging a friend from the Friends list creates the race and invites them. They get a notification on their Mac, with Join and Decline, even if Map Lock is in the background.
- The same invite shows at the top of the Race tab. You can also invite a friend from the waiting screen. The code still works if you want to send it yourself.
- A 1v1 race keeps going after the first person finishes. They see their time and the other player's progress. If you leave, the result shows up later under Recent races.
- The results card shows both times, the margin, and a rematch that invites the same friend.
- The "Click on" label next to the pointer is smaller and sits just to the right of the cursor.

## 1.3.4

- Microstate dots stay above neighboring countries. Highlighting Malaysia, marking it found, or the correct-answer glow no longer covers Singapore's dot. The label by the pointer and the rising name still sit above the dots.
- The website badge reads the latest version from the update feed. That change is the site only.

## 1.3.3

- Unlock stats count each question by its continent, instead of filing mixed quizzes under Several regions or Other. Older unlock quizzes stay out of that table until new ones are saved.
- Unlock also lists Capitals and Flags when those quizzes are stored.
- The label next to the pointer is smaller, so it covers less of the map.

## 1.3.2

- Click-the-map questions show a small "Click on …" label next to the pointer. Flag mode shows the flag without the country name. Turn it off in Settings.
- Stats no longer files quizzes under Unknown. Each one is labeled with its place, and older saved quizzes are filled in when the countries or the question count make the place clear.

## 1.3.1

- Friend requests show up for the person who was asked, with a badge and a notification. Friends refreshes when you open it, when you sync, and while that tab is open.
- If you each send a request, you become friends right away.
- The Race a friend card uses region chips, and Options opens when you click the whole row.
- The person who created a race can cancel it before anyone joins. The code stops working.

## 1.3.0

- Map Lock can update itself. On the second launch it asks whether to check automatically. Check for Updates… is in the app menu, under About.

## 1.2.1

- Copy confirms with a green Copied check, and the race code pulses. Reduce Motion keeps the confirmation and skips the bounce.
- Home panes stay out of the toolbar. Scrolled text goes behind a solid bar with a hairline.

## 1.2.0

- Speedrun mode: time yourself across a continent or the whole world, with personal bests.
- Optional accounts. Sign in with Apple, or with a username and password.
- Friends, a speedrun leaderboard, and live 1v1 races.
- Seterra-style answer feedback. A correct country turns white and its name rises. A wrong click flashes.
- Fixes for the first-click freeze, click targets, the account layout, and a fairer speedrun clock.
