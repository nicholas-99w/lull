#!/usr/bin/env python3
"""Generates Config/jamf-custom-schema.json (Jamf Pro Application & Custom Settings).

Run from the repo root:  python3 Scripts/dev/gen-jamf-schema.py
Tests/LullCoreTests/ShippedConfigTests.swift checks the result against the
parser (same keys; defaults equal Lull's own defaults), so edit here, not the JSON.

Format: Jamf-documented subset (title, description, type, enum +
options.enum_titles, default, items, pattern, property_order, required,
options.infoText, links) plus widely used json-editor features (minimum/maximum,
nested objects, options.remove_empty_properties). See __notes in the output.
"""
import json, collections

DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
HHMM = "^([01][0-9]|2[0-3]):[0-5][0-9]$"
DATE = "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
HEX = "^#?([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"

order = [0]
def nxt():
    order[0] += 5
    return order[0]

def prop(key, title, desc, typ, default=None, enum=None, titles=None, minimum=None, maximum=None, pattern=None, items=None, props=None, required=None):
    p = collections.OrderedDict()
    p["title"] = title
    p["description"] = desc
    p["property_order"] = nxt()
    p["type"] = typ
    if enum: p["enum"] = enum
    if default is not None: p["default"] = default
    if minimum is not None: p["minimum"] = minimum
    if maximum is not None: p["maximum"] = maximum
    if pattern: p["pattern"] = pattern
    if items: p["items"] = items
    if props: p["properties"] = props
    if required: p["required"] = required
    opts = collections.OrderedDict()
    if titles: opts["enum_titles"] = titles
    opts["infoText"] = f"Key name: {key}"
    p["options"] = opts
    return key, p

def obj(*pairs): return collections.OrderedDict(pairs)

def colour(key, title, default_light, default_dark=None):
    d = f"Hex colour (#RRGGBB or #RRGGBBAA). Leave empty for Lull's default ({default_light}"
    d += f", dark {default_dark})." if default_dark else ")."
    return [prop(key, title, d, "string", pattern=HEX),
            prop(key + "Dark", title + " (dark mode)", "Optional dark-appearance variant. If empty, the light colour is used in both.", "string", pattern=HEX)]

schedule_item = obj(
    ("type", "object"), ("title", "Schedule"),
    ("required", ["Days", "Start", "End"]),
    ("properties", obj(
        prop("Name", "Name", "Shown with {{scheduleName}}, e.g. School night.", "string"),
        prop("Days", "Days", "Days on which the window STARTS.", "array",
             items=obj(("type", "string"), ("title", "Day"), ("enum", DAYS),
                       ("options", obj(("enum_titles", ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]))))),
        prop("Start", "Start (HH:mm)", "24-hour time, e.g. 21:30.", "string", pattern=HHMM),
        prop("End", "End (HH:mm)", "24-hour time. If End is at or before Start, the window ends the next day.", "string", pattern=HHMM),
        prop("WarningMinutes", "Warning minutes (this schedule)", "Optional. Overrides the global notice period for this schedule.", "integer", minimum=0, maximum=240),
    )))

exception_item = obj(
    ("type", "object"), ("title", "Date exception"),
    ("required", ["StartDate", "EndDate", "Mode"]),
    ("properties", obj(
        prop("StartDate", "Start date (YYYY-MM-DD)", "First date, inclusive.", "string", pattern=DATE),
        prop("EndDate", "End date (YYYY-MM-DD)", "Last date, inclusive.", "string", pattern=DATE),
        prop("Mode", "Mode", "Skip: no downtime starts on these dates. AllDay: locked all day.", "string",
             enum=["Skip", "AllDay"], titles=["Skip (no downtime)", "All day (locked 24h)"], default="Skip"),
        prop("Note", "Note", "For admins, e.g. Summer holidays.", "string"),
    )))

appearance = obj(
    prop("BannerImagePath", "Banner image", "File name in /Library/Application Support/Lull/Branding/ (deploy separately).", "string"),
    prop("BannerHeight", "Banner height (pt)", "0-600.", "integer", default=180, minimum=0, maximum=600),
    prop("BannerContentMode", "Banner scaling", "", "string", enum=["fill", "fit"], titles=["Fill (crop)", "Fit"], default="fill"),
    prop("LogoImagePath", "Logo image", "File name in the Branding folder.", "string"),
    prop("BackgroundStyle", "Background style", "", "string", enum=["Blur", "Solid", "Image"], titles=["Blurred desktop", "Solid colour", "Image"], default="Blur"),
    *colour("BackgroundColor", "Background colour", "#000000"),
    prop("BackgroundOpacity", "Background opacity", "0 to 1.", "number", default=0.85, minimum=0, maximum=1),
    prop("BackgroundImagePath", "Background image", "File name in the Branding folder (for the Image style).", "string"),
    *colour("CardBackgroundColor", "Card background colour", "#FFFFFF", "#1C1C1E"),
    prop("CardCornerRadius", "Card corner radius", "0-64.", "integer", default=16, minimum=0, maximum=64),
    prop("CardWidth", "Card width (pt)", "320-1200.", "integer", default=640, minimum=320, maximum=1200),
    *colour("TitleColor", "Title colour", "#1D1D1F", "#F5F5F7"),
    *colour("BodyColor", "Body text colour", "#3A3A3C", "#D1D1D6"),
    *colour("AccentColor", "Accent colour", "#0A84FF"),
    *colour("CountdownColor", "Countdown colour", "#1D1D1F", "#F5F5F7"),
    *colour("ProgressTrackColor", "Progress track colour", "#E5E5EA", "#3A3A3C"),
    prop("FontName", "Font", "PostScript name of an installed font. Empty = system font.", "string"),
    prop("TitleFontSize", "Title font size", "10-96.", "integer", default=28, minimum=10, maximum=96),
    prop("BodyFontSize", "Body font size", "8-64.", "integer", default=15, minimum=8, maximum=64),
    prop("ShowCountdown", "Show countdown", "", "boolean", default=True),
    prop("ShowProgress", "Show progress bar", "", "boolean", default=True),
    prop("ShowBannerInWarning", "Show banner on warning card", "", "boolean", default=False),
    prop("WarningCardPosition", "Warning card position", "", "string", enum=["TopCenter", "TopRight", "Center"], titles=["Top centre", "Top right", "Centre"], default="TopCenter"),
)

TOKENS = "Tokens: {{startTime}} {{endTime}} {{minutesRemaining}} {{secondsRemaining}} {{scheduleName}} {{firstName}} {{organizationName}} {{supportContact}}."
def text(key, title, default):
    return prop(key, title, f"Empty = default: \"{default}\". {TOKENS}" if default else f"Empty = hidden. {TOKENS}", "string")

texts = obj(
    prop("OrganizationName", "Organisation name", "Used by {{organizationName}} in the default messages. Empty = \"your school\".", "string"),
    prop("SupportContact", "Support contact", "Used by {{supportContact}}, e.g. \"the IT Service Desk (ext. 1234)\". Empty = \"your IT team\".", "string"),
    text("WarningTitle", "Warning title", "Downtime starts soon"),
    text("WarningMessage", "Warning message", "This Mac will lock at {{startTime}}. Please save your work."),
    text("LockedTitle", "Lock screen title", "Time to unplug"),
    text("LockedMessage", "Lock screen message", "Devices at {{organizationName}} are unavailable during downtime hours."),
    text("UnlockLabel", "Unlock label", "Back online at {{endTime}}"),
    text("FooterText", "Footer", ""),
    text("SupportText", "Support text", "Need help? Contact {{supportContact}}."),
    text("OverrideButtonLabel", "Override link label", "Admin override"),
    text("SnoozeButtonLabel", "Snooze button label", "Snooze"),
    text("ShutdownButtonLabel", "Shut Down button label", "Shut Down"),
)

portal = obj(
    prop("URL", "Portal URL", "https URL of your Lull portal, e.g. https://lull.example.edu.au. Empty = portal management off: this profile's Schedules apply.", "string",
         pattern="^https://"),
    prop("PollIntervalSeconds", "Check-in interval (seconds)", "How often the Mac fetches portal settings and reports its status. 60-3600.", "integer", default=300, minimum=60, maximum=3600),
)

order[0] = 0
properties = obj(
    prop("Enabled", "Enabled", "Master switch. Off = never lock.", "boolean", default=True),
    prop("Timezone", "Time zone", "IANA name, e.g. Australia/Sydney. All schedule times use this, never the Mac's own time zone.", "string", default="Australia/Sydney"),
    prop("Schedules", "Schedules", "Downtime windows.", "array", items=schedule_item),
    prop("DateExceptions", "Date exceptions", "Holidays (Skip) and full-day downtime (AllDay).", "array", items=exception_item),
    prop("WarningMinutes", "Warning minutes", "Notice period before each lock. 0 = no warning.", "integer", default=15, minimum=0, maximum=240),
    prop("WarningIntervalsMinutes", "Warning card at (minutes before)", "The warning card appears for ~20s at each of these.", "array",
         default=[15, 10, 5, 2, 1], items=obj(("type", "integer"), ("title", "Minutes"), ("minimum", 1))),
    prop("FinalCountdownSeconds", "Final countdown (seconds)", "Persistent countdown before the lock.", "integer", default=60, minimum=0, maximum=600),
    prop("SnoozeEnabled", "Allow snooze", "", "boolean", default=False),
    prop("SnoozeMinutes", "Snooze minutes", "", "integer", default=10, minimum=1, maximum=120),
    prop("MaxSnoozesPerWindow", "Snoozes per window", "", "integer", default=1, minimum=0, maximum=10),
    prop("ExemptUsernames", "Exempt users", "Short user names never locked.", "array", items=obj(("type", "string"), ("title", "User name"))),
    prop("ExemptAdminUsers", "Exempt admin users", "Members of the local admin group are never locked.", "boolean", default=True),
    prop("OverrideEnabled", "Allow admin override", "", "boolean", default=True),
    prop("OverrideDurationMinutes", "Override duration (minutes)", "", "integer", default=30, minimum=1, maximum=720),
    prop("OverrideMaxAttempts", "Override attempts before lockout", "", "integer", default=5, minimum=1, maximum=100),
    prop("OverrideLockoutMinutes", "Override lockout (minutes)", "", "integer", default=15, minimum=1, maximum=1440),
    prop("OverridePasswordHash", "Override passphrase hash", "From `lullctl hash-passphrase`. Readable by local users: prefer the root-only /var/db/lull/override.json and leave this empty.", "string",
         pattern="^pbkdf2-sha256\\$[0-9]+\\$[A-Za-z0-9+/=]+\\$[A-Za-z0-9+/=]+$"),
    prop("TimeServers", "Time servers", "SNTP servers, in order. Empty = time.apple.com.", "array", items=obj(("type", "string"), ("title", "Server"))),
    prop("TimeSyncIntervalMinutes", "Time sync interval (minutes)", "", "integer", default=60, minimum=5, maximum=1440),
    prop("MaxClockDriftSeconds", "Clock tamper threshold (seconds)", "", "integer", default=30, minimum=5, maximum=3600),
    prop("OfflineBootPolicy", "After an offline reboot", "", "string", enum=["ForwardOnly", "LockUntilSynced"],
         titles=["Time only moves forward (may lock early)", "Stay locked until time is synced"], default="ForwardOnly"),
    prop("FallbackActionIfAgentMissing", "If the lock screen can't be restored", "", "string", enum=["SleepDisplay", "None"],
         titles=["Sleep the display", "Do nothing"], default="SleepDisplay"),
    prop("AgentMissingGraceSeconds", "Lock screen restore grace (seconds)", "", "integer", default=5, minimum=1, maximum=120),
    prop("ShowShutdownButton", "Show Shut Down button", "Forced shutdown, with a lost-work warning and a Sleep alternative.", "boolean", default=True),
    prop("Appearance", "Appearance", "Lock screen and warning card styling.", "object", props=appearance),
    prop("Texts", "Texts", "Lock screen and warning wording.", "object", props=texts),
    prop("Portal", "Parent portal", "Optional. Lets parents (and IT) opt this Mac out and set its school-night and weekend times in the Lull portal. Enabled = false here still wins; DateExceptions stay school-wide. Until the Mac first reaches the portal, Schedules above apply.", "object", props=portal),
)

schema = obj(
    ("title", "Lull (au.com.nickit.lull)"),
    ("description", "Scheduled device-free hours. Preference domain: au.com.nickit.lull. Scope to computers. Empty fields use Lull's defaults."),
    ("__preferencedomain", "au.com.nickit.lull"),
    ("__version", "1.0"),
    ("__notes", [
        "Generated by Scripts/dev/gen-jamf-schema.py; do not edit by hand.",
        "Verified against Jamf docs (developer.jamf.com/jamf-pro/docs/application-custom-settings, 2026-10): title, description, type, enum + options.enum_titles, default, items, pattern, property_order, required, options.infoText.",
        "Community/json-editor convention, VERIFY in your Jamf Pro: minimum/maximum, nested objects (Appearance, Texts), options.remove_empty_properties, number vs integer plist types.",
        "Jamf writes default values for untouched fields; they equal Lull's built-in defaults, so they change nothing. Lull treats empty strings as not set.",
    ]),
    ("options", obj(("remove_empty_properties", True))),
    ("required", ["Timezone", "Schedules"]),
    ("properties", properties),
)

with open("Config/jamf-custom-schema.json", "w") as f:
    json.dump(schema, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("wrote Config/jamf-custom-schema.json")
