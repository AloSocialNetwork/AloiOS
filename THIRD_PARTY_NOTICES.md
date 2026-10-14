# Third-party notices

## Telegram iOS interaction references

The chat interaction audit references the official Telegram iOS source at
commit `6ad963e5b62d354da79040f388ae2b9132fb17b8`:

- `GlassBackgroundComponent/Sources/TouchEffect.swift`: size-dependent touch
  feedback and lift/release spring parameters.
- `Display/Source/InteractiveTransitionGestureRecognizer.swift`: directional
  intent validation and arbitration with horizontal controls.
- `TelegramUI/Sources/OverlayMediaControllerNode.swift`: direct drag tracking,
  velocity-aware corner docking and interruptible settling.
- `ChatMessageItemImpl/Sources/ChatMessageDateHeader.swift`: compact date header.
- `ChatMessageItemCommon`, `ChatMessageReplyInfoNode`, reply/forward accessory
  panels: dimensions and bounded two-line reply presentation.
- `ChatTextInputMediaRecordingButton` and `TGModernConversationInputMicButton`:
  hold delay, cancellation/locking thresholds and release intent.
- `Camera/Sources/Camera.swift` and `VideoRecorder.swift`: one sample-based
  writer across camera-position changes, preserving the microphone and its
  timestamp timeline. Alo's `ChatCircleRecorder` and `AloCircleSampleWriter`
  are independently written with public AVFoundation APIs; Telegram's camera
  transition compositor and recorder classes are not copied into the project.
- `CallScreen/PrivateCallScreen` and `ButtonGroupView`: call-control dimensions.
- `CallScreen/Components/VideoContainerView`: video-source continuity and
  interrupted video transitions; `ChatMessageContactBubbleContentNode`: contact
  avatar and text-column dimensions. No private video-layer/blur implementation
  from these components is included.
- `ChatMessagePollBubbleContentNode`: percentage-column width and the
  separate 100-percent font size. Alo uses native text rather than copying
  Telegram's percentage-image renderer.
- `ChatControllerNode`, `WallpaperBackgroundNode`, `WallpaperEdgeEffectNodeImpl`
  and `EdgeEffect`: scroll
  edge extents, fixed 80 / 60 pt fade lengths and a compact sampling of the
  normalized opacity profile. Alo's dark chat edges use the black overlay from
  the inverted-pattern branch, with one masked scrim, not stacked dark
  materials. Its 68% opacity and 28 / 16 pt inward extensions are a lighter,
  more compact user-requested adaptation. Alo does not duplicate Telegram's
  wallpaper inversion model.
  Glass controls and modal scrims separately use public `UIVisualEffectView`;
  Telegram's private variable-blur filter and wallpaper-clone classes are not
  included.
- `ChatHistoryNavigationButtonNode`: 40 pt down button, 20 pt badge placed
  7 pt above its top; `ReactionButtonListComponent` and
  `ChatMessageReactionsFooterContentNode`: 30 pt reaction surface and 6 pt
  visual row spacing. Alo keeps a separate 44 pt accessible touch target.
- `ContextControllerImpl/ContextActionNode`, `ContextActionsContainerNode`
  and `ContextControllerExtractedPresentationNode`: 16 / 12 pt action insets,
  250 pt baseline action-list width, source-relative placement and a 0.42 s
  damped presentation spring. `ReactionSelectionNode/ReactionContextNode`:
  46 pt compact panel and adaptive reaction slots. Alo's implementation is
  independently written SwiftUI, not Telegram's extractable-node, portal,
  private backdrop or emoji-pack renderer.

Source: https://github.com/TelegramMessenger/Telegram-iOS

Alo implements these mechanics with its own SwiftUI/UIKit components and
public Apple APIs. Telegram's component/dependency graph, private backdrop
APIs, artwork, logo and networking implementation are not included.

This attribution is not permission to redistribute copied Telegram source
without its applicable license requirements.

The 2026-10-13 overlay-media comparison additionally uses official commit
`6e370e06d147b091b07903071cb1b8a22152492d`, specifically
`OverlayMediaControllerNode`, `OverlayInstantVideoNode`,
`InteractiveTransitionGestureRecognizer` and `NavigationTransitionCoordinator`.
Alo's independently written floating-circle release policy reflects direction
into one canonical corner, using the reference's 500 pt/s threshold, 30-degree
directional tolerance, 4 pt inset and 120/150 pt overlay sizing. The source's
four branch implementations are not copied verbatim. Playback surface ownership
and interruptible UIKit settling remain Alo implementations.

## Alo original chat wallpaper

`AloiOS/Assets.xcassets/AloChatPattern.imageset/alo_chat_pattern.png` is
generated locally from `Design/AloChatWallpaper.svg`.

The vector artwork is an original Alo composition of abstract network routes,
orbits and cards. It does not contain Telegram artwork, Telegram source code or
other third-party pattern material. It is covered by this repository's license.

## Signal libsignal

The client uses `LibSignalClient` from the Signal `libsignal` project for
identity keys, sessions, prekeys and message encryption.

Source: https://github.com/signalapp/libsignal

Version: `0.97.1`

License: AGPL-3.0-only.

## WebRTC

Audio, video and screen-sharing transport uses the prebuilt `WebRTC-SDK`
package.

Source: https://github.com/webrtc-sdk/Specs

Version: `144.7559.10`

License: BSD; see `Pods/WebRTC-SDK/WebRTC.xcframework/LICENSE` after
dependency installation for the complete notice.
