# Security

Lull enforces downtime for students on **standard (non-admin) accounts**. It's
built to keep the lock screen up when someone tries to get around it, and
never to trap anyone: Shut Down, Sleep and your IT contact details are always
on the lock screen.

## Reporting a problem

Please report security problems privately through
[GitHub's private vulnerability reporting](https://github.com/nicholas-99w/lull/security/advisories/new),
not as a public issue. Describe the problem and its impact; there's no need
to send a working exploit. For anything else, open an
[issue](https://github.com/nicholas-99w/lull/issues) and include the output of
`lullctl status --json` and `/var/log/lull/lulld.log`. Neither contains
secrets.

## What Lull resists

Each of these is covered by automated tests, the [test plan](Docs/TESTING.md),
or both.

| A student tries to… | What happens |
|---|---|
| Change the clock or time zone | Lull keeps its own trusted time, and schedules use the profile's time zone. The change is logged as tampering |
| Go offline, or restart offline | Locking never needs the network. After an offline restart, Lull's clock only moves forward, or optionally stays locked until it's synced |
| Run a fake time server | Network time may only correct a small, plausible drift. Bigger jumps must be confirmed over HTTPS with apple.com, which a student can't forge |
| Quit the lock screen (Cmd-Q, Force Quit, Dock, app switching, AppleScript) | Shortcuts are swallowed, app switching and Force Quit are disabled, and quit requests are refused unless the Mac is logging out or shutting down |
| Kill, freeze, hide or unload the lock screen, or replace its launchd job | `lulld` notices within seconds and brings the lock screen back |
| Keep killing it in a loop | The Mac is put to sleep repeatedly until the loop stops |
| Run a look-alike app | `lulld` only talks to the exact build installed in its root-owned folder |
| Edit Lull's files or settings | Everything is owned by root, and settings are only read from configuration profiles |
| Guess the override passphrase | It's checked by the root service against a slow, salted hash (PBKDF2-SHA256), with a lockout that survives restarts and clock changes |
| Attach a debugger | Release builds don't allow it |
| Turn Lull off in Login Items | The login items profile prevents it |

## Known limits

- **Admins aren't stopped.** Anyone with an admin account or root can remove
  Lull. Keep students on standard accounts, and use the *Lull unhealthy* Smart
  Group (see the [Deployment guide](Docs/DEPLOYMENT.md#6-extension-attributes-and-smart-group))
  to find Macs where it was removed or stopped.
- **Mission Control, Spaces and Spotlight** can still be opened over the lock
  screen. Turning off hot corners with your MDM reduces this.
- **Brief gaps**: the desktop can be visible for a moment when a student logs
  in during downtime, for about a second after the lock screen is killed, and
  for a few seconds during an upgrade.
- **A fake time server** that stays within the allowed drift can shift Lull's
  time by minutes at most, never hours.
- **A passphrase hash in the profile** can be read on the Mac and guessed
  offline. Prefer the root-only passphrase file, or use a long passphrase.
- **Parent portal**: a parent's opt-out and release are deliberate ways round
  the evening schedule, which a student who knows their parent's password could
  use. Whoever runs the portal controls the schedules of the Macs enrolled in
  it, so secure it like any other staff system.

The recommended MDM settings in the
[Deployment guide](Docs/DEPLOYMENT.md#7-recommended-settings-around-lull)
close several of these gaps.

## How the parts trust each other

- `lulld` and the lock screen talk over a private XPC connection. Each side
  checks that the other is the exact build installed in
  `/Library/Application Support/Lull` (by bundle identifier and code hash,
  recomputed for every connection), and, for signed builds, that it has the
  same Team ID. If the install folder's ownership has been changed, Lull falls
  back to checking the identifier and Team ID only, and logs
  `xpc_peer_pin_unavailable`. Reinstalling the package fixes it.
- Only root can register the daemon's XPC service, so a user can't pretend to
  be the daemon.
- Release packages are signed with a Developer ID and notarised by Apple. The
  binaries are signed with a secure timestamp and the hardened runtime.
- The parent portal is reached over HTTPS using the system's trusted
  certificates only. Its credentials are stored in root-only files, settings
  can only move forward in revision, and a lock-down can never last more than
  24 hours.

## Secrets

Passphrases, hashes and portal credentials are never logged. The status file
that `lullctl status` and the extension attributes read is readable by
everyone, so it contains no secrets.
