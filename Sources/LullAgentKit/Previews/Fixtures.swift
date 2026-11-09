#if DEBUG
    import AppKit
    import LullCore

    /// Sample data for previews, snapshot tests and the Debug demo mode.
    /// Generic art only: no school names or contact details.
    public enum Fixtures {
        /// Mon 2026-10-05 22:00 AEDT, half an hour into a 21:30-06:30 window.
        public static let lockedNow = date("2026-10-05T11:00:00Z")
        public static let windowStart = date("2026-10-05T10:30:00Z")
        public static let windowEnd = date("2026-10-05T19:30:00Z")

        static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

        public static var brandedAppearance: Appearance {
            var a = Appearance()
            a.bannerHeight = 160
            a.cardWidth = 600
            a.cardCornerRadius = 18
            a.backgroundStyle = .blur
            a.backgroundColor = ThemedColor("#0B1F3A")
            a.backgroundOpacity = 0.7
            a.titleColor = ThemedColor("#0B1F3A", dark: "#F2F5FA")
            a.bodyColor = ThemedColor("#33415C", dark: "#C9D2E3")
            a.accentColor = ThemedColor("#1F7A8C", dark: "#3FB0C4")
            a.countdownColor = ThemedColor("#1F7A8C", dark: "#3FB0C4")
            a.progressTrackColor = ThemedColor("#E1E8EF", dark: "#2B3A52")
            a.cardBackgroundColor = ThemedColor("#FFFFFF", dark: "#14223A")
            a.showBannerInWarning = true
            a.warningCardPosition = .topRight
            return a
        }

        /// Demo mode shows the built-in defaults, i.e. exactly what a school sees
        /// before setting any Texts keys ("your school", "your IT team").
        public static var demoTexts: Texts { Texts() }

        /// Previews of a school that has set only the two branding values.
        public static var configuredTexts: Texts {
            var t = Texts()
            t.organizationName = "Example College"
            t.supportContact = "the IT Service Desk"
            return t
        }

        public static func lockedState(branded: Bool = true, now: Date = lockedNow, texts: Texts = Texts()) -> DisplayState {
            DisplayState(
                phase: .locked, trustedNow: now, windowStart: windowStart, windowEnd: windowEnd, lockStart: windowStart,
                scheduleName: "School night", overrideAvailable: true, shutdownAvailable: true,
                timeZoneIdentifier: "Australia/Sydney", appearance: branded ? brandedAppearance : Appearance(),
                texts: texts)
        }

        public static func warningState(
            secondsToLock: TimeInterval, branded: Bool = true, snooze: Bool = true, texts: Texts = Texts()
        ) -> DisplayState {
            DisplayState(
                phase: .warning, trustedNow: windowStart.addingTimeInterval(-secondsToLock), windowStart: windowStart,
                windowEnd: windowEnd, lockStart: windowStart, scheduleName: "School night", showWarningCard: true,
                inFinalCountdown: secondsToLock <= 60, finalCountdownSeconds: 60, snoozeAvailable: snooze,
                timeZoneIdentifier: "Australia/Sydney", appearance: branded ? brandedAppearance : Appearance(),
                texts: texts)
        }

        /// Locked without a window: LockUntilSynced after an offline boot.
        public static var awaitingSyncState: DisplayState {
            DisplayState(
                phase: .locked, trustedNow: lockedNow, overrideAvailable: true, timeZoneIdentifier: "Australia/Sydney")
        }

        public static var brandedImages: BrandingImages {
            BrandingImages(banner: makeBanner(), logo: makeLogo())
        }

        /// A generated banner (gradient + soft shapes) standing in for an admin image.
        public static func makeBanner(size: NSSize = NSSize(width: 1200, height: 320)) -> NSImage {
            NSImage(size: size, flipped: false) { rect in
                NSGradient(
                    colors: [
                        NSColor(srgbRed: 0.04, green: 0.12, blue: 0.23, alpha: 1),
                        NSColor(srgbRed: 0.12, green: 0.48, blue: 0.55, alpha: 1),
                    ])!.draw(in: rect, angle: 20)
                NSColor(white: 1, alpha: 0.08).setFill()
                for i in 0..<6 {
                    let d = CGFloat(140 + i * 70)
                    NSBezierPath(ovalIn: NSRect(x: rect.maxX - d * 0.9, y: rect.minY - d * 0.35, width: d, height: d)).fill()
                }
                // A crescent moon.
                NSColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 0.95).setFill()
                let moon = NSBezierPath(ovalIn: NSRect(x: rect.width * 0.12, y: rect.height * 0.42, width: 90, height: 90))
                moon.fill()
                NSGradient(
                    colors: [
                        NSColor(srgbRed: 0.05, green: 0.16, blue: 0.29, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.22, blue: 0.35, alpha: 1),
                    ]
                )!.draw(
                    in: NSBezierPath(ovalIn: NSRect(x: rect.width * 0.12 + 28, y: rect.height * 0.42 + 18, width: 90, height: 90)),
                    angle: 20)
                return true
            }
        }

        /// A generic mark (moon in a rounded square) standing in for a school logo.
        public static func makeLogo(size: NSSize = NSSize(width: 88, height: 88)) -> NSImage {
            NSImage(size: size, flipped: false) { rect in
                let square = rect.insetBy(dx: 8, dy: 8)
                NSColor(srgbRed: 0.12, green: 0.48, blue: 0.55, alpha: 1).setFill()
                NSBezierPath(roundedRect: square, xRadius: 16, yRadius: 16).fill()
                let disc = square.insetBy(dx: 16, dy: 16)
                NSColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 1).setFill()
                NSBezierPath(ovalIn: disc).fill()
                // Bite out of the disc in the background colour makes the crescent.
                NSColor(srgbRed: 0.12, green: 0.48, blue: 0.55, alpha: 1).setFill()
                NSBezierPath(ovalIn: disc.offsetBy(dx: 11, dy: 7)).fill()
                return true
            }
        }
    }
#endif
