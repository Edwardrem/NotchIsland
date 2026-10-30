# Changelog

## 1.1.1 · 2026-10-30

### Fixed
- Permissions that System Settings showed as allowed did not apply, and every restart or update
  looked as if it had lost them. macOS ties each grant to the signature of the build that asked for
  it. A grant made to 1.0.0 (signed ad hoc, so a different app to macOS after every build) or to a
  `swift run` binary never matches the signed releases, yet System Settings keeps listing it
  switched on, and flipping the switch does not refresh the stored requirement. NotchIsland now
  repairs this itself: on the first launch of a build with a different signature it removes its
  stale entries (`tccutil reset`) and asks for Accessibility again. Settings ▸ Permissions marks a
  grant that was there before and no longer applies, offers **Allow…** and **Reset…** per row,
  explains the leftover development entries (the ones with a terminal icon), and has **Reset All
  Permissions…** for Automation, Bluetooth and Camera.
- Accessibility granted while the app was running was not used until a relaunch: the hotkey kept
  its observe-only fallback. The CGEvent tap is now re-armed within three seconds of a change (and
  dropped again if the grant goes away).
- The app never asked for Accessibility, it only checked. **Allow…** in Settings and the first
  launch after an update now show the system dialog.

### Changed
- `scripts/make-dmg.sh` refuses to sign a release with a certificate other than the one recorded in
  `Resources/release-identity.sha1` (the hash macOS stores with every grant) unless `NEW_IDENTITY=1`,
  and refuses an ad-hoc build unless `ALLOW_ADHOC=1`. `scripts/signing-identity.sh --fingerprint`
  prints the current certificate. Either slip would make every user grant everything again.
- Settings ▸ Permissions ▸ About names the signing certificate and what it means for grants.

## 1.1.0 · 2026-10-29

### Fixed
- The island stuck on one browser while another one played. The browser status script stopped at
  the first tab with any media element, even a paused preview (YouTube's home page keeps one), so
  a tab playing further along the tab strip was never seen and the island stayed on whatever it
  had shown before. Every tab is now read and every stream is reported.

### Added
- Multiple sources. Every player and every browser tab with media is a stream. The island follows
  the one that started playing most recently (audible before muted), stays on the current one
  while nothing plays, and lists the others as chips in the media card. Tap a chip to switch; the
  choice holds until a new stream starts. Clicking the artwork of a browser stream jumps to its tab.
- Safari, and every Chromium browser next to Chrome, Brave and Edge: Arc, Vivaldi, Opera, Opera GX,
  Chromium and the beta/dev/canary channels. Safari needs Develop ▸ Developer Settings ▸ Allow
  JavaScript from Apple Events (turn on *Show features for web developers* in Settings ▸ Advanced
  first). Firefox has no scripting bridge.
- `NOTCHISLAND_MEDIA_LOG=1` logs every poll's streams and the chosen one.

### Changed
- Media that never played (hover previews, blocked autoplay) and muted looping decorations
  (landing-page hero videos) are ignored. Each tab gets at most 3 s, so a hung page can no longer
  freeze the island for a minute. A stream that one poll missed is held for a couple of seconds
  before the island moves on, so a tab closing elsewhere does not flip the card back and forth.

## 1.0.1 · 2026-10-29

### Fixed
- Notifications showed "Notifications unavailable: authorization denied" when NotchIsland had no
  Full Disk Access, while Settings ▸ Permissions still showed a green check. The readable-file test
  used `access(2)`, which macOS does not gate on Full Disk Access, so the real `open()` failed later
  with SQLite's `SQLITE_AUTH`. The app now opens the store for real, shows a clear hint in the
  island (click it to jump to the Full Disk Access pane), and Settings ▸ Permissions explains the
  steps and offers a Relaunch button. The store is re-checked every 10 s, so a grant is picked up.

### Changed
- Releases are signed with a stable, self-signed "NotchIsland Developer" identity instead of
  ad-hoc. macOS ties Full Disk Access and Accessibility grants to the app's signature, and ad-hoc
  signatures change on every build, which silently voided the grants. After installing 1.0.1 grant
  them once more; later updates keep them. New script: `scripts/signing-identity.sh`.

### Added
- The DMG carries a *Read me first.txt* with the exact steps for Gatekeeper's "could not verify"
  dialog on macOS 13/14 and 15+, plus the Terminal one-liner. README and website say the same.
- `scripts/make-dmg.sh` has a Developer ID path: with a "Developer ID Application" certificate and
  `NOTARY_PROFILE=<notarytool profile>` it signs with the hardened runtime
  (`Resources/NotchIsland.entitlements`), notarizes and staples the app and the DMG, which is the
  only way to make that dialog go away. Untested until a paid Developer ID is available.
- `NOTCHISLAND_PREVIEW=settings` (with `NOTCHISLAND_SETTINGS_TAB=…`) opens the Settings window.

## 1.0.0 · 2026-10-29

- First release.
