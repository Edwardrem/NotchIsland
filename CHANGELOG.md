# Changelog

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
