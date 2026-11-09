# Configuration guide

Lull is configured by one configuration profile: managed preferences for the
domain **`au.com.nickit.lull`**, scoped to **computers**. This guide explains
how settings work, gives recipes for common timetables, and lists every
setting. The look and wording of the lock screen are covered in the
[Appearance guide](APPEARANCE.md).

- [How settings work](#how-settings-work)
- [Recipes](#recipes)
- [Reference](#reference): [General](#general) · [Schedules](#schedules) ·
  [Date exceptions](#date-exceptions) · [Warnings and snooze](#warnings-and-snooze) ·
  [Who is locked](#who-is-locked) · [Admin override](#admin-override) ·
  [Time](#time) · [Enforcement](#enforcement) ·
  [Appearance and texts](#appearance-and-texts) · [Parent portal](#parent-portal)

## How settings work

**Creating the profile.** In Jamf Pro, use **Application & Custom Settings**
with the custom schema from the release's Jamf kit (see the
[Deployment guide](DEPLOYMENT.md#4-settings-profile)). Jamf then shows a form;
the *Form label* column below gives each setting's name there. You can also
edit `profiles/au.com.nickit.lull.mobileconfig` from the kit, which contains
every setting with sample values.

**Only a profile counts.** Settings written any other way, such as with
`defaults write`, are ignored, and `lullctl status` lists them as
*not enforced by a profile*.

**Empty means default.** You only need to fill in what you want to change.

**Changes apply within seconds** of the profile reaching the Mac, without a
restart.

**Mistakes are handled safely.**

| Problem | What happens |
|---|---|
| No schedules, a schedule or date exception that can't be read, or an unknown option for *After an offline reboot* or *If the lock screen can't be restored* | The profile is **rejected**. Lull keeps using the last good profile. If there has never been one, Lull doesn't lock |
| A value of the wrong type, a bad colour, a missing image, an unknown setting | That value uses its default |
| A number out of range | It's clamped to the nearest allowed value |
| Missing or unknown time zone | The last good time zone, otherwise `Australia/Sydney` |

Every problem is reported by `lullctl status` and the *Lull Status* extension
attribute.

**Check a profile before you deploy it.** Save the settings as a plist (the
`mcx_preference_settings` dictionary of a `.mobileconfig`), then on any Mac
with Lull installed run:

```
"/Library/Application Support/Lull/bin/lullctl" validate-config settings.plist
```

It lists every error and warning, and exits with status 1 if the profile would
be rejected.

## Recipes

Values are shown as *Form label*: value. Anything not mentioned keeps its
default.

### School nights

Locked from 9:30 pm until 6:30 am before each school day:

- *Time zone*: `Australia/Sydney`
- *Schedules* → *Name*: `School night`, *Days*: Sun, Mon, Tue, Wed, Thu,
  *Start*: `21:30`, *End*: `06:30`

A window belongs to the day it **starts**, so Sunday night is listed under Sun,
and the Thursday window ends on Friday morning.

### Later on weekends

Add a second schedule:

- *Name*: `Weekend`, *Days*: Fri, Sat, *Start*: `23:00`, *End*: `07:00`

### School holidays

- *Date exceptions* → *Start date*: `2026-12-18`, *End date*: `2027-01-27`,
  *Mode*: Skip, *Note*: `Summer holidays`

No window starts on those dates. A window that began the night before the
first date still ends the next morning as usual.

### A device-free day

- *Date exceptions* → *Start date*: `2026-11-20`, *End date*: `2026-11-20`,
  *Mode*: All day, *Note*: `Device-free day`

Locked from midnight to midnight, joined up with any windows either side.

### A homework block after school

- *Name*: `Homework break`, *Days*: Mon–Thu, *Start*: `18:00`, *End*: `19:00`

Schedules can overlap or touch; they merge into one lock.

### Allow a snooze

- *Allow snooze*: on, *Snooze minutes*: `10`, *Snoozes per window*: `1`

### Never lock staff

- *Exempt users*: `itadmin`, `jsmith` (short user names)
- *Exempt admin users*: on (the default)

### Shorter notice

- *Warning minutes*: `5`, *Warning card at*: `5, 1`

### Pause Lull for some Macs

Scope those Macs a profile with *Enabled* off. They stop locking within seconds.

### Stricter after an offline restart

- *After an offline reboot*: Stay locked until time is synced

If a Mac restarts during downtime without a network connection, it stays
locked (the admin override still works) until it can confirm the time online.

## Reference

### General

| Key | Form label | Type | Default | Notes |
|---|---|---|---|---|
| `Enabled` | Enabled | bool | on | Off: Lull never locks |
| `Timezone` | Time zone | string | `Australia/Sydney` | An IANA name, such as `Australia/Perth`, `Pacific/Auckland` or `Europe/London`. **All times use this**, never the Mac's own time zone |
| `Schedules` | Schedules | list | required | See [Schedules](#schedules) |
| `DateExceptions` | Date exceptions | list | none | See [Date exceptions](#date-exceptions) |

### Schedules

Each entry in `Schedules`:

| Key | Form label | Type | Notes |
|---|---|---|---|
| `Name` | Name | string | Optional; shown on screen with `{{scheduleName}}` |
| `Days` | Days | list of `Mon` `Tue` `Wed` `Thu` `Fri` `Sat` `Sun` | The days the window **starts**. Required |
| `Start` | Start (HH:mm) | `HH:mm` | 24-hour, such as `21:30`. Required |
| `End` | End (HH:mm) | `HH:mm` | At or before *Start*: ends the next day. Equal to *Start*: 24 hours. Required |
| `WarningMinutes` | Warning minutes (this schedule) | 0–240 | Optional; replaces the global *Warning minutes* for this schedule |

**Daylight saving** is handled. A window over the night the clocks go forward
is an hour shorter; over the night they go back, an hour longer. A start time
that doesn't exist that night starts at the first valid time after it.

### Date exceptions

Each entry in `DateExceptions`:

| Key | Form label | Type | Notes |
|---|---|---|---|
| `StartDate` | Start date | `YYYY-MM-DD` | First date, inclusive. Required |
| `EndDate` | End date | `YYYY-MM-DD` | Last date, inclusive. Required |
| `Mode` | Mode | `Skip` \| `AllDay` | **Skip**: no window starts on these dates. **AllDay**: locked from midnight to midnight on each date. AllDay wins if a date has both. Required |
| `Note` | Note | string | For your reference; also shown as the schedule name on AllDay dates |

### Warnings and snooze

| Key | Form label | Type | Default | Range | Notes |
|---|---|---|---|---|---|
| `WarningMinutes` | Warning minutes | int | 15 | 0–240 | Notice before each lock. 0: no warning |
| `WarningIntervalsMinutes` | Warning card at (minutes before) | list of int | 15, 10, 5, 2, 1 | ≥ 1 | The card shows for about 20 seconds at each. Values above *Warning minutes* are ignored |
| `FinalCountdownSeconds` | Final countdown (seconds) | int | 60 | 0–600 | The card stays up with a live countdown for the last N seconds |
| `SnoozeEnabled` | Allow snooze | bool | off | | Adds a Snooze button to the warning card |
| `SnoozeMinutes` | Snooze minutes | int | 10 | 1–120 | Never past the end of the window |
| `MaxSnoozesPerWindow` | Snoozes per window | int | 1 | 0–10 | |

### Who is locked

| Key | Form label | Type | Default | Notes |
|---|---|---|---|---|
| `ExemptUsernames` | Exempt users | list of string | none | Short user names that are never locked (not case-sensitive) |
| `ExemptAdminUsers` | Exempt admin users | bool | on | Members of the Mac's `admin` group are never locked. **Test with a standard account**, or turn this off |

With fast user switching, each logged-in user is handled separately.

### Admin override

| Key | Form label | Type | Default | Range | Notes |
|---|---|---|---|---|---|
| `OverrideEnabled` | Allow admin override | bool | on | | Shows *Admin override* on the lock screen when a passphrase is set |
| `OverrideDurationMinutes` | Override duration (minutes) | int | 30 | 1–720 | How long the right passphrase unlocks the Mac for. It locks again afterwards, unless downtime has ended |
| `OverrideMaxAttempts` | Override attempts before lockout | int | 5 | 1–100 | |
| `OverrideLockoutMinutes` | Override lockout (minutes) | int | 15 | 1–1440 | Survives restarts and clock changes |
| `OverridePasswordHash` | Override passphrase hash | string | none | | From `lullctl hash-passphrase` |

Lull never stores the passphrase itself, only a slow, salted hash. The
recommended way to set it is a script that stores it where only root can read
it (see the [Deployment guide](DEPLOYMENT.md#5-override-passphrase-optional)).
If you use `OverridePasswordHash` instead, remember that profiles can be read
on the Mac: use a long passphrase of four or more random words. If both are
set, the root-only file wins.

### Time

Lull keeps its own clock. It's synced from the network when possible, but
locking never depends on the network, and changing the Mac's clock or time
zone has no effect.

| Key | Form label | Type | Default | Range | Notes |
|---|---|---|---|---|---|
| `TimeServers` | Time servers | list of string | `time.apple.com` | | NTP servers, tried in order. If none answers sensibly, Lull checks the time over HTTPS with apple.com |
| `TimeSyncIntervalMinutes` | Time sync interval (minutes) | int | 60 | 5–1440 | Retried every minute after a failure |
| `MaxClockDriftSeconds` | Clock tamper threshold (seconds) | int | 30 | 5–3600 | A change to the Mac's clock bigger than this is logged as tampering |
| `OfflineBootPolicy` | After an offline reboot | `ForwardOnly` \| `LockUntilSynced` | `ForwardOnly` | | **ForwardOnly**: after a restart without network, Lull's clock never goes backwards, so it may lock a little early but never late. **LockUntilSynced**: stays locked until the time is confirmed online |

### Enforcement

| Key | Form label | Type | Default | Range | Notes |
|---|---|---|---|---|---|
| `AgentMissingGraceSeconds` | Lock screen restore grace (seconds) | int | 5 | 1–120 | How long the lock screen may be missing before Lull restarts it |
| `FallbackActionIfAgentMissing` | If the lock screen can't be restored | `SleepDisplay` \| `None` | `SleepDisplay` | | If the lock screen can't be brought back, Lull keeps putting the display to sleep, and then the Mac. This only happens when something is fighting Lull |
| `ShowShutdownButton` | Show Shut Down button | bool | on | | Shut Down on the lock screen. It asks first, and offers **Sleep** instead, which keeps apps and documents open |

### Appearance and texts

The `Appearance` and `Texts` settings are described in the
[Appearance guide](APPEARANCE.md#reference).

### Parent portal

Optional. With a portal URL set, the Mac also registers with
[lull-portal](https://github.com/nicholas-99w/lull-portal) (see the
[Deployment guide](DEPLOYMENT.md#parent-portal-optional)).

| Key | Form label | Type | Default | Range | Notes |
|---|---|---|---|---|---|
| `Portal.URL` | Portal URL | string | empty (off) | `https://` only | Empty: the portal is off. A bad URL turns the portal off with a warning; it never rejects the profile |
| `Portal.PollIntervalSeconds` | Check-in interval (seconds) | int | 300 | 60–3600 | How often the Mac fetches its settings. A parent's *Lock down now* starts at the next check-in, so use 60–120 if it should feel immediate |

How the portal and the profile combine:

- Your `Schedules` are the baseline. Parents can opt out of, or change, school
  nights (windows starting Sunday to Thursday) and weekends (Friday and
  Saturday) separately. Anything they don't change follows your schedules.
- Parents can also *Lock down now* (for at most 24 hours) and release downtime
  that's in progress. The next scheduled window still locks.
- School hours, set by IT in the portal, are off limits to parents.
- `Enabled = false` in the profile always wins. Holidays (`DateExceptions`),
  appearance, texts and the override stay in the profile.
- The Mac keeps the last settings it received. Being offline, or blocking the
  portal, doesn't change when it locks.
