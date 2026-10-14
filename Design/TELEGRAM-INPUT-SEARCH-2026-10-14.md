# Composer and chat-list search — 14 October 2026

Scope: compact chat composer, a shared search field for Search and Chats, and a pull-to-reveal chat-list search. Other separately updated application features were preserved.

## Telegram reference

Read the official Telegram-iOS source at commit `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838`:

- [ChatTextInputPanelNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift): 40 pt microphone/attachment slots; 8 pt outer horizontal insets and 6 pt spacing; regular-font field minimum is its text height plus 5/4 pt vertical insets.
- [ChatTextInputFontMetrics](https://github.com/TelegramMessenger/Telegram-iOS/blob/f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputFontMetrics.swift): regular 17 pt text uses a 31 pt minimum text area, giving a 40 pt field minimum.
- [ChatListNavigationBar](https://github.com/TelegramMessenger/Telegram-iOS/blob/f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838/submodules/TelegramUI/Components/ChatListHeaderComponent/Sources/ChatListNavigationBar.swift): search reveal scroll range is 54 pt.

These are measurements of the cited source, not a claim that every Telegram version or text-size setting uses identical geometry.

## Applied in Alo

- Composer visible surfaces: **40 pt**, with **44 pt touch targets**. The row uses 8 pt outer layout padding and 6 pt layout spacing. The larger invisible button targets add 2 pt to each side of their visible circle; this is an intentional accessibility adaptation, not pixel-identical Telegram placement.
- Single-line input radius: 20 pt. Text uses the existing scalable body font and can grow to five lines. Paperclip, microphone and circle share the compact geometry; the emoji action stays bottom-aligned as the field grows.
- Search and Chats reuse `AloSocialSearchField`: visible minimum 40 pt, touch row minimum 44 pt, horizontal inset 16 pt, title gap 10 pt. The shared utility field grows with Dynamic Type up to 60 pt.
- Chat search is initially above the visible list, even for a one-row list. Pulling down reveals it; scrolling up tucks it away. A release inside the 54 pt range settles to shown or hidden according to the projected native scroll target.
- No competing custom drag recognizer was added. `ScrollPosition` and `ScrollTargetBehavior` keep the native list's momentum. Search activation/cancellation uses a non-bouncy spring and respects system Reduce Motion.
- Activating search preserves the title and field width/position. Cancellation is in the header, not a button that narrows the field. Focus tracks the native text field directly rather than an unattached SwiftUI `FocusState`.
- Comments share the input metric, retaining their own layout and 44 pt send target.

## Verification

- Debug build and selected unit/UI tests passed on iOS 26.2 simulators: iPhone Pro (402 × 874 pt) and iPhone SE (375 × 667 pt).
- Per device: three unit test functions (including seven parameterized snap cases) and three UI tests, all passing.
- UI tests measured rendered field bounds, verified 40 pt composer and 44 pt button targets, voice/circle mode switching, initially hidden search, pull-down reveal, equal Search/Chats field frames, stable position on focus and hiding on cancellation.
- Search tests ran both native glass and the app's forced legacy-glass rendering path. This is not an actual iOS 18 device/runtime test.
- The simulator was using hardware-keyboard input. Focus was verified automatically; a separate manual software-keyboard check was unavailable because the Mac was locked. A physical iPhone installation and visual check remain necessary.
- `git diff --check` passed.

Actual test screenshots (fixture content, not production messages):

- [Compact voice composer](2026-10-14-input-search/composer-40pt-voice.png)
- [Compact circle composer](2026-10-14-input-search/composer-40pt-circle.png)
- [Chats with search tucked away](2026-10-14-input-search/inbox-search-hidden.png)
- [Chats with search focused](2026-10-14-input-search/inbox-search-focused.png)

## Server

Started the current backend with `npm run dev` in `/Users/mikhail/alo`. The Mac's LAN endpoint is `http://192.168.0.19:3000`, matching the current physical-device Debug configuration. `/health/ready` returned HTTP 200 with all readiness checks true. Database, uploaded media, credentials and the existing closed-web-site policy were not changed. No endpoint edit or backend build was necessary: the dev command runs the current JavaScript source directly.
