# UI polish v32 — 11–12 September 2026

## Scope

The four supplied screenshots: peer actions, swipeable media categories, floating feed controls, and rounded profile tabs. Additional chat work is limited to poll layout, read-status strokes and regressions around reaction geometry. Inbox filters, account data and the profile's colourful branding are unchanged.

## Implementation

- Peer actions have local press feedback. Search opens above profile information, scrolls into view, focuses the field, and opens a matching message. Both More menus have distinct accessibility identifiers and align with the other action icons.
- Call actions expose pending work and block duplicate startup requests. An existing direct call is expanded instead of silently ignoring the action. Mute waits for the server result; if the initial state was unavailable, it loads the state before toggling it. Failures use the existing app error presentation.
- Media can be dragged horizontally or selected using the tab buttons. The leading 24 pt remain reserved for Back. Only the current page and a neighbouring page are rendered during a drag. Attachment filtering is outside the per-frame drag state. A swipe suppresses the release-tap on a photo; empty pages retain enough height to keep the media header pinned. Both selected and unselected tabs have an explicit 44 pt hit shape, instead of the inactive target shrinking to its text. Empty-state cards themselves use their content height.
- Feed controls are two separate material capsules over the scrolling feed, not a shared segmented tray. Only the status-bar area is covered; the controls themselves float over the posts. The initial content inset leaves the first items unobscured.
- Profile tabs use capsules for both the track and the selection, with 44 pt button height.
- Polls place the question above the poll type, use regular-weight answers and a thin result bar below each answer. Percentages remain on one line. A selected answer has a check as well as colour. Reaction layout width remains independent of the primary message content.
- Read indicators use a light full/partial vector tick with a fixed footprint; reading-state animation does not resize the message. A layout change from voting/reactions no longer flashes an extra floating date.

## Reference and skills

Inspected Telegram's official iOS client on 11 September 2026:

- [Poll layout](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TelegramUI/Components/Chat/ChatMessagePollBubbleContentNode/Sources/ChatMessagePollBubbleContentNode.swift): minimum option layout height 52 pt, 4 pt result bar, separate percentage and answer columns.
- [Message date/status](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode/Sources/ChatMessageDateAndStatusNode.swift): full and partial check assets, nominal 11 pt checks for a 17 pt base font. Alo's paths are independently drawn, not transplanted client source.
- [Reaction footer](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TelegramUI/Components/Chat/ChatMessageReactionsFooterContentNode/Sources/ChatMessageReactionsFooterContentNode.swift): wrapping is constrained by the available width. Alo retains its previously verified 44 pt touch targets and content-first message sizing.

UI UX Pro Max informed hit areas, selected semantics and the visual check. Apple Design informed local, interruptible press/drag feedback and Reduce Motion/Transparency handling. No continuously running animation, new image dependency or per-frame network work was added. Frame-rate and battery consumption have not been benchmarked on a physical phone.

## Verification boundary

UI tests use explicitly labelled offline fixtures. Call tests verify routing to the coordinator without contacting real people. Mute/poll fixtures are local; they do not demonstrate a production server round trip. The production call, mute and poll API paths remain in place.

This is a local simulator build, not an App Store/TestFlight release and not installed on the user's physical iPhone.

## Final verification — 12 September

`build-v32f.log`: **TEST BUILD SUCCEEDED**. `git diff --check`: clean.

| Run | Device / width | Verified result |
| --- | --- | --- |
| `pro-max-v32f.xcresult` | Pro Max, 440 pt | 3/3 passed: floating feed + profile tabs; five peer actions and focused search; media swipes in both directions, pinned header, edge resistance and dragging the tab bar itself |
| `compact-v32f.xcresult` | Compact simulator, 375 pt | 1/1 passed: the same media swipe sequence and pinned-header assertions |
| `pro-max-v32e.xcresult` | Pro Max, 440 pt | Chat capture, peer actions, sticky media/viewer return and poll voting passed. Its media test failed on the inactive tab's shrunken accessibility/hit frame; fixed and rerun in v32f above |
| `compact-v32e.xcresult` | Compact simulator, 375 pt | Poll voting and reaction counts/wrapping passed; 4 Swift Testing layout tests passed (including 5 phone widths). Its media hit-frame failure was fixed and rerun in v32f |
| `compact-v32d.xcresult` | Compact simulator, 375 pt | 3/3 passed: feed/profile tabs, cancelled Back swipe and return, reaction mutation geometry across five message modes |
| `compact-v32.xcresult` | Compact simulator, 375 pt | 2/2 passed: six message-content/selection modes and four reaction chips fitting the available row |

The final swipe tests keep the header position within 1 pt after changing pages. Poll tests check stable bubble width, revoting and single-line 100%. Reaction regression checks cover addition/removal and 999 → 1,000, keeping chips inside the bubble without changing the primary message dimensions.

No source changes followed the final v32f build; only this report and exported screenshots were added. Automated gesture coverage uses a populated photo page followed by empty video/voice/file pages. Scrubbing a populated voice page while paging, physical-device frame rate, live calls and production server round trips remain outside this verification.

## Actual screenshots

All images below are unedited simulator captures with explicitly labelled test data. Feed/profile/peer/media captures come from v32f; chat/poll captures come from v32e (those layouts were unchanged in v32f).

- [Chat and thin read checks](/Users/mikhail/AloiOS/Design/QA-messenger/v32-final/chat-pro-max.png)
- [Poll after voting](/Users/mikhail/AloiOS/Design/QA-messenger/v32-final/poll-pro-max.png)
- [Floating feed buttons](/Users/mikhail/AloiOS/Design/QA-messenger/v32-final/feed-pro-max.png)
- [Rounded profile tabs](/Users/mikhail/AloiOS/Design/QA-messenger/v32-final/profile-pro-max.png)
- [Peer actions](/Users/mikhail/AloiOS/Design/QA-messenger/v32-final/peer-pro-max.png)
- [Media grid after swiping back](/Users/mikhail/AloiOS/Design/QA-messenger/v32-final/media-pro-max.png)
- [Empty media page with the header still pinned](/Users/mikhail/AloiOS/Design/QA-messenger/v32-final/media-empty-pro-max.png)
