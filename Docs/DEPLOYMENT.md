# Deployment guide

This guide takes you from a downloaded release to Lull running on student
Macs, managed from Jamf Pro. Other MDMs work too, as long as they can deploy a
package, configuration profiles and scripts; only the form-based settings
schema is specific to Jamf Pro.

You'll deploy:

| | What | Why |
|---|---|---|
| 1 | Login items profile | Stops students turning Lull off in System Settings |
| 2 | The package | Installs Lull |
| 3 | A settings profile | Your schedules, wording and branding |
| 4 | An override passphrase (optional) | Lets staff unlock a Mac for a while |
| 5 | Two extension attributes and a Smart Group | Finds Macs where Lull isn't healthy |

## Before you start

- **Macs**: Apple silicon, macOS 13 Ventura or later, enrolled with
  user-approved MDM (needed for the login items profile).
- **Accounts**: students need **standard** accounts. Admin accounts are exempt
  by default, and an admin could remove Lull anyway.
- **A test Mac** you can afford to lock, with Remote Login (SSH) turned on so
  you can recover it from another computer if needed. Don't test on your own
  Mac.

## 1. Download

From the [Releases page](https://github.com/nicholas-99w/lull/releases/latest),
download:

| File | What it is |
|---|---|
| `Lull-<version>-<build>.pkg` | The installer, signed with a Developer ID and notarised by Apple |
| `Lull-<version>-<build>-jamf-kit.zip` | Custom schema, profiles, extension attributes and scripts |
| `SHA256SUMS.txt` | Checksums |

Check the download and unzip the kit:

```
shasum -a 256 -c SHA256SUMS.txt
unzip Lull-*-jamf-kit.zip
```

The package installs into `/Library/Application Support/Lull/`, with its
launchd jobs in `/Library/LaunchDaemons` and `/Library/LaunchAgents`, state in
`/var/db/lull/` and logs in `/var/log/lull/`. Lull's identifiers
(`au.com.nickit.lull` and `au.com.nickit.lulld`) appear in every profile and
script, so keep them as they are.

## 2. Login items profile

Deploy this **first**, so students never get the chance to switch Lull off.

In Jamf Pro: Computers > Configuration Profiles > **Upload**
`profiles/servicemanagement-teamid.mobileconfig` from the kit, and scope it to
the student Macs.

It approves Lull's login items by their identifiers and requires Lull's
Developer ID Team ID. That way, items with the same identifiers signed by
someone else aren't approved.

> **Building your own package without a Developer ID?** It has no Team ID, so
> use `Config/servicemanagement.mobileconfig` from the repository instead,
> which matches by identifier only.

## 3. Package

1. Settings > Computer Management > Packages > New: upload the `.pkg`.
2. Computers > Policies > New: add the package (Install), trigger
   **Recurring Check-in** (or Enrollment Complete), frequency
   **Once per computer**.
3. Scope it to a pilot group first.

Lull starts straight away for everyone logged in; no restart or logout is
needed. It does nothing until a settings profile arrives.

To install by hand on a test Mac, double-click the package, or run
`sudo installer -pkg Lull-*.pkg -target /`.

## 4. Settings profile

Computers > Configuration Profiles > New > **Application & Custom Settings**:

1. **External Applications** > Add > **Custom Schema**.
2. Preference domain: `au.com.nickit.lull`
3. Paste the contents of `jamf-custom-schema.json` from the kit.
4. Fill in the form. At minimum:
   - **Time zone**, for example `Australia/Sydney`
   - one **Schedule**, for example Days Sun–Thu, Start `21:30`, End `06:30`
   - **Texts > Organisation name** and **Support contact**
5. Scope it to the student **computers** (not users).

Empty fields use Lull's defaults. The [Configuration guide](CONFIGURATION.md)
describes every setting, with recipes for common timetables, and the
[Appearance guide](APPEARANCE.md) covers branding.

If you'd rather edit a file, `profiles/au.com.nickit.lull.mobileconfig` in the
kit contains every setting with sample values. Edit it and upload it.

Changes reach the Macs at their next check-in, and Lull applies them within
seconds. Mistakes are handled safely: a bad value falls back to its default,
and a profile that can't be used at all is ignored in favour of the last good
one. Either way, Lull reports the problem (see
[How settings work](CONFIGURATION.md#how-settings-work)).

**Branding images** go in `/Library/Application Support/Lull/Branding/` on
each Mac. Package them with Jamf Composer or `pkgbuild` and deploy them with a
policy; see [Images](APPEARANCE.md#images).

## 5. Override passphrase (optional)

The lock screen's **Admin override** unlocks the Mac for a set time (30 minutes
by default) after the right passphrase. Lull stores only a slow, salted hash.

Store it on each Mac where only root can read it. Create a Jamf script:

```
#!/bin/bash
echo "$4" | "/Library/Application Support/Lull/bin/lullctl" hash-passphrase --stdin --write
```

Run it from a policy (once per computer) with the passphrase in
**parameter 4**, so it isn't stored in the script itself.

You can put a hash in the settings profile instead (`lullctl hash-passphrase`
makes one), but profiles can be read on the Mac, so a student could try to
guess it offline. If you do, use a long passphrase of four or more random
words.

## 6. Extension attributes and Smart Group

Settings > Computer Management > Extension Attributes > New, Data type
**String**, Input type **Script**:

| Name | Script (from the kit) | A healthy Mac reports |
|---|---|---|
| Lull Status | `extension-attributes/ea-status.sh` | `OK: phase=normal config=managed v1.0.0` |
| Lull Time Integrity | `extension-attributes/ea-time-integrity.sh` | `OK: synced 12m ago via time.apple.com, clock offset 0s` |

Then create a Smart Group, **Lull unhealthy**: *Lull Status* *does not match
regex* `^OK`. It catches Macs where Lull is missing or not running, has a
broken profile, or has a logged-in user without a lock screen during downtime.
A *Lull Time Integrity* value starting with `WARN` means the clock was changed,
or the Mac can't reach a time server.

## 7. Recommended settings around Lull

These aren't part of Lull, but they close gaps around it. Deploy them with your
MDM's own restriction settings, and test each on a test Mac first:

- Keep students on standard accounts.
- Hide the Date & Time settings.
- Turn off fast user switching.
- Require a password straight after sleep or the screen saver.
- Turn off hot corners.
- Block Terminal and Activity Monitor for students (for example with Jamf
  Restricted Software).

Don't block Shut Down or Restart: Lull relies on people always being able to
turn the Mac off.

## Parent portal (optional)

[lull-portal](https://github.com/nicholas-99w/lull-portal) is a self-hosted
web portal where parents can opt their child's Mac out of evening downtime or
change its times, within limits IT sets. School hours stay off limits to
parents. Your profile's schedules remain the baseline, and a Mac keeps
enforcing its last settings if it can't reach the portal.

1. Set up the portal as described in its README. It must be served over HTTPS
   with a certificate the Macs trust.
2. In the settings profile, set **Parent portal > Portal URL**.
3. Add the kit's `scripts/portal-enrol.sh` to a policy, once per computer,
   with the portal's enrolment secret in **parameter 4**. Put it in the package
   policy with priority **Before**, or in its own policy. It stores the secret
   where only root can read it; never put it in the profile.

Each Mac registers with the portal straight away. How the portal and profile
settings combine is described in [Parent portal](CONFIGURATION.md#parent-portal).

## Rolling out

1. **Pilot** on a test Mac with downtime a few minutes ahead. Check that:
   - the warning card and lock screen appear for a standard user, on every
     display
   - the admin override unlocks the Mac
   - Shut Down and Sleep work from the lock screen
   - the extension attributes report `OK`

   The [test plan](TESTING.md) has the full list.
2. **Tell staff and families** when downtime runs, what the lock screen looks
   like, and who to contact.
3. **Pilot group**: a handful of real student Macs for a week, watching the
   Smart Group.
4. **Everyone else.**

## Day to day

On a Mac, from Terminal or Jamf Remote:

```
lullctl status            # what Lull is doing, its next change, settings problems, time sync, users
lullctl status --json     # the same, for scripts
sudo tail -f /var/log/lull/lulld.log
```

`lullctl` is at `/Library/Application Support/Lull/bin/lullctl`, with a
shortcut in `/usr/local/bin` where that folder is writable only by root.

| Situation | What to do |
|---|---|
| Pause Lull for some Macs | Scope them a settings profile with **Enabled** off |
| School holidays | Add a **Date exception** with Mode **Skip** |
| A student needs their Mac during downtime | Use the admin override, or exempt their username |
| A Mac is in *Lull unhealthy* | Look at its extension attribute value; reinstall the package if Lull is missing |

## Upgrading

Upload the new package to Jamf and point your policy at it. Lull restarts with
the new version for everyone logged in. If that happens during downtime, the
lock screen disappears for a few seconds. Settings, the passphrase and override
lockouts are kept. Check the release notes for new settings, and paste the new
`jamf-custom-schema.json` into your settings profile if it changed.

## Removing Lull

1. Remove the settings and login items profiles from the Macs' scope.
2. Run a policy with Files and Processes > Execute Command:
   ```
   "/Library/Application Support/Lull/bin/uninstall.sh" --purge
   ```
   `--purge` also deletes Lull's state, passphrase and logs.
3. Exclude those Macs from the *Lull unhealthy* Smart Group, as they will now
   report `ERROR: not installed`.

## Troubleshooting

Start with `lullctl status`; it says which settings Lull is using and why it
is or isn't locking.

| Symptom | Likely cause |
|---|---|
| No warning or lock at the expected time | Check the time zone, and that the day is in the schedule's **Days**: the day a window *starts*. Check the user isn't exempt (admins are, by default) |
| `source=none` in `lullctl status` | The settings profile hasn't arrived, or is scoped to users instead of computers |
| Settings listed as "not enforced by a profile" | They were written some other way, such as `defaults write`. Lull only reads configuration profiles |
| Lull can be turned off in Login Items | The login items profile isn't installed |
| Locked earlier than expected after a restart | The Mac was offline with its clock ahead. Lull never moves its time backwards without the network, and corrects itself once online |
| `xpc_peer_pin_unavailable` in the log | The install folder's ownership was changed; reinstall the package |
