import Foundation

/// Pure scheduling decisions, so they're easy to test.
public enum LoopScheduler {
    /// Loops whose clock schedule says they should run now.
    public static func dueLoops(_ loops: [LoopDefinition], state: Store.LoopState, now: Date,
                                calendar: Calendar = .current) -> [LoopDefinition] {
        loops.filter { loop in
            guard loop.enabled, let schedule = loop.schedule else { return false }
            let since = state.lastRun[loop.id] ?? state.firstSeen[loop.id] ?? now
            return schedule.isDue(now: now, lastRun: since, catchUp: loop.catchUp, calendar: calendar)
        }
    }

    /// Loops that react to a Mac event (launch / wake / unlock).
    /// `minGap` stops a loop from firing twice when wake and unlock happen back to back.
    public static func loops(for trigger: LoopTrigger, in loops: [LoopDefinition], state: Store.LoopState,
                             now: Date, minGap: TimeInterval = 15 * 60) -> [LoopDefinition] {
        loops.filter { loop in
            guard loop.enabled, loop.triggers.contains(trigger) else { return false }
            if let last = state.lastRun[loop.id], now.timeIntervalSince(last) < minGap { return false }
            return true
        }
    }

    /// Loops chained to run after `finished` (matched by id, file name or name). `minGap` stops A→B→A cycles.
    public static func loops(after finished: LoopDefinition, in loops: [LoopDefinition], state: Store.LoopState,
                             now: Date, minGap: TimeInterval = 10 * 60) -> [LoopDefinition] {
        loops.filter { loop in
            guard loop.enabled, loop.id != finished.id else { return false }
            let names = loop.after.map { $0.lowercased() }
            guard names.contains(finished.id.lowercased()) || names.contains(finished.fileStem.lowercased())
                    || names.contains(finished.name.lowercased()) else { return false }
            if let last = state.lastRun[loop.id], now.timeIntervalSince(last) < minGap { return false }
            return true
        }
    }

    /// True when a loop has used up its `max_runs_per_day` of automatic runs today.
    public static func hitDailyLimit(_ loop: LoopDefinition, runs: [LoopRun], now: Date, calendar: Calendar = .current) -> Bool {
        guard let limit = loop.maxRunsPerDay else { return false }
        let automatic: Set<RunTrigger> = [.schedule, .launch, .wake, .unlock, .after]
        let today = runs.filter { $0.loopId == loop.id && automatic.contains($0.trigger) && calendar.isDate($0.startedAt, inSameDayAs: now) }
        return today.count >= limit
    }

    public static func nextRun(for loop: LoopDefinition, state: Store.LoopState, now: Date) -> Date? {
        guard loop.enabled, let schedule = loop.schedule else { return nil }
        let since = state.lastRun[loop.id] ?? state.firstSeen[loop.id]
        return schedule.nextOccurrence(after: now, lastRun: since)
    }
}
