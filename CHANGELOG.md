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

## 1.0.0 · 2026-10-29

- First release.
