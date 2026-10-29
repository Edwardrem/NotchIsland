<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="NotchIsland icon">
</p>
<h1 align="center">NotchIsland</h1>
<p align="center">Your MacBook notch, now a Dynamic Island.<br>
<a href="https://edwardrem.github.io/NotchIsland/">Website</a> ·
<a href="https://github.com/Edwardrem/NotchIsland/raw/main/dist/NotchIsland.dmg"><b>Download NotchIsland.dmg</b></a> ·
<a href="https://github.com/Edwardrem/NotchIsland/releases">Releases</a><br>
<sub>Made by <a href="https://www.linkedin.com/in/rufaro-mutepfa-0a64b810a/">Rufaro Edward Mutepfa</a></sub></p>

<p align="center">
  <img src="docs/assets/shade.png" width="420" alt="The NotchIsland shade">
</p>

NotchIsland turns the MacBook notch into a Dynamic Island. The whole UI is one true-black surface
that flows out of the notch (flat top, rounded bottom, one width): compact "ears" when something is
live, a short HUD for live activities, a hover readout, and a click-down shade with a clock, quick
toggles, timer, next event, Now Playing, shelf, clipboard and notifications grouped by app.
⌥ Space opens a Spotlight-style launcher with fuzzy app search, calculator, unit conversion, file
search and quick actions. Free, open source (MIT), macOS 13+, Apple silicon.

## Install

1. Download [NotchIsland.dmg](https://github.com/Edwardrem/NotchIsland/raw/main/dist/NotchIsland.dmg)
   and drag **NotchIsland** into Applications.
2. First launch: the app is signed ad-hoc (no paid Developer ID), so right-click ▸ **Open**. On
   macOS 15+ open it once, then System Settings ▸ Privacy & Security ▸ **Open Anyway**.
3. Grant what you use (see [Permissions](#permissions)). Settings ▸ Permissions shows the state.

## Run from source

```bash
git clone https://github.com/Edwardrem/NotchIsland.git
cd NotchIsland
swift run            # builds and launches
```

Or open `Package.swift` in Xcode and press ⌘R. Requires macOS 13+ and Xcode 15+.
The bare executable embeds its own Info.plist (bundle id `com.notchisland.app`, `LSUIElement`, privacy
usage strings), so permission prompts name the app properly even when it is not in an `.app` bundle.

## Build the app and DMG

```bash
scripts/make-dmg.sh 1.0.0   # release build → dist/NotchIsland.app → dist/NotchIsland.dmg (ad-hoc signed)
```

`Resources/Info.plist` is the bundle template, `Resources/AppIcon.icns` the icon (drawn by
`scripts/icon.swift`). The DMG is committed under `dist/` so the website can link to it directly.

## Feature matrix

Legend: ✅ done · ◐ partial · ✗ not in this build (reason in the notes below).

### Core island behaviour
| Feature | | Notes |
|---|---|---|
| Pixel-accurate notch (width/height from `NSScreen`), flat top, rounded bottom, true black | ✅ | `NotchGeometry`, `IslandSurfaceShape` |
| Hover-to-expand with spring; auto-collapse on leave; configurable hover delay | ✅ | Reduce Motion respected |
| Click opens the full shade | ✅ | Clock header, quick toggles, cards, grouped notifications |
| Drag-into-island detection | ✅ | Island expands with a drop target; files land on the Shelf |
| Every Space, over full-screen apps | ✅ | `canJoinAllSpaces`, `fullScreenAuxiliary`; optional "hide in full screen" |
| Multi-monitor | ◐ | Lives on the notched display; 200 pt stand-in on Macs without a notch |
| Idle / quiet mode | ✅ | Collapsed = just the notch |
| Do Not Disturb / Focus | ◐ | Focus *status* is shown (ears, hover, shade); toggling Focus has no public API |

### Live activities
| Feature | | Notes |
|---|---|---|
| Now Playing: art, title/artist, progress, play/pause/skip, scrubbing | ✅ | Music, Spotify, VLC via AppleScript; Chrome/Brave/Edge via page JavaScript (one-time browser switch, see Permissions) |
| Volume HUD | ◐ | Island shows a volume HUD on change (1 s poll). The stock macOS overlay is **not** suppressed |
| Brightness HUD | ✗ | Needs private CoreDisplay APIs |
| Battery: charger plug/unplug activity, low-battery (20/10/5 %) warnings | ✅ | IOKit power-source notifications |
| Timer / Pomodoro with countdown ring | ✅ | Presets, ring in the ears, chime + activity when done; `timer 25` in the launcher |
| Calendar next event + join link | ✅ | EventKit; Zoom/Meet/Teams/Webex… links get a Join button |
| Notification mirroring | ✅ | Banner in the island + app-grouped shade with history |
| Downloads progress (Safari/Chrome/Finder) | ✅ | Watches `~/Downloads`; Safari gives real %; completion activity. Stale partials ignored |
| Screen recording / mic / camera indicators | ◐ | Mic (CoreAudio) and camera (AVFoundation) ✅; screen recording ✗ (no public signal) |
| AirPods/Bluetooth connect with per-bud battery | ✅ | IOBluetooth connect/disconnect; L/R/Case % from the IO registry |
| Focus mode status | ✅ | |
| Clipboard history | ✅ | Last 25 text items; concealed/transient (password-manager) items skipped |

### Launcher / productivity
| Feature | | Notes |
|---|---|---|
| Fuzzy app search, recent/frequent ranking, keyboard navigation | ✅ | |
| Global hotkey that swallows the keystroke, configurable | ✅ | CGEvent tap when Accessibility is granted; falls back to observe-only monitors |
| Calculator | ✅ | Safe recursive-descent evaluator; ↩ copies |
| Unit conversion | ✅ | length, mass, temperature, volume, speed, data (`5 km to mi`, `100 f in c`) |
| Currency conversion | ✗ | Needs a rates API/key |
| File search | ✅ | Spotlight (`NSMetadataQuery`) from 3+ characters |
| Quick actions: lock, sleep, empty trash | ✅ | plus dark mode, keep-awake, Wi-Fi, mirror, settings |
| Shelf / drop zone, drag out, AirDrop | ✅ | |
| Quick toggles: Dark Mode, Keep Awake, Wi-Fi, Mirror, Focus | ✅ | Focus tile shows the active mode (e.g. "Do Not Disturb") and opens Focus settings; Bluetooth toggle ✗ (private API) |
| Camera mirror / preview | ✅ | In the shade |

### Polish and settings
| Feature | | Notes |
|---|---|---|
| Settings window: per-module toggles, hover delay, hide for apps / full screen | ✅ | Menu bar ▸ Settings… or ⚙ in the shade |
| Launch at login | ✅ | LaunchAgent pointing at the current binary (re-enable after moving/rebuilding elsewhere) |
| Menu bar icon toggle | ✅ | |
| `LSUIElement` (no Dock icon) | ✅ | |
| Haptic / sound feedback option | ✅ | |
| Reduce-motion support | ✅ | Follows the system setting |
| Theming: accent colour; light/dark | ◐ | Accent colour picker ✅; island stays black by design |
| Low CPU footprint | ◐ | Event-driven where macOS allows (power, Bluetooth, WAL file, CoreAudio, KVO); 1 s polls remain for AppleScript players, volume and the notification store |
| Sparkle auto-updates, signed & notarised build | ✗ | Needs a Developer ID and hosting; out of scope for a `swift run` project |

### Hard but differentiating
| Feature | | Notes |
|---|---|---|
| Private MediaRemote for Now Playing from any app | ✗ | Returns nothing to third-party processes on current macOS; the known workaround relays through an Apple-signed binary, which this project does not ship |
| Replacing the system volume HUD | ✗ | Requires suppressing the OSD process |
| Per-app notification capture via the Notification Center database | ✅ | |
| Shortcuts.app integration (custom live activities) | ✅ | Write JSON to `~/Library/Application Support/NotchIsland/activity.json` from a "Run Shell Script" action |

## Use

- **Idle**: the island matches the notch. When something is live it grows ears: album art / timer
  ring / an indicator on the left; level meter / countdown / mic·camera·Focus marks or a download
  ring on the right.
- **Live activity HUD**: volume, charger, low battery, AirPods connected (with battery), download
  started/finished, timer done, custom activities. Tap to dismiss.
- **Hover** → clock and date, Mic/Camera/Focus/Awake chips, battery, a bell with the unread count,
  then the running timer, next event, Now Playing and the last notification.
- **Click** → the shade: clock header, quick toggles (Dark Mode, Keep Awake, Wi-Fi, Mirror, Focus),
  Timer, next event with Join, Now Playing with scrubber and system volume, Shelf, Clipboard, then
  notifications grouped by app with Clear / Clear All. Grabber, Esc or clicking elsewhere closes it.
- **Drag files onto the notch** → they land on the Shelf; drag them out again or AirDrop them.
- **⌥ Space** (configurable) → launcher. Try `12*3+4^2`, `5 km to mi`, `timer 25`, `lock`, `dark`.
- **Shortcuts**: `echo '{"title":"Build done","subtitle":"main · 42s","symbol":"hammer.fill","progress":1,"seconds":5}' > ~/Library/Application\ Support/NotchIsland/activity.json`

## Permissions

| Feature | What it needs |
|---|---|
| Hotkey swallow; browser ⏮ ⏭ (media keys) | **Accessibility** for the binary (`.build/debug/NotchIsland` from `swift run`) |
| Now Playing, volume, dark mode | **Automation** → each player/browser and System Events (asked on first use) |
| Browser Now Playing | Chrome/Brave/Edge: **View ▸ Developer ▸ Allow JavaScript from Apple Events**, once |
| Notifications | Read access to `~/Library/Group Containers/group.com.apple.usernoted/` (Full Disk Access if the island shows the hint) |
| Calendar | Asked when you press **Allow** in the shade |
| Camera mirror | Asked when you first open the mirror |
| Bluetooth connect activity | One-time Bluetooth prompt (deferred a few seconds after launch) |

Settings ▸ Permissions shows the current status with shortcuts to the right System Settings panes.

## How it works

| File | Role |
|---|---|
| `NotchGeometry.swift` | Measures the real notch from `NSScreen` |
| `IslandLayout.swift` | Mode (collapsed / compact / activity / banner / expanded / shade / launcher) → sizes for view and window |
| `NotchPanel.swift` | Borderless, non-activating `NSPanel` above the menu bar, all Spaces, hide-by-policy |
| `DesignSystem.swift` | Shared look: card style, icon badges, buttons, chips, toggle tiles, type scale, semantic tints |
| `NotchView.swift` | The black surface, compact ears, hover content, drop target |
| `ShadeView.swift` | Shade: quick toggles, timer, calendar, media, shelf, clipboard, notifications |
| `LiveActivity.swift` | `ActivityCenter` (HUD + long-running "sticky" activities) and the HUD view |
| `Monitors.swift` | Battery, mic/camera/Focus, Bluetooth, Downloads, Clipboard, custom-activity file, visibility |
| `MediaController.swift` | Music/Spotify/VLC + Chromium browsers, transport, seek, artwork, system volume |
| `MediaViews.swift` | Ears, level meter, media cards, volume slider |
| `NotificationWatcher.swift` | Reads Notification Center's SQLite store (history + WAL watcher) |
| `TimerModule.swift`, `CalendarModule.swift`, `Shelf.swift`, `CameraMirror.swift` | Those modules |
| `LauncherEngine.swift`, `LauncherView.swift` | Fuzzy search, ranking, calculator, units, files, actions |
| `Hotkey.swift`, `MenuBar.swift`, `SettingsWindow.swift`, `Support.swift` | Hotkey tap, status item, settings UI, settings model, theme, feedback, launch-at-login, system actions |
| `Sources/NotchIslandInfoPlist` | Embeds the Info.plist into the executable |

## Developer aids

- `NOTCHISLAND_PREVIEW=shade|expanded|launcher|banner|activity swift run` opens that state on launch.
- `NOTCHISLAND_DEMO=1` swaps the live media, notification and clipboard sources for sample content
  (no personal data), which is how the screenshots in `docs/assets` are made; `NOTCHISLAND_QUERY`
  pre-fills the launcher.
- `NOTCHISLAND_DEBUG=1` logs shade toggles and key-window loss.
- Test notification: `osascript -e 'display notification "body" with title "Title"'`.

## Website

`docs/` is the GitHub Pages site (https://edwardrem.github.io/NotchIsland/): a single `index.html`
with the screenshots in `docs/assets`. The download button points at `dist/NotchIsland.dmg` in this
repository.

## Author

NotchIsland is built and maintained by **Rufaro Edward Mutepfa**.

- GitHub: [@Edwardrem](https://github.com/Edwardrem)
- LinkedIn: [linkedin.com/in/rufaro-mutepfa-0a64b810a](https://www.linkedin.com/in/rufaro-mutepfa-0a64b810a/)

Questions, ideas or bugs: open an [issue](https://github.com/Edwardrem/NotchIsland/issues), or say hello on LinkedIn.

## License

MIT © 2026 Rufaro Edward Mutepfa. See [LICENSE](LICENSE).
