#if DEBUG
    import AppKit
    import LullCore
    import os

    /// Debug-only state source for demo mode (`Lull --demo ...`): drives the real
    /// windows from a scripted timeline so the UI can be checked on a test Mac
    /// without the daemon. Never performs a real shutdown.
    @MainActor
    public final class MockDisplayStateSource: DisplayStateSource {
        public enum Scenario: String, CaseIterable {
            /// Warning card (0-20s), quiet (20-60s), final countdown (60-120s),
            /// locked (lockDuration), then normal.
            case cycle
            case warning
            case locked
            /// Locked with no window (LockUntilSynced after an offline boot).
            case awaiting
        }

        public var onUpdate: ((DisplayState) -> Void)?
        public var presentingCheck: (() -> Bool)?
        let scenario: Scenario
        let appearance: Appearance
        let texts: Texts
        let lockDuration: TimeInterval
        private let log = Logger(subsystem: LullConstants.logSubsystem, category: "agent")
        private let startedAt = Date()
        private let uptimeAtStart = ProcessInfo.processInfo.systemUptime
        private var lockStart: Date
        private var windowEnd: Date
        private var snoozes = 0
        private var overrideUntil: Date?
        private var failures = 0
        private var lockedOutUntil: Date?
        private var timer: Timer?

        /// The demo accepts this passphrase.
        public static let demoPassphrase = "lull"

        public init(
            scenario: Scenario, appearance: Appearance = Fixtures.brandedAppearance, texts: Texts = Fixtures.demoTexts,
            lockDuration: TimeInterval = 180
        ) {
            self.scenario = scenario
            self.appearance = appearance
            self.texts = texts
            self.lockDuration = lockDuration
            switch scenario {
            case .cycle: lockStart = startedAt.addingTimeInterval(120)
            case .warning: lockStart = startedAt.addingTimeInterval(16 * 60)
            case .locked, .awaiting: lockStart = startedAt.addingTimeInterval(-60)
            }
            windowEnd = lockStart.addingTimeInterval(lockDuration)
        }

        var now: Date { startedAt.addingTimeInterval(ProcessInfo.processInfo.systemUptime - uptimeAtStart) }

        public func start() {
            log.log("DEBUG demo mode: \(self.scenario.rawValue, privacy: .public)")
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            publish()
        }

        public func refresh() { publish() }

        public func requestSnooze() {
            guard snoozes == 0 else { return }
            snoozes += 1
            lockStart = lockStart.addingTimeInterval(60)
            publish()
        }

        public func attemptOverride(passphrase: String, completion: @escaping (OverrideResult) -> Void) {
            let now = self.now
            // Simulate the daemon's PBKDF2 time so the "Checking…" state is visible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                let result: OverrideResult
                if let until = lockedOutUntil, now < until {
                    result = .lockedOut(until: until)
                } else if passphrase == Self.demoPassphrase {
                    failures = 0
                    overrideUntil = now.addingTimeInterval(60)
                    result = .granted(until: overrideUntil!)
                } else {
                    failures += 1
                    if failures >= 3 {
                        failures = 0
                        lockedOutUntil = now.addingTimeInterval(30)
                        result = .lockedOut(until: lockedOutUntil!)
                    } else {
                        result = .rejected(attemptsRemaining: 3 - failures)
                    }
                }
                completion(result)
                publish()
            }
        }

        public func requestShutdown() {
            log.log("DEBUG demo: shutdown requested (not performed)")
            NSSound.beep()
        }

        public func requestSleep() {
            log.log("DEBUG demo: sleep requested (not performed)")
            NSSound.beep()
        }

        func state(at now: Date) -> DisplayState {
            var s = DisplayState(
                phase: .normal, trustedNow: now, windowStart: lockStart, windowEnd: windowEnd, lockStart: lockStart,
                scheduleName: "Demo", finalCountdownSeconds: 60, overrideAvailable: true, shutdownAvailable: true,
                timeZoneIdentifier: TimeZone.current.identifier, appearance: appearance, texts: texts)
            if scenario == .awaiting {
                s.windowStart = nil
                s.windowEnd = nil
                s.lockStart = nil
                s.phase = .locked
            } else if now >= lockStart && now < windowEnd {
                s.phase = .locked
            } else if now < lockStart && lockStart.timeIntervalSince(now) <= 15 * 60 {
                let remaining = lockStart.timeIntervalSince(now)
                s.phase = .warning
                s.inFinalCountdown = remaining <= 60
                // Card for the first 20s of the demo, then the final countdown.
                s.showWarningCard = s.inFinalCountdown || now.timeIntervalSince(startedAt) < 20
                s.snoozeAvailable = snoozes == 0
            }
            if s.phase == .locked, let until = overrideUntil, now < until {
                s.phase = .overridden
            }
            return s
        }

        private func publish() { onUpdate?(state(at: now)) }
    }
#endif
