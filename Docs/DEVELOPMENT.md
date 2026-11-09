# Development

Most schools just download a release; see the [project README](../README.md).
This page covers building Lull from source, signing, making a release, and how
the code is laid out.

## Building

Requirements: macOS 13 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). No other dependencies. You don't need an Apple
Developer account: without one, builds are ad-hoc signed (see
[Signing with a Developer ID](#signing-with-a-developer-id)).

```
make gen            # generate Lull.xcodeproj from project.yml
make test           # source checks, unit tests, builds every target
make build          # Debug build (includes developer test hooks; test Macs only)
make release        # Release build, Apple silicon only (arm64)
make check-release  # proves the Release build has no developer test hooks
make pkg            # build/pkg/Lull-<version>-<build>.pkg from the Release build
make dist           # all of the above, in order (and notarises a signed package)
```

Set the build number in `project.yml` (`CURRENT_PROJECT_VERSION`) before each
release so every package has a new file name.

> **Safety:** Lull locks the screen. Never install or run the daemon or lock
> screen on the Mac you develop on. See [Dev safety](#dev-safety).

## Making a release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`
   and `LullConstants.version` in `Sources/LullCore/Constants.swift` (the
   version `lulld` and `lullctl` report). Add a `## <version> build <build>: …`
   section at the top of `Docs/CHANGELOG.md`. Every release gets a new version
   number, and the build number only ever goes up, so upgrades work.
2. Run `make release-assets` (`Scripts/make-release.sh`). It runs the full build
   and tests, then writes to `build/release/<version>-<build>/`:
   the `.pkg`, a `-jamf-kit.zip` (profiles, schema, extension attributes,
   uninstaller), `SHA256SUMS.txt` and `RELEASE_NOTES.md`.
3. Create a GitHub Release tagged `v<version>` with the notes and the
   three files attached, e.g.
   `gh release create v<version> build/release/<version>-<build>/{*.pkg,*.zip,SHA256SUMS.txt} --notes-file build/release/<version>-<build>/RELEASE_NOTES.md`

Official releases are signed with a Developer ID and notarised. Without
`Config/Signing.local.xcconfig`, everything is ad-hoc signed, which is all
Jamf policies need. `make-release.sh` says in the release notes which it is.

## Signing with a Developer ID

Optional for your own builds: nothing depends on it.

1. **Certificates.** The team's Account Holder creates a *Developer ID
   Application* and a *Developer ID Installer* certificate (developer.apple.com
   > Certificates, or Xcode > Settings > Accounts > Manage Certificates), in the
   build Mac's **login** keychain. Back up both with their private keys (`.p12`).
   Check them with `security find-identity -v -p codesigning` (Application) and
   `security find-identity -v -p basic` (Installer).
2. **Notary credentials**, once (the password is an app-specific password, and
   is stored in the keychain):
   `xcrun notarytool store-credentials lull-notary --apple-id <Apple ID> --team-id <TEAMID>`
3. **Settings.** Copy `Config/Signing.local.xcconfig.example` to
   `Config/Signing.local.xcconfig` (gitignored) and fill in the Team ID, both
   identities and the notary profile. The local file keeps the signer's name
   out of the repository. Environment variables and `make` arguments of the
   same names override it.
4. `make dist` (or `make release-assets`). Release builds are then signed with
   a secure timestamp and the hardened runtime. `Scripts/check-signing.sh`
   checks all three products. The package is signed with `productsign
   --timestamp`, then `Scripts/notarize.sh` submits it to Apple, waits,
   staples the ticket and checks it with `spctl`. Apple's log is saved next to
   the package. Debug builds stay ad-hoc.

The first signing asks for keychain access; choose **Always Allow**.

With a Team ID in the signature, the daemon and lock screen require it from
each other in addition to the installed-build check
([SECURITY.md](../SECURITY.md#how-the-parts-trust-each-other)). For such a
release, the Jamf kit also contains `servicemanagement-teamid.mobileconfig`
([Deployment guide](DEPLOYMENT.md#2-login-items-profile)).

**Certificates expire.** Binaries keep working after the Developer ID
Application certificate expires, because they carry a secure timestamp. A
package signed with an expired Developer ID Installer certificate won't
install until it's re-signed, so rebuild packages kept in Jamf before then. A
*revoked* certificate stops installed copies from launching, so keep the
private keys safe.

## Dev safety

Lull locks the screen, so a bug can lock the machine you're working on.

- **Never install or run the daemon or lock screen on your everyday Mac.** Use a
  spare test Mac (or a VM, then re-check the lock screen on real hardware).
- **Turn on Remote Login (SSH) on the test Mac before testing a lock**, so you can
  recover it from another machine: `sudo touch /var/db/lull/DISABLE` (Debug
  builds) or `sudo "/Library/Application Support/Lull/bin/uninstall.sh"`.
- Stopping only the daemon doesn't end a lock: by design, the lock screen stays
  up until the downtime window ends if it loses the daemon.
- Test with Debug builds, which have the escape hatches below. Release builds
  must have none of them.

## Debug builds

Debug builds contain hooks that never exist in Release (checked by
`make check-release` at source and binary level):

- the lock releases itself after 10 minutes, and **Ctrl-Option-Command-Shift-L** releases it at once
- `/var/db/lull/DISABLE` (created by root) disables Lull
- a developer settings file and a time offset to reach a downtime window quickly
- `lullctl simulate` to evaluate a schedule at any time
- `Lull --demo …` to show the real lock screen from a scripted timeline

`make dev-bundle` packs a Debug build with `dev-install.sh` for a test Mac.

## Layout

```
Sources/
  LullCore/        Pure logic: settings, schedule engine, trusted time, override hashing, XPC contract
                   (Remote/: the parent portal's wire format and settings rules)
  LullDaemonKit/   Daemon internals: settings loading, persistence, logging, time sync, supervision
  LullAgentKit/    Lock screen: SwiftUI views, window control, XPC client
  Lull/            Lock-screen app entry point
  lulld/           Daemon entry point
  lullctl/         Admin CLI
Tests/             Unit tests (swift test); never open windows
  Fixtures/portal/ Copy of lull-portal's contract/fixtures; keep identical
Resources/         Info.plist, app icon, launchd plist templates
Config/            Example profile, Jamf schema, Service Management profile
Scripts/           Build, package, uninstall, install scripts, Jamf extension attributes, checks
Docs/              Documentation
```

The portal's device API is defined in
[lull-portal](https://github.com/nicholas-99w/lull-portal) (`contract/PORTAL_API.md`);
within `/v1` it only changes in backward-compatible ways. The Mac side is
`Sources/LullCore/Remote/`, `Sources/LullDaemonKit/PortalClient.swift` and
`Scripts/jamf/portal-enrol.sh`.

The Jamf schema is generated from `Scripts/dev/gen-jamf-schema.py`. Tests check
that it and the example profile match the settings the code understands.
Documentation screenshots are rendered from the real views:
`LULL_DOC_SCREENSHOTS=$PWD/Docs/images swift test --filter DocScreenshotTests`.
