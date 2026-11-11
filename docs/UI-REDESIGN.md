# Native app UI and UX redesign

Map Lock is a daily learning tool. The interface should make starting a session easy,
keep the map readable, and distinguish a voluntary practice session from a screen-locking quiz.
This redesign applies to the SwiftUI Mac app. The independently deployed browser demo
and marketing Worker are outside this change.

| Area | Finding | Implemented choice |
| --- | --- | --- |
| Visual system | Translucent cards, colored glows, and heavy shadows compete with the map. | Solid adaptive surfaces, a restrained green/slate palette, quieter elevation, consistent headings and spacing. |
| Navigation | A small default window hides much of setup; the toolbar action does not explain that it locks the screen. | A larger screen-fitted default window, branded native sidebar, and an explicit “Unlock quiz” toolbar action with explanatory help. Existing saved window sizes are respected. |
| Practice | Many stacked choices push Start out of view. | Three numbered steps: destination, subject/method, pace. A persistent footer shows the selected session and Start; ⌘Return starts practice. It adapts to the 680 × 460 minimum window. |
| Selection | Selected regions rely on a solid color change. | Region cards include explicit selected checks; answer methods use radio indicators and a quiet selected background. |
| Quizzes | Progress is overlaid in the middle of a header that also contains variable-width labels. Click prompts sit below the map. | Separate status and progress rows; click prompts above the map; more prominent question text; quieter answer cards; textual and symbolic feedback. |
| Speedruns and results | The map precedes the country to find; results lack consistent visual hierarchy. | Country prompt above the map, explicit completion label, shared result surfaces and actions. |
| Races | Creating and joining compete visually; the waiting state offers little guidance. | Destination-oriented introduction, stronger Create action, explicit Join section and race-settings label, actionable waiting copy, accessible invite/progress controls, and a clearer result header. |
| Stats | Empty sections describe missing data without giving a next step. | Overview heading, stronger primary metrics, a first-session empty state with a Practice action, and accurate sync copy. |
| Account and friends | Generic sign-in heading; account-free capabilities are overstated; icon actions lack labels. | State-specific sign-in/create-account headings, accurate account benefits, clearer friend instructions, labeled actions, and an actionable leaderboard empty state. |
| Settings | Scheduling, quiz content, appearance, and deletion share one long form. | Three categories: Quizzes, App & appearance, Your data. Existing native controls, immediate saving, and destructive confirmations remain. |
| Custom sets | “Type” does not explain that it searches; empty search feedback is terse. | “Search countries,” clearer search/empty-state copy, a labeled clear action, and reduced-motion-aware transitions. |
| Accessibility | Custom click surfaces are not consistently native buttons. | Native Button semantics around first-click targets, disabled-state propagation, explicit selected states and progress labels, hidden background content behind quiz dialogs, and broader Reduce Motion support. |

## Validation

The `macOS app checks` workflow builds the real app, runs the palette contrast check,
and runs the existing quiz, stats, speedrun, account, zoom, and app-move checks.
The palette check enforces 4.5:1 text contrast (including accent text) and 3:1 land/sea
contrast in both themes; existing informational exceptions for certain map feedback
pairs remain, with outlines and symbols supplying additional cues.

`./check-ui.sh /tmp/map-lock-ui` builds an isolated native preview executable and captures
actual SwiftUI screens in both appearances, including compact practice, quiz prompts,
and answer feedback. It does not start the app delegate, screen locks, schedule timers,
or update checks. It substitutes an inert keychain implementation and uses isolated
model stores. The workflow uploads the PNGs as `native-ui-previews`.

CI also exposed two existing verification problems fixed here: mixed Double/CGFloat
arithmetic in a map-feedback animation, and portable checks missing the custom-set
storage dependency. Storage has been moved unchanged to a Foundation-only file so
those checks can compile without SwiftUI.

## Manual release checks

Native captures and compilation do not replace interactive testing. Before shipping:

- Test Tab/Shift-Tab, Space, ⌘Return, answer shortcuts 1–4, Return, and Escape with Full Keyboard Access; inspect controls in VoiceOver.
- Resize home and quiz windows, including 680 × 460 home; scroll every practice step and each settings category.
- Switch light/dark/system appearance and enable Reduce Motion.
- Exercise custom-set editing, empty sets, each subject and answer method, correct/incorrect answers, result and emergency-exit dialogs.
- With two test accounts, verify sign-in, friends, race creation/joining, disconnection, completion, rematch, and syncing. No live account mutation is part of the preview harness.
- Verify unlock/wake/scheduled quizzes on a Mac and ensure Emergency skip remains reachable.
