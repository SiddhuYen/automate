import Foundation

/// When a loop runs on the clock.
///
/// Accepted forms:
///   every 30m | every 2h | every 1d | hourly
///   daily 09:00 | weekdays 18:30 | weekends 10:00 | mon,wed,fri 07:15
///   cron: "30 8 * * 1-5" (fixed minute and hour, any day-of-week list/range) or "*/15 * * * *"
///   once 2026-11-02 17:00 (a one-off, e.g. a reminder)
public enum Schedule: Equatable, Sendable {
    case interval(TimeInterval)
    /// Runs once at this moment (or as soon as the Mac is awake after it), then never again.
    case once(Date)
    /// weekdays use Calendar numbering: 1 = Sunday ... 7 = Saturday
    case weekly(days: Set<Int>, hour: Int, minute: Int)

    public static func parse(_ raw: String) -> Schedule? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if s == "hourly" { return .interval(3600) }

        let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if parts.count == 5 { return parseCron(parts) }
        if parts.count == 3, parts[0] == "once" {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendarTimeZone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.date(from: "\(parts[1]) \(parts[2])").map { .once($0) }
        }
        guard parts.count == 2 else { return nil }

        if parts[0] == "every" {
            let spec = parts[1]
            guard let unit = spec.last, let n = Double(spec.dropLast()), n > 0 else { return nil }
            switch unit {
            case "m": return .interval(max(n, 1) * 60)
            case "h": return .interval(n * 3600)
            case "d": return .interval(n * 86400)
            default: return nil
            }
        }

        let timeParts = parts[1].split(separator: ":").compactMap { Int($0) }
        guard timeParts.count == 2, (0..<24).contains(timeParts[0]), (0..<60).contains(timeParts[1]) else {
            return nil
        }
        let days: Set<Int>
        switch parts[0] {
        case "daily": days = Set(1...7)
        case "weekdays": days = [2, 3, 4, 5, 6]
        case "weekends": days = [1, 7]
        default:
            let map = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            let parsed = parts[0].split(separator: ",").compactMap { map[String($0.prefix(3))] }
            guard !parsed.isEmpty else { return nil }
            days = Set(parsed)
        }
        return .weekly(days: days, hour: timeParts[0], minute: timeParts[1])
    }

    /// The common cron shapes: "M H * * DOW" and "*/N * * * *" / "0 */N * * *".
    static func parseCron(_ f: [String]) -> Schedule? {
        let (minute, hour, dom, month, dow) = (f[0], f[1], f[2], f[3], f[4])
        guard dom == "*", month == "*" else { return nil }
        if minute.hasPrefix("*/"), hour == "*", dow == "*", let n = Double(minute.dropFirst(2)), n > 0 {
            return .interval(n * 60)
        }
        if minute == "0" || minute == "00", hour.hasPrefix("*/"), dow == "*", let n = Double(hour.dropFirst(2)), n > 0 {
            return .interval(n * 3600)
        }
        if minute == "0" || minute == "00", hour == "*", dow == "*" { return .interval(3600) }
        guard let m = Int(minute), (0..<60).contains(m), let h = Int(hour), (0..<24).contains(h) else { return nil }
        var days = Set<Int>()
        if dow == "*" {
            days = Set(1...7)
        } else {
            let names = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
            func num(_ s: Substring) -> Int? { Int(s) ?? names[String(s.prefix(3))] }
            for part in dow.split(separator: ",") {
                let range = part.split(separator: "-")
                if range.count == 2, let a = num(range[0]), let b = num(range[1]), a <= b, a >= 0, b <= 7 {
                    for d in a...b { days.insert(d % 7 + 1) }
                } else if let d = num(part), (0...7).contains(d) {
                    days.insert(d % 7 + 1) // cron 0/7 = Sunday = Calendar 1
                } else {
                    return nil
                }
            }
        }
        return .weekly(days: days, hour: h, minute: m)
    }

    /// Time zone `once` dates are read in (tests pin it).
    nonisolated(unsafe) public static var calendarTimeZone: TimeZone = .current

    /// Most recent scheduled moment at or before `now` (weekly schedules only).
    public func mostRecentOccurrence(onOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        guard case let .weekly(days, hour, minute) = self else { return nil }
        for back in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard days.contains(weekday),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { continue }
            if candidate <= now { return candidate }
        }
        return nil
    }

    /// Next scheduled moment strictly after `now`.
    public func nextOccurrence(after now: Date, lastRun: Date?, calendar: Calendar = .current) -> Date? {
        switch self {
        case .interval(let seconds):
            guard let last = lastRun else { return now }
            return max(last.addingTimeInterval(seconds), now)
        case .once(let date):
            if let last = lastRun, last >= date { return nil }
            return max(date, now)
        case let .weekly(days, hour, minute):
            for ahead in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: ahead, to: now) else { continue }
                let weekday = calendar.component(.weekday, from: day)
                guard days.contains(weekday),
                      let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
                else { continue }
                if candidate > now { return candidate }
            }
            return nil
        }
    }

    /// Should the loop run now?
    /// - lastRun: when it last ran (or when Automate first saw the loop, so new loops don't fire for the past).
    /// - catchUp: if the Mac was asleep at the scheduled time, run as soon as possible afterwards.
    public func isDue(now: Date, lastRun: Date, catchUp: Bool, calendar: Calendar = .current) -> Bool {
        switch self {
        case .interval(let seconds):
            return now.timeIntervalSince(lastRun) >= seconds
        case .once(let date):
            return now >= date && lastRun < date && (catchUp || now.timeIntervalSince(date) < 10 * 60)
        case .weekly:
            guard let prev = mostRecentOccurrence(onOrBefore: now, calendar: calendar), prev > lastRun else {
                return false
            }
            return catchUp || now.timeIntervalSince(prev) < 10 * 60
        }
    }

    public var description: String {
        switch self {
        case .interval(let s):
            if s >= 86400, s.truncatingRemainder(dividingBy: 86400) == 0 { return "every \(Int(s / 86400))d" }
            if s >= 3600, s.truncatingRemainder(dividingBy: 3600) == 0 { return "every \(Int(s / 3600))h" }
            return "every \(Int(s / 60))m"
        case .once(let date):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = Self.calendarTimeZone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return "once \(f.string(from: date))"
        case let .weekly(days, hour, minute):
            let t = String(format: "%02d:%02d", hour, minute)
            if days.count == 7 { return "daily \(t)" }
            if days == [2, 3, 4, 5, 6] { return "weekdays \(t)" }
            if days == [1, 7] { return "weekends \(t)" }
            let names = ["", "sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            return days.sorted().map { names[$0] }.joined(separator: ",") + " " + t
        }
    }
}
