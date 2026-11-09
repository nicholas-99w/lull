# Testing

Lull is tested in two ways:

- **Automated** (`make test`): runs anywhere, never opens a window or locks anything.
- **Manual matrix** (below): on a **test Mac** and in **Jamf**. Each row has
  steps and the expected result. Record pass/fail and the macOS version.

## Safety first

**Never run lulld or Lull.app on a daily-driver Mac.** Use a spare Mac (real
hardware for overlay/Spaces/display checks; a VM is fine for the rest).

Before any lock test:
1. Enable **Remote Login (SSH)** on the test Mac and log in from a second machine.
2. Know the way out:
   - Debug builds: wait 10 min (auto-release), press **Ctrl-Opt-Cmd-Shift-L**,
     or `sudo touch /var/db/lull/DISABLE` over SSH (`sudo rm` it afterwards).
   - Any build: `sudo "/Library/Application Support/Lull/bin/uninstall.sh"`
     (stops the daemon and every lock screen; state is kept unless `--purge`).
     Stopping only the daemon (`launchctl bootout system/…`) does **not** end a
     lock: by design the lock screen stays up until the window ends (row F5).
   - Release builds have only the admin override and the SSH routes.

## Automated

```
make test              # Debug-guard source check, unit tests (LullCore, LullDaemonKit, LullAgentKit), builds all targets
make release
make check-release     # source guard + Release binaries contain no Debug hatches (+ self-test on the Debug build)
LULL_NETWORK_TESTS=1 swift test --filter NetworkTimeSyncTests   # live SNTP + HTTPS Date (opt-in)
LULL_SNAPSHOTS=1 swift test --filter SnapshotTests              # renders the UI to /tmp/lull-snapshots/*.png
LULL_PORTAL_E2E_URL=http://localhost:8080 LULL_PORTAL_E2E_SECRET=<enrolment secret> \
    LULL_PORTAL_E2E_ADMIN_EMAIL=<admin> LULL_PORTAL_E2E_ADMIN_PASSWORD=<password> \
    swift test --filter PortalLiveTests   # lulld's engine + real HTTP client against a running portal (opt-in)
```

`PortalLiveTests` needs a portal running from a
[lull-portal](https://github.com/nicholas-99w/lull-portal) checkout, with
`LULL_PORTAL_E2E_SECRET` set to that checkout's `LULL_ENROLMENT_SECRET` (in
its `.env`). It runs only the daemon engine (fake clock, temp state, no XPC,
agent or supervisor), so it is safe on a development Mac. It registers a Mac,
signs in as IT (`LULL_PORTAL_E2E_ADMIN_EMAIL`/`_PASSWORD`, an admin you created
in the portal, e.g. the owner), creates a parent linked to the test student,
sets the parent's password with the one-time setup code, opts the Mac out, and
checks the engine applies it and the portal shows *Up to date*.

## Getting a build onto the test Mac

| Route | Use for | Commands |
|---|---|---|
| **Debug dev bundle** | Most of the matrix (escape hatches, time offset, dev plist) | Dev Mac: `make build && make dev-bundle`, copy `build/lull-dev-Debug.tar.gz`. Test Mac: `tar xzf …; cd lull-dev; sudo ./dev-install.sh --i-am-on-a-test-mac --products . --dev-config my.plist`. Remove: `sudo ./dev-uninstall.sh [--purge]` |
| **Release package via Jamf** | Install/upgrade/profile/EA rows and final sign-off | `make dist` → `build/pkg/Lull-<ver>-<build>.pkg`, deploy with a policy |
| **Demo overlay (no daemon)** | UI look only | `…/Lull.app/Contents/MacOS/Lull --demo cycle\|warning\|locked\|awaiting [--demo-config plist]`. Passphrase `lull`; Shut Down/Sleep only beep |

**Reaching a window quickly (Debug):** set `DebugTimeOffsetSeconds` in the dev
plist to (target − now) in seconds, e.g.
`sudo plutil -replace DebugTimeOffsetSeconds -integer $(( $(date -j -f %H:%M:%S 21:27:00 +%s) - $(date +%s) )) /var/root/Library/Preferences/au.com.nickit.lull.dev.plist`
(applied within 5 s; set back to 0 to end). Or put `Start` a few minutes ahead.
Test as a **standard** user (admins are exempt by default).

Useful while testing: `lullctl status`, `sudo tail -f /var/log/lull/lulld.log`,
`log stream --predicate 'subsystem == "au.com.nickit.lull"'`.

## Manual matrix

Result column: ✅ / ❌ / note. "Locked" means the overlay is on every display.

### A. Schedule and warnings

| # | Steps | Expected |
|---|---|---|
| A1 | Window approaching (15 min) | Warning card at 15, 10, 5, 2, 1 min for ~20 s each, in the configured corner, without taking focus from the front app |
| A2 | Final 60 s | Card stays up with a live countdown and filling progress bar |
| A3 | Lock time | Locked; card on the primary display only; desktop blurred/solid/image per config; Dock and menu bar hidden |
| A4 | Snooze (`SnoozeEnabled`) during warning | Lock delayed by `SnoozeMinutes`; second snooze refused at `MaxSnoozesPerWindow`=1 |
| A5 | Window end | Overlay goes away; the user's apps are where they were |
| A6 | `DateExceptions` Skip for today | No window starts today (an overnight window from yesterday still ends normally) |
| A7 | Window spanning a DST change (`lullctl simulate` in Debug, or set the test Mac's date range) | Lock/unlock at the configured local times |
| A8 | Branding: banner/logo in `Branding/`, colours, texts with tokens, dark mode | Rendered as configured; `{{firstName}}` etc. filled; missing/corrupt image simply omitted |

### B. Time tampering and network

| # | Steps | Expected |
|---|---|---|
| B1 | During a window, as admin over SSH: `sudo date` forward past the window end | Still locked; `clock_tamper` logged; `lullctl status` wall offset shows the jump |
| B2 | Before a window: `sudo date` back several hours | Lock still at the real time |
| B3 | Change the Mac's time zone | No effect on lock/unlock times |
| B4 | Wi-Fi off / Ethernet unplugged across a lock time | Locks on time; `time_sync` failures logged and retried every 60 s |
| B5 | Reboot offline inside a window, RTC set back (`ForwardOnly`) | Still locked after login; `[provisional]`; never unlocks earlier than the real end |
| B6 | Same with `OfflineBootPolicy=LockUntilSynced` | Locked "awaiting time sync" until network returns; then normal schedule; override still works |
| B7 | Block UDP 123 on the network | Sync succeeds via `https://www.apple.com` (status `last sync … via https://…`) |
| B8 | **Spoofed time server**: point the test Mac's DNS at a host that answers NTP for `time.apple.com` with a time 9 h ahead (e.g. a Raspberry Pi with chrony + `local stratum`), during a window | Still locked; `time_sync_suspicious` logged; next sync via HTTPS; the spoofed time is never applied |
| B9 | Sleep (close lid) before a lock time, wake after it | Overlay up immediately on wake, before the desktop is usable |

### C. Anti-tamper (as the standard user, while locked)

| # | Steps | Expected |
|---|---|---|
| C1 | Cmd-Q, Cmd-W, Cmd-H, Cmd-M, Cmd-Tab, Cmd-Opt-Esc | Nothing happens |
| C2 | Mission Control (F3, Ctrl-↑), Ctrl-←/→, Cmd-Space, hot corners | **Known gap**: may appear. Note what is reachable; the overlay covers every Space. Mitigate with the recommended MDM settings (deployment guide, section 7) |
| C3 | Click another app / a notification | Focus back on the overlay within ~1 s |
| C4 | Over SSH as the user: `kill -9 $(pgrep -x Lull)` | Overlay back within ~1–2 s |
| C5 | `kill -STOP $(pgrep -x Lull)` | Within ~5–8 s `agent_missing` then `agent_recovery method=kickstart`; overlay back |
| C6 | `launchctl bootout gui/$(id -u)/au.com.nickit.lull` | Within ~5 s `agent_recovery method=bootstrap`; overlay back |
| C7 | `launchctl disable gui/$(id -u)/au.com.nickit.lull` then bootout | Recovered as C6 (lulld re-enables first) |
| C8 | `osascript -e 'quit app "Lull"'` (approve the Automation prompt) | Quit refused (`refused quit request` in the log); overlay stays |
| C9 | Make recovery fail (as root, temporarily `chmod 000` the agent plist; restore 644 afterwards) | After ~15 s `fallback_sleep_display`; display sleeps every 10 s while missing |
| C10 | Look-alike agent: copy Lull.app, change a byte in `Info.plist`, `codesign -f -s - -i au.com.nickit.lull`, run it | Never receives state (cdhash pin); real overlay unaffected |
| C11 | `lldb -p $(pgrep -x Lull)` (Release) | Refused (debugger attachment denied) |
| C12 | System Settings > General > Login Items, as the standard user | Lull items managed, can't be turned off (needs the Service Management profile) |
| C13 | Release build, as admin: `sudo defaults write /Library/Preferences/au.com.nickit.lull Enabled -bool false` (a standard user can't write there, and the daemon never reads user-level prefs) | No effect; `lullctl status` lists `Enabled` under "ignored (not enforced by a profile)". Remove it afterwards |
| C14 | Kill loop + keep display awake: `while :; do pkill -9 -x Lull; done &` and `while :; do caffeinate -u -t 1; done &` (as the user, over SSH) | ~15 s: display sleeps (undone by caffeinate); ~30 s: **the Mac sleeps** (`fallback_sleep_system`) and keeps doing so every 20 s while the loop runs. Stop the loops; overlay back |
| C15 | Hijack the label: `launchctl bootout gui/$(id -u)/au.com.nickit.lull`, then `launchctl bootstrap gui/$(id -u) ~/x.plist` with `Label=au.com.nickit.lull`, `Program=/usr/bin/yes`, `KeepAlive=true` | `agent_label_hijacked` with the plist path; `agent_recovery method=replace`; real overlay back within ~5 s |
| C16 | Hide the lock screen from another process: `osascript -e 'tell application "System Events" to set visible of process "Lull" to false'` in a loop | Overlay reappears at once; if hiding keeps winning, lulld sees "not presenting" and restarts the agent; fallback as C14 |

### D. Displays and sessions

| # | Steps | Expected |
|---|---|---|
| D1 | Plug/unplug an external display while locked; toggle mirroring | Overlay covers all displays within ~1 s |
| D2 | Fast user switching: two non-exempt users, switch during a window | Each session locked independently; status lists both; display-sleep fallback only for the on-screen session |
| D3 | Log out and back in during a window | Overlay as soon as the session starts (a brief desktop flash is a known limitation) |
| D4 | Screen Sharing into the locked Mac | Remote viewer sees the overlay; no interaction possible beyond the lock screen |
| D5 | Exempt username / admin user (`ExemptAdminUsers=true`) / non-exempt standard user | Exempt and admin see nothing (`exempt=true` in status); standard user locked |

### E. Override, Shut Down, Sleep

| # | Steps | Expected |
|---|---|---|
| E1 | `echo '…' \| sudo "/Library/Application Support/Lull/bin/lullctl" hash-passphrase --stdin --write` | `/var/db/lull/override.json` root:wheel 0600; status `hash=file`. `chmod 644` it → `override_file_rejected`, `hash=none` |
| E2 | Admin override with the right passphrase | Unlocked for `OverrideDurationMinutes`, then locks again |
| E3 | Wrong passphrase ×`OverrideMaxAttempts` | "n attempts remaining", then lockout; lockout survives `sudo launchctl kickstart -k system/au.com.nickit.lulld` and a clock change |
| E4 | Shut Down → confirmation | Text warns unsaved work will be lost and suggests Sleep; Return = Sleep |
| E5 | Choose Sleep | Mac sleeps; overlay still up on wake |
| E6 | Choose Shut Down | Powers off immediately without save prompts |
| E7 | `ShowShutdownButton=false` | No button; a forged request is refused (`power_request allowed=false`) |
| E8 | While locked: press the power button (or Ctrl-Eject / Ctrl-power on older keyboards) | The system's Restart / Sleep / Shut Down dialog appears and works (never trap people; the Apple menu itself is hidden while locked) |

### F. Config and operations

| # | Steps | Expected |
|---|---|---|
| F1 | Change the profile in Jamf | `config_loaded` within ~5 s of the profile landing |
| F2 | Push an invalid profile (`Start = 9pm`) | `config_rejected` once; `usingLastValid=true`; EA `WARN: config invalid…` |
| F3 | Jamf custom schema: paste `Config/jamf-custom-schema.json`, fill Timezone + one schedule, check the `</>` preview | Form renders all sections; integers as `<integer>`, opacity `<real>`; Mac shows `currentValid=true`, no warnings |
| F4 | `sudo profiles show -type configuration` | Payload `com.apple.ManagedClient.preferences`, Forced, domain `au.com.nickit.lull` |
| F5 | `sudo launchctl bootout system/au.com.nickit.lulld` while locked | Overlay stays until the window's end time, then releases on its own |
| F6 | `sudo kill -9 $(pgrep -x lulld)` while locked | Restarted by launchd; agent reconnects; overlay never drops |
| F7 | EAs + `sudo jamf recon` | `OK: …`; after F5 → `ERROR: lulld not running`; Smart Group `^OK` membership changes; B1 → Time Integrity `WARN: clock tampering…` |

### H. Parent portal (profile with `Portal.URL`; portal per the [lull-portal README](https://github.com/nicholas-99w/lull-portal#readme))

| # | Steps | Expected |
|---|---|---|
| H1 | Run `Scripts/jamf/portal-enrol.sh` (parameter 4 = the portal's enrolment secret) | `/var/db/lull/portal-enroll.json` root:wheel 0600; within one poll `portal_registered`; `lullctl status` shows `registered=true`; IT sees the Mac in the portal |
| H2 | Student signs in; parent (portal) adds the student's username | The parent sees the Mac; its primary user is the student (not an exempt/admin account), shown by the account's full name (IT sees the username too) |
| H3 | New Mac with the profile's Mon–Fri schedule | Portal has *School's schedule* selected, showing "(Mon–Thu …)", and the Mac follows the profile |
| H4 | Parent opts out during a lock | Unlocks within `PollIntervalSeconds`; portal shows *Up to date* and the current schedule as "opted out" |
| H5 | Parent: school nights *School's schedule*, weekend *Opt out* | No downtime starting Fri or Sat (the profile's Friday window too); Sun–Thu still the school's; a school `AllDay` day still locks |
| H6 | Parent customises school nights only | Mac: parent's times Sun–Thu, the profile's Friday window kept; switching back to "Follow" restores the profile's |
| H7 | Parent moves school-night start; IT tightens bounds | `portal_settings_applied` (and `settings_clamped` in the portal's audit log); lock at the new time |
| H8 | Change the profile's `Schedules` (another Jamf profile for the group) | Macs following the school pick it up within ~5 s; customised kinds keep the parent's times |
| H9 | Parent: *Lock down now* 30 minutes (also while opted out of the schedules) | Locks at the next poll with no warning card; lock screen countdown to the chosen end; unlocks on its own, also offline |
| H10 | Parent: *Unlock now* during a scheduled window; *Reset overrides* during a lock-down | Unlocks at the next poll (no warning); the next night's window still locks |
| H11 | Weekday during school hours (portal: Mon–Fri 08:30–15:30) | Parent sees "Lock down now isn't available during school hours" and "The Mac can't be unlocked during school hours"; a school-night window ending 09:00 is refused; IT can still lock |
| H12 | Profile `Enabled=false` with the parent opted in | Disabled (IT's master switch wins); a lock-down has no effect either |
| H13 | Block the portal host (pf, or unplug the network) across a lock time | Locks on time with the cached settings; `portal_error` logged once; EA `WARN: portal: …` |
| H14 | Reboot offline | Cached portal settings apply from the first second (no profile-schedule fallback) |
| H15 | `sudo date` a year ahead (TLS fails), during a window | Still enforcing the cached settings; error mentions TLS/clock; no settings change |
| H16 | IT clicks *Reset device* | Next poll: `portal_token_refused`, `portal_registered`; settings and primary user kept |
| H17 | IT: *De-register device* (tick the confirmation), during a portal lock-down | At the next poll: `portal_deregistered`; lock-down ends; profile schedule applies; `/var/db/lull/portal.json` and `portal-enroll.json` gone; `lullctl status` "de-registered by IT"; EA stays `OK`; no further portal requests (portal log) |
| H18 | Re-run the enrolment script after H17 | Registers as a new Mac (school defaults); parent sees it again once the student signs in |
| H19 | `chmod 644 /var/db/lull/portal.json` or the enrolment file | Refused (`portal_credentials_rejected` / "enrolment secret refused"); re-registers only from a root-only file |
| H20 | Fresh deployment: open the portal | "Set up the portal"; the account created is the owner (Users: *Owner*), can't be deleted or demoted; `/FirstRun` then leads to sign-in |
| H21 | IT imports parents by CSV, mail-merges the setup codes; a parent sets a password (8+ with upper, lower and special) | Parent sees their child's Mac; a weaker password is refused with what's missing; 5 wrong passwords lock the account for 15 min; IT can unlock or issue a new code (the old password and sessions stop working) |
| H22 | Release build: `strings lulld \| grep -- --portal-url` | Nothing (`make check-release`) |
| H23 | IT adds a school holiday starting next Monday; the parent sets School holidays to Custom 14:00–09:00 | Friday before (the last school day): unlocked until school ends, then locks as "School holidays" until 09:00; during the break, from 14:00; on the night before school goes back, from 14:00 straight into the usual school-night window, which ends as usual |
| H24 | As H23 with School holidays: Opt out | No scheduled downtime from the last school day's evening to the night before school; a parent lock-down still locks; a profile `AllDay` date in the break still locks all day |

### G. Install, upgrade, uninstall

| # | Steps | Expected |
|---|---|---|
| G1 | Install the Release pkg with a Jamf policy while a user is logged in | `lulld started`, agent connected, no logout needed |
| G2 | Install a newer build over a running copy (also during a lock) | Overlay back within seconds; state (lockouts, snoozes, trusted time) kept; no `xpc_peer_pin_unavailable` |
| G3 | `pkgutil --files au.com.nickit.lull.pkg`; `ls -la@` the install folder | No `._*` files installed; root:wheel; no group/other write; `/usr/local/bin/lullctl` only if that folder is root-only |
| G4 | A copy of Lull.app in `~/Downloads`, then install | Installs to `/Library/Application Support/Lull/` (not relocated) |
| G5 | `grep xpc_listening /var/log/lull/lulld.log \| tail -1` | `"pinned":true`, `cdhash H"…"` |
| G6 | Jamf policy: `"/Library/Application Support/Lull/bin/uninstall.sh" --purge` | All files, jobs, receipt and `/var/db/lull` gone; exit 0 |
| G7 | Unsigned package: download it in a browser on a test Mac, then `sudo installer -pkg Lull-*.pkg -target /` | Installs without a Gatekeeper prompt (VERIFY); double-clicking the same file is blocked as unsigned |
| G8 | Signed package: download it in a browser, then double-click it | Installer opens with no Gatekeeper warning; `spctl -a -vv -t install Lull-*.pkg` says `source=Notarized Developer ID` |
| G9 | With `servicemanagement-teamid.mobileconfig` installed: C12, then `sudo sfltool dumpbtm` | Lull items managed, can't be turned off; dumpbtm shows them matched by the Team ID rules |

## Definition of done

The release criteria, and how each is checked.

| Item | Verified here (automated) | Still to verify (matrix) |
|---|---|---|
| Release build for arm64 (Apple silicon only); unit tests pass | `make release` (`lipo -info` shows arm64 only); `make test` | none |
| Installer package; Developer ID signed and notarised when configured, otherwise ad-hoc | `make dist` builds `Lull-<ver>-<build>.pkg`; `check-signing.sh` (all products the same way; Team ID, timestamp, hardened runtime, no get-task-allow); signatures survive staging; `notarize.sh` (accepted, stapled, `spctl`) | G1, G8 |
| Warning cards at intervals; lock at trusted time on all displays; branded card | Schedule engine, presenter and snapshot tests | A1–A3, A8, D1 |
| Clock/timezone/network changes don't move lock times | TrustedClock and engine tests incl. tamper, offline reboot, spoofed SNTP | B1–B8 |
| Killing/unloading the agent brings the overlay back within seconds | Supervisor and AgentHub tests (missing, hung, disabled+unloaded agents) | C4–C9 |
| Override, snooze, shutdown and exemptions behave as specified | Engine, gate, XPC hub and model tests | D5, E1–E8, A4 |
| Release builds contain no Debug escape hatches | `check-debug-guards.py` (source) + `check-release-hatches.sh` (binaries, with self-test) | C11 |
| All deliverable files exist and match the settings reference | `ShippedConfigTests` (example profile and schema vs parser) | F3, F4 |

## VERIFY register (unconfirmed external behaviour)

| Item | Where | Matrix row |
|---|---|---|
| Root daemon sees device-scoped managed prefs as forced | `Sources/LullDaemonKit/ConfigSource.swift` | F1, F4, C13 |
| `State:/Users/ConsoleUser` SessionInfo keys | `Sources/LullDaemonKit/Sessions.swift` | D2 |
| ~~cdhash of the installed build matches the running peer~~ **Confirmed** (see note below) | `Sources/LullCore/XPC/CodeSigningRequirement.swift` | G5, C10 |
| Service Management Label/BundleIdentifier rules lock ad-hoc items | `Config/servicemanagement.mobileconfig` | C12 |
| ~~Service Management `TeamIdentifier` sub-key matches Developer ID signed items~~ **Confirmed** (see below) | `Config/servicemanagement-teamid.mobileconfig.template` | G9 |
| Jamf accepts the signed component package for Enrollment/PreStage | `Scripts/make-pkg.sh` | not tested |
| Jamf custom schema: min/max, nested objects, number vs integer, payload format | `Config/jamf-custom-schema.json` | F3, F4 |
| `ThrottleInterval 1` honoured | `Resources/LaunchAgent.plist.template` | C4 |
| ~~`AssociatedBundleIdentifiers` lists lulld under "Lull"~~ **Confirmed** (see below) | `Resources/LaunchDaemon.plist.template` | C12 |
| Event tap needs Accessibility (not ListenEvent) | event tap not built; no PPPC profile shipped | not built |
| Quit reason codes on logout/restart/shutdown reach the agent | `Sources/LullAgentKit/QuitPolicy.swift` | E8 |
| `pmset sleepnow` can't be blocked by a standard user's power assertions (`caffeinate -i/-s`) | `Sources/LullDaemonKit/Supervisor.swift` | C14 |
| `launchctl print` `path = …` line identifies the job's plist | `Sources/LullDaemonKit/CommandRunner.swift` | C15 |
| `NSApp.unhideWithoutActivation` restores an overlay hidden by another process | `Sources/LullAgentKit/Windows/OverlayController.swift` | C16 |
| IOPlatformExpertDevice serial/UUID readable by the root daemon (and on VMs) | `Sources/LullDaemonKit/PortalCredentials.swift` | H1 |
| URLSession in a root LaunchDaemon uses the system trust store (Jamf-deployed CA) and system proxy | `Sources/LullDaemonKit/PortalClient.swift` | H1, H15 |

**Confirmed in practice:**

- *cdhash of the installed build matches the running peer*: confirmed on a
  test Mac over an extended run (daemon and lock screen connect and lock as
  expected).
- *Developer ID signing and notarisation*: `make dist` signs all three
  products with a secure timestamp and the hardened runtime, the package is
  accepted by the notary service and stapled, and `spctl` reports
  `source=Notarized Developer ID`. G8 is still to be run on a test Mac.
- *Team ID login items profile* (G9): with
  `servicemanagement-teamid.mobileconfig` installed, Lull's items are managed
  and can't be turned off.
- *Login Items name*: on a fresh install of a signed build, `sfltool dumpbtm`
  shows lulld with `Assoc. Bundle IDs: [ au.com.nickit.lull ]`, listed under
  "Lull".
