import Foundation

/// Read-only filesystem seam for discovering Codex automations. The surface has
/// no write operation, and callers may inject a synthetic tree in tests.
public protocol CodexAutomationFileReading: Sendable {
    /// Exact `automation.toml` files one directory below `root`.
    func automationFiles(in root: URL) throws -> [URL]
    /// Read one discovered metadata file. Production discovery immediately
    /// projects it down to an allow-list and never retains or exposes prompts.
    func readAutomationFile(at url: URL) throws -> String
}

/// Real read-only filesystem backend. Symlinked directories and files are
/// ignored so an automation entry cannot redirect discovery outside the
/// configured root.
public struct LocalCodexAutomationFileReader: CodexAutomationFileReading {
    public init() {}

    public func automationFiles(in root: URL) throws -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let children = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return try children.compactMap { directory in
            let values = try directory.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let file = directory.appendingPathComponent("automation.toml", isDirectory: false)
            guard manager.fileExists(atPath: file.path) else { return nil }
            let fileValues = try file.resourceValues(forKeys: keys)
            guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else { return nil }
            return file
        }.sorted { $0.path < $1.path }
    }

    public func readAutomationFile(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

/// One enabled Codex automation, deliberately limited to scheduling metadata.
/// There is no prompt property and the TOML scanner never captures its value.
public struct CodexAutomation: Equatable, Sendable, Identifiable {
    public struct LocalTarget: Equatable, Sendable {
        public var type: String
        public var projectID: String?

        public init(type: String, projectID: String? = nil) {
            self.type = type
            self.projectID = projectID
        }
    }

    public var id: String
    public var name: String
    public var rrule: String
    public var recurrence: CodexRecurrenceRule
    public var workingDirectories: [String]
    public var createdAt: Date?
    public var executionEnvironment: String
    public var target: LocalTarget
    public var sourceURL: URL

    public init(
        id: String,
        name: String,
        rrule: String,
        recurrence: CodexRecurrenceRule,
        workingDirectories: [String] = [],
        createdAt: Date? = nil,
        executionEnvironment: String = "local",
        target: LocalTarget = LocalTarget(type: "project"),
        sourceURL: URL
    ) {
        self.id = id
        self.name = name
        self.rrule = rrule
        self.recurrence = recurrence
        self.workingDirectories = workingDirectories
        self.createdAt = createdAt
        self.executionEnvironment = executionEnvironment
        self.target = target
        self.sourceURL = sourceURL
    }

    /// The first scheduled run strictly after `date`.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        recurrence.next(after: date, anchor: createdAt, calendar: calendar)
    }
}

public struct CodexAutomationDiscoveryIssue: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case rootUnreadable
        case fileUnreadable
        case malformedMetadata
        case missingField(String)
        case invalidRecurrence
    }

    public var sourceURL: URL
    public var reason: Reason

    public init(sourceURL: URL, reason: Reason) {
        self.sourceURL = sourceURL
        self.reason = reason
    }
}

public struct CodexAutomationDiscoveryResult: Equatable, Sendable {
    public var automations: [CodexAutomation]
    public var issues: [CodexAutomationDiscoveryIssue]

    public init(
        automations: [CodexAutomation] = [],
        issues: [CodexAutomationDiscoveryIssue] = []
    ) {
        self.automations = automations
        self.issues = issues
    }

    /// Prompt-free diagnostic summaries suitable for a structured log.
    public func diagnosticEvents(at date: Date) -> [UnattendedDiagnosticEvent] {
        var events = [UnattendedDiagnosticEvent(
            date: date,
            kind: .discoveryCompleted,
            automationCount: automations.count,
            issueCount: issues.count
        )]
        if !issues.isEmpty {
            events.append(UnattendedDiagnosticEvent(
                date: date,
                kind: .discoveryFailed,
                issueCount: issues.count
            ))
        }
        return events
    }
}

/// Finds `$CODEX_HOME/automations/*/automation.toml` and returns enabled
/// scheduling metadata only. Prompt text is discarded during parsing and is
/// never retained in the returned model, logged, or included in an error.
public struct CodexAutomationDiscovery: Sendable {
    public let root: URL
    private let files: any CodexAutomationFileReading

    public init(
        root: URL = CodexAutomationDiscovery.defaultRoot(),
        files: any CodexAutomationFileReading = LocalCodexAutomationFileReader()
    ) {
        self.root = root
        self.files = files
    }

    public static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let codexHome: URL
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            codexHome = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("automations", isDirectory: true)
    }

    public func discover() -> CodexAutomationDiscoveryResult {
        let urls: [URL]
        do {
            urls = try files.automationFiles(in: root)
        } catch {
            return CodexAutomationDiscoveryResult(
                issues: [CodexAutomationDiscoveryIssue(sourceURL: root, reason: .rootUnreadable)]
            )
        }

        var automations: [CodexAutomation] = []
        var issues: [CodexAutomationDiscoveryIssue] = []
        for url in urls {
            let text: String
            do {
                text = try files.readAutomationFile(at: url)
            } catch {
                issues.append(CodexAutomationDiscoveryIssue(sourceURL: url, reason: .fileUnreadable))
                continue
            }
            let fields = SafeAutomationTOML.fields(in: text)
            guard Self.isEnabled(fields),
                  let executionEnvironment = SafeAutomationTOML.string(fields["execution_environment"]),
                  ["local", "worktree"].contains(executionEnvironment.lowercased()),
                  let target = Self.localTarget(fields["target"])
            else { continue }
            guard let id = SafeAutomationTOML.string(fields["id"]), !id.isEmpty else {
                issues.append(CodexAutomationDiscoveryIssue(sourceURL: url, reason: .missingField("id")))
                continue
            }
            guard let name = SafeAutomationTOML.string(fields["name"]), !name.isEmpty else {
                issues.append(CodexAutomationDiscoveryIssue(sourceURL: url, reason: .missingField("name")))
                continue
            }
            guard let rrule = SafeAutomationTOML.string(fields["rrule"]), !rrule.isEmpty else {
                issues.append(CodexAutomationDiscoveryIssue(sourceURL: url, reason: .missingField("rrule")))
                continue
            }
            let recurrence: CodexRecurrenceRule
            do {
                recurrence = try CodexRecurrenceRule(rrule)
            } catch {
                issues.append(CodexAutomationDiscoveryIssue(sourceURL: url, reason: .invalidRecurrence))
                continue
            }
            let cwds = SafeAutomationTOML.stringArray(fields["cwds"]) ?? []
            let createdAt = SafeAutomationTOML.date(fields["created_at"])
            automations.append(CodexAutomation(
                id: id,
                name: name,
                rrule: rrule,
                recurrence: recurrence,
                workingDirectories: cwds,
                createdAt: createdAt,
                executionEnvironment: executionEnvironment,
                target: target,
                sourceURL: url
            ))
        }
        automations.sort {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
        return CodexAutomationDiscoveryResult(automations: automations, issues: issues)
    }

    private static func isEnabled(_ fields: [String: String]) -> Bool {
        SafeAutomationTOML.string(fields["status"])?.uppercased() == "ACTIVE"
    }

    private static func localTarget(_ raw: String?) -> CodexAutomation.LocalTarget? {
        guard let raw,
              let type = SafeAutomationTOML.inlineString(named: "type", in: raw)
        else { return nil }
        let projectID = SafeAutomationTOML.inlineString(named: "project_id", in: raw)
        if type == "project", let projectID, projectID.hasPrefix("local-") {
            return CodexAutomation.LocalTarget(type: type, projectID: projectID)
        }
        return nil
    }
}

// MARK: - Safe TOML projection

/// A tiny top-level TOML scanner that captures only scheduling metadata. It is
/// intentionally not a general TOML API. In particular, `prompt` and every
/// unknown value are consumed for lexical correctness but never copied out.
private enum SafeAutomationTOML {
    private static let allowedKeys: Set<String> = [
        "id", "name", "rrule", "cwds", "status", "created_at",
        "execution_environment", "target",
    ]

    static func fields(in text: String) -> [String: String] {
        let characters = Array(text)
        var index = 0
        var result: [String: String] = [:]
        while index < characters.count {
            skipHorizontalWhitespace(characters, &index)
            guard index < characters.count else { break }
            if characters[index].isNewline {
                index += 1
                continue
            }
            if characters[index] == "#" || characters[index] == "[" {
                skipLine(characters, &index)
                continue
            }
            let keyStart = index
            while index < characters.count, isBareKeyCharacter(characters[index]) {
                index += 1
            }
            guard index > keyStart else {
                skipLine(characters, &index)
                continue
            }
            let key = String(characters[keyStart..<index])
            skipHorizontalWhitespace(characters, &index)
            guard index < characters.count, characters[index] == "=" else {
                skipLine(characters, &index)
                continue
            }
            index += 1
            let valueStart = index
            let valueEnd = consumeValue(characters, &index)
            if allowedKeys.contains(key) {
                result[key] = String(characters[valueStart..<valueEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if index < characters.count, characters[index].isNewline { index += 1 }
        }
        return result
    }

    static func string(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return nil }
        if value.first == "'", value.last == "'", !value.hasPrefix("'''") {
            return String(value.dropFirst().dropLast())
        }
        guard value.first == "\"", value.last == "\"", !value.hasPrefix("\"\"\"") else {
            return nil
        }
        let body = Array(value.dropFirst().dropLast())
        var output = ""
        var index = 0
        while index < body.count {
            let character = body[index]
            guard character == "\\" else {
                output.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < body.count else { return nil }
            switch body[index] {
            case "b": output.append("\u{8}")
            case "t": output.append("\t")
            case "n": output.append("\n")
            case "f": output.append("\u{c}")
            case "r": output.append("\r")
            case "\"": output.append("\"")
            case "\\": output.append("\\")
            default: return nil
            }
            index += 1
        }
        return output
    }

    static func stringArray(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        let characters = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard characters.first == "[", characters.last == "]" else { return nil }
        var values: [String] = []
        var index = 1
        while index < characters.count - 1 {
            while index < characters.count - 1,
                  characters[index].isWhitespace || characters[index] == "," {
                index += 1
            }
            guard index < characters.count - 1 else { break }
            if characters[index] == "#" {
                skipLine(characters, &index)
                continue
            }
            let quote = characters[index]
            guard quote == "\"" || quote == "'" else { return nil }
            let start = index
            index += 1
            var escaped = false
            while index < characters.count - 1 {
                if quote == "\"", !escaped, characters[index] == "\\" {
                    escaped = true
                    index += 1
                    continue
                }
                if !escaped, characters[index] == quote { break }
                escaped = false
                index += 1
            }
            guard index < characters.count - 1, characters[index] == quote else { return nil }
            index += 1
            guard let value = string(String(characters[start..<index])) else { return nil }
            values.append(value)
        }
        return values
    }

    static func inlineString(named name: String, in raw: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|[,\\{])\\s*\(escaped)\\s*=\\s*\"([^\"\\\\]*)\""
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = expression.firstMatch(in: raw, range: range),
              let valueRange = Range(match.range(at: 1), in: raw)
        else { return nil }
        return String(raw[valueRange])
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let unquoted = string(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(unquoted) {
            // Current Codex files use epoch milliseconds; accept seconds for
            // older or hand-authored files as well.
            return Date(timeIntervalSince1970: number.magnitude >= 10_000_000_000 ? number / 1_000 : number)
        }
        return ISO8601DateFormatter().date(from: unquoted)
    }

    private enum StringMode {
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    /// Consume a complete TOML value, including multiline strings and arrays.
    /// The returned index excludes trailing comments and the terminating line
    /// break, allowing safe fields to be decoded while ignored values are never
    /// materialized.
    private static func consumeValue(_ characters: [Character], _ index: inout Int) -> Int {
        var mode: StringMode?
        var squareDepth = 0
        var braceDepth = 0
        var lastValueCharacter = index
        while index < characters.count {
            let character = characters[index]
            if mode != nil {
                switch mode! {
                case .basic:
                    if character == "\\" {
                        index = min(index + 2, characters.count)
                        lastValueCharacter = index
                    } else {
                        index += 1
                        lastValueCharacter = index
                        if character == "\"" { mode = nil }
                    }
                case .literal:
                    index += 1
                    lastValueCharacter = index
                    if character == "'" { mode = nil }
                case .multilineBasic:
                    if character == "\\" {
                        index = min(index + 2, characters.count)
                        lastValueCharacter = index
                    } else if hasTripleQuote(characters, at: index, quote: "\"") {
                        index += 3
                        lastValueCharacter = index
                        mode = nil
                    } else {
                        index += 1
                        lastValueCharacter = index
                    }
                case .multilineLiteral:
                    if hasTripleQuote(characters, at: index, quote: "'") {
                        index += 3
                        lastValueCharacter = index
                        mode = nil
                    } else {
                        index += 1
                        lastValueCharacter = index
                    }
                }
                continue
            }

            if hasTripleQuote(characters, at: index, quote: "\"") {
                mode = .multilineBasic
                index += 3
                lastValueCharacter = index
            } else if hasTripleQuote(characters, at: index, quote: "'") {
                mode = .multilineLiteral
                index += 3
                lastValueCharacter = index
            } else if character == "\"" {
                mode = .basic
                index += 1
                lastValueCharacter = index
            } else if character == "'" {
                mode = .literal
                index += 1
                lastValueCharacter = index
            } else if character == "[" {
                squareDepth += 1
                index += 1
                lastValueCharacter = index
            } else if character == "]" {
                squareDepth = max(0, squareDepth - 1)
                index += 1
                lastValueCharacter = index
            } else if character == "{" {
                braceDepth += 1
                index += 1
                lastValueCharacter = index
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
                index += 1
                lastValueCharacter = index
            } else if character == "#" {
                if squareDepth == 0, braceDepth == 0 {
                    skipLine(characters, &index)
                    return lastValueCharacter
                }
                skipLine(characters, &index)
            } else if character.isNewline, squareDepth == 0, braceDepth == 0 {
                return lastValueCharacter
            } else {
                index += 1
                if !character.isWhitespace { lastValueCharacter = index }
            }
        }
        return lastValueCharacter
    }

    private static func hasTripleQuote(
        _ characters: [Character],
        at index: Int,
        quote: Character
    ) -> Bool {
        index + 2 < characters.count
            && characters[index] == quote
            && characters[index + 1] == quote
            && characters[index + 2] == quote
    }

    private static func isBareKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    private static func skipHorizontalWhitespace(_ characters: [Character], _ index: inout Int) {
        while index < characters.count, characters[index] == " " || characters[index] == "\t" {
            index += 1
        }
    }

    private static func skipLine(_ characters: [Character], _ index: inout Int) {
        while index < characters.count, !characters[index].isNewline { index += 1 }
    }
}

// MARK: - Recurrence

public struct CodexRecurrenceRule: Equatable, Sendable {
    public enum Frequency: String, Equatable, Sendable {
        case minutely = "MINUTELY"
        case hourly = "HOURLY"
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
    }

    public enum Weekday: String, CaseIterable, Equatable, Hashable, Sendable {
        case monday = "MO"
        case tuesday = "TU"
        case wednesday = "WE"
        case thursday = "TH"
        case friday = "FR"
        case saturday = "SA"
        case sunday = "SU"

        fileprivate var calendarWeekday: Int {
            switch self {
            case .sunday: return 1
            case .monday: return 2
            case .tuesday: return 3
            case .wednesday: return 4
            case .thursday: return 5
            case .friday: return 6
            case .saturday: return 7
            }
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        case missingFrequency
        case unsupportedFrequency
        case invalidInterval
        case invalidWeekday
        case invalidMonthDay
        case invalidHour
        case invalidMinute
        case unsupportedPart(String)
        case invalidStartDate
    }

    public var frequency: Frequency
    public var interval: Int
    public var byWeekdays: Set<Weekday>
    public var byMonthDays: [Int]
    public var byHours: [Int]
    public var byMinutes: [Int]
    public var startDate: Date?

    public init(
        frequency: Frequency,
        interval: Int = 1,
        byWeekdays: Set<Weekday> = [],
        byMonthDays: [Int] = [],
        byHours: [Int] = [],
        byMinutes: [Int] = [],
        startDate: Date? = nil
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.byWeekdays = byWeekdays
        self.byMonthDays = Array(Set(byMonthDays.filter {
            $0 != 0 && (-31...31).contains($0)
        })).sorted()
        self.byHours = Array(Set(byHours.filter { (0...23).contains($0) })).sorted()
        self.byMinutes = Array(Set(byMinutes.filter { (0...59).contains($0) })).sorted()
        self.startDate = startDate
    }

    public init(_ raw: String, timeZone: TimeZone = .current) throws {
        var recurrenceText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedStart: Date?
        var ruleLines: [String] = []
        for line in recurrenceText.split(whereSeparator: { $0.isNewline }).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("DTSTART") {
                guard let separator = trimmed.firstIndex(of: ":") ?? trimmed.firstIndex(of: "=") else {
                    throw ParseError.invalidStartDate
                }
                let value = String(trimmed[trimmed.index(after: separator)...])
                guard let date = Self.parseStartDate(value, timeZone: timeZone) else {
                    throw ParseError.invalidStartDate
                }
                parsedStart = date
            } else {
                ruleLines.append(trimmed)
            }
        }
        recurrenceText = ruleLines.joined(separator: ";")
        if recurrenceText.uppercased().hasPrefix("RRULE:") {
            recurrenceText.removeFirst("RRULE:".count)
        }

        var values: [String: String] = [:]
        for rawPart in recurrenceText.split(separator: ";") {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            guard let equals = part.firstIndex(of: "=") else {
                throw ParseError.unsupportedPart(part)
            }
            let key = part[..<equals].uppercased()
            let value = String(part[part.index(after: equals)...])
            switch key {
            case "FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYHOUR", "BYMINUTE":
                values[key] = value
            case "BYSECOND":
                guard value.split(separator: ",").allSatisfy({ Int($0) == 0 }) else {
                    throw ParseError.unsupportedPart(key)
                }
            case "WKST":
                // Calendar.firstWeekday owns week boundaries at evaluation.
                continue
            case "DTSTART":
                guard let date = Self.parseStartDate(value, timeZone: timeZone) else {
                    throw ParseError.invalidStartDate
                }
                parsedStart = date
            default:
                throw ParseError.unsupportedPart(key)
            }
        }

        guard let frequencyRaw = values["FREQ"] else { throw ParseError.missingFrequency }
        guard let frequency = Frequency(rawValue: frequencyRaw.uppercased()) else {
            throw ParseError.unsupportedFrequency
        }
        let interval: Int
        if let rawInterval = values["INTERVAL"] {
            guard let value = Int(rawInterval), value > 0 else { throw ParseError.invalidInterval }
            interval = value
        } else {
            interval = 1
        }
        let weekdays: Set<Weekday>
        if let rawDays = values["BYDAY"] {
            let parsed = try rawDays.split(separator: ",").map { token -> Weekday in
                guard let weekday = Weekday(rawValue: token.uppercased()) else {
                    throw ParseError.invalidWeekday
                }
                return weekday
            }
            weekdays = Set(parsed)
        } else {
            weekdays = []
        }
        let monthDays = try Self.monthDayList(values["BYMONTHDAY"])
        if frequency != .monthly, !monthDays.isEmpty {
            throw ParseError.unsupportedPart("BYMONTHDAY")
        }
        let hours = try Self.integerList(values["BYHOUR"], range: 0...23, error: .invalidHour)
        let minutes = try Self.integerList(values["BYMINUTE"], range: 0...59, error: .invalidMinute)
        self.init(
            frequency: frequency,
            interval: interval,
            byWeekdays: weekdays,
            byMonthDays: monthDays,
            byHours: hours,
            byMinutes: minutes,
            startDate: parsedStart
        )
    }

    /// Find the next occurrence strictly after `date`. `anchor` is normally the
    /// automation's creation time and gives INTERVAL a stable origin when the
    /// RRULE has no DTSTART.
    public func next(
        after date: Date,
        anchor externalAnchor: Date? = nil,
        calendar inputCalendar: Calendar = .current
    ) -> Date? {
        var calendar = inputCalendar
        if calendar.timeZone.identifier.isEmpty { calendar.timeZone = .current }
        let anchor = startDate ?? externalAnchor ?? Date(timeIntervalSince1970: 0)
        switch frequency {
        case .minutely:
            return nextMinutely(after: date, anchor: anchor, calendar: calendar)
        case .hourly:
            return nextHourly(after: date, anchor: anchor, calendar: calendar)
        case .daily:
            return nextDaily(after: date, anchor: anchor, calendar: calendar)
        case .weekly:
            return nextWeekly(after: date, anchor: anchor, calendar: calendar)
        case .monthly:
            return nextMonthly(after: date, anchor: anchor, calendar: calendar)
        }
    }

    private func nextMinutely(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        guard let anchorMinute = calendar.dateInterval(of: .minute, for: anchor)?.start,
              let dateMinute = calendar.dateInterval(of: .minute, for: max(date, anchor))?.start,
              var candidate = calendar.date(byAdding: .minute, value: 1, to: dateMinute)
        else { return nil }
        let offset = max(0, calendar.dateComponents([.minute], from: anchorMinute, to: candidate).minute ?? 0)
        let remainder = offset % interval
        if remainder != 0,
           let aligned = calendar.date(byAdding: .minute, value: interval - remainder, to: candidate) {
            candidate = aligned
        }
        for _ in 0..<Self.searchLimit {
            if matchesFilters(candidate, calendar: calendar, defaultMinute: nil, defaultHour: nil) {
                return candidate
            }
            guard let next = calendar.date(byAdding: .minute, value: interval, to: candidate) else { return nil }
            candidate = next
        }
        return nil
    }

    private func nextHourly(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        guard let anchorHour = calendar.dateInterval(of: .hour, for: anchor)?.start,
              var hour = calendar.dateInterval(of: .hour, for: max(date, anchor))?.start
        else { return nil }
        let offset = max(0, calendar.dateComponents([.hour], from: anchorHour, to: hour).hour ?? 0)
        let remainder = offset % interval
        if remainder != 0,
           let aligned = calendar.date(byAdding: .hour, value: interval - remainder, to: hour) {
            hour = aligned
        }
        let defaultMinute = calendar.component(.minute, from: anchor)
        for _ in 0..<Self.searchLimit {
            if matchesDayAndHour(hour, calendar: calendar) {
                for minute in effectiveMinutes(defaultMinute) {
                    if let candidate = calendar.date(bySetting: .minute, value: minute, of: hour),
                       calendar.component(.hour, from: candidate) == calendar.component(.hour, from: hour),
                       candidate > date, candidate >= anchor {
                        return candidate
                    }
                }
            }
            guard let next = calendar.date(byAdding: .hour, value: interval, to: hour) else { return nil }
            hour = next
        }
        return nil
    }

    private func nextDaily(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        let anchorDay = calendar.startOfDay(for: anchor)
        var day = calendar.startOfDay(for: max(date, anchor))
        let offset = max(0, calendar.dateComponents([.day], from: anchorDay, to: day).day ?? 0)
        let remainder = offset % interval
        if remainder != 0,
           let aligned = calendar.date(byAdding: .day, value: interval - remainder, to: day) {
            day = aligned
        }
        for _ in 0..<Self.searchLimit {
            if matchesWeekday(day, calendar: calendar),
               let candidate = firstCandidate(on: day, after: date, anchor: anchor, calendar: calendar) {
                return candidate
            }
            guard let next = calendar.date(byAdding: .day, value: interval, to: day) else { return nil }
            day = next
        }
        return nil
    }

    private func nextWeekly(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        guard let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start,
              var week = calendar.dateInterval(of: .weekOfYear, for: max(date, anchor))?.start
        else { return nil }
        let offset = max(0, calendar.dateComponents([.weekOfYear], from: anchorWeek, to: week).weekOfYear ?? 0)
        let remainder = offset % interval
        if remainder != 0,
           let aligned = calendar.date(byAdding: .weekOfYear, value: interval - remainder, to: week) {
            week = aligned
        }
        let defaultWeekday = calendar.component(.weekday, from: anchor)
        let weekdays = byWeekdays.isEmpty
            ? [defaultWeekday]
            : byWeekdays.map(\.calendarWeekday)
        let orderedOffsets = weekdays.map { ($0 - calendar.firstWeekday + 7) % 7 }.sorted()
        for _ in 0..<Self.searchLimit {
            for offset in orderedOffsets {
                guard let day = calendar.date(byAdding: .day, value: offset, to: week) else { continue }
                if let candidate = firstCandidate(on: day, after: date, anchor: anchor, calendar: calendar) {
                    return candidate
                }
            }
            guard let next = calendar.date(byAdding: .weekOfYear, value: interval, to: week) else { return nil }
            week = next
        }
        return nil
    }

    private func nextMonthly(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        guard let anchorMonth = calendar.dateInterval(of: .month, for: anchor)?.start,
              var month = calendar.dateInterval(of: .month, for: max(date, anchor))?.start
        else { return nil }
        let offset = max(
            0,
            calendar.dateComponents([.month], from: anchorMonth, to: month).month ?? 0
        )
        let remainder = offset % interval
        if remainder != 0,
           let aligned = calendar.date(byAdding: .month, value: interval - remainder, to: month) {
            month = aligned
        }

        for _ in 0..<Self.searchLimit {
            for day in monthlyDayCandidates(in: month, anchor: anchor, calendar: calendar) {
                guard let candidateDay = calendar.date(
                    byAdding: .day,
                    value: day - 1,
                    to: month
                ) else { continue }
                if let candidate = firstCandidate(
                    on: candidateDay,
                    after: date,
                    anchor: anchor,
                    calendar: calendar
                ) {
                    return candidate
                }
            }
            guard let next = calendar.date(byAdding: .month, value: interval, to: month)
            else { return nil }
            month = next
        }
        return nil
    }

    /// Resolve positive and negative RFC 5545 month days for one concrete
    /// month. Missing dates are skipped instead of being normalized into the
    /// next month. An unqualified monthly rule uses the anchor's day, while
    /// BYDAY without BYMONTHDAY selects every matching weekday in the month.
    private func monthlyDayCandidates(
        in month: Date,
        anchor: Date,
        calendar: Calendar
    ) -> [Int] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: month) else {
            return []
        }
        let dayCount = dayRange.count
        let candidates: [Int]
        if !byMonthDays.isEmpty {
            candidates = byMonthDays.compactMap { raw in
                let resolved = raw > 0 ? raw : dayCount + raw + 1
                return dayRange.contains(resolved) ? resolved : nil
            }
        } else if !byWeekdays.isEmpty {
            candidates = Array(dayRange)
        } else {
            let anchorDay = calendar.component(.day, from: anchor)
            candidates = dayRange.contains(anchorDay) ? [anchorDay] : []
        }

        return Array(Set(candidates)).filter { day in
            guard !byWeekdays.isEmpty else { return true }
            guard let candidate = calendar.date(byAdding: .day, value: day - 1, to: month)
            else { return false }
            return matchesWeekday(candidate, calendar: calendar)
        }.sorted()
    }

    private func firstCandidate(
        on day: Date,
        after date: Date,
        anchor: Date,
        calendar: Calendar
    ) -> Date? {
        let defaultHour = calendar.component(.hour, from: anchor)
        let defaultMinute = calendar.component(.minute, from: anchor)
        for hour in effectiveHours(defaultHour) {
            for minute in effectiveMinutes(defaultMinute) {
                guard let candidate = calendar.date(
                    bySettingHour: hour,
                    minute: minute,
                    second: 0,
                    of: day
                ) else { continue }
                if candidate > date, candidate >= anchor { return candidate }
            }
        }
        return nil
    }

    private func matchesFilters(
        _ date: Date,
        calendar: Calendar,
        defaultMinute: Int?,
        defaultHour: Int?
    ) -> Bool {
        matchesWeekday(date, calendar: calendar)
            && (byHours.isEmpty ? defaultHour.map { calendar.component(.hour, from: date) == $0 } ?? true
                : byHours.contains(calendar.component(.hour, from: date)))
            && (byMinutes.isEmpty ? defaultMinute.map { calendar.component(.minute, from: date) == $0 } ?? true
                : byMinutes.contains(calendar.component(.minute, from: date)))
    }

    private func matchesDayAndHour(_ date: Date, calendar: Calendar) -> Bool {
        matchesWeekday(date, calendar: calendar)
            && (byHours.isEmpty || byHours.contains(calendar.component(.hour, from: date)))
    }

    private func matchesWeekday(_ date: Date, calendar: Calendar) -> Bool {
        byWeekdays.isEmpty
            || byWeekdays.contains { $0.calendarWeekday == calendar.component(.weekday, from: date) }
    }

    private func effectiveHours(_ defaultHour: Int) -> [Int] {
        byHours.isEmpty ? [defaultHour] : byHours
    }

    private func effectiveMinutes(_ defaultMinute: Int) -> [Int] {
        byMinutes.isEmpty ? [defaultMinute] : byMinutes
    }

    private static let searchLimit = 100_000

    private static func integerList(
        _ raw: String?,
        range: ClosedRange<Int>,
        error: ParseError
    ) throws -> [Int] {
        guard let raw else { return [] }
        var values: [Int] = []
        for token in raw.split(separator: ",") {
            guard let value = Int(token), range.contains(value) else { throw error }
            values.append(value)
        }
        return Array(Set(values)).sorted()
    }

    private static func monthDayList(_ raw: String?) throws -> [Int] {
        guard let raw else { return [] }
        var values: [Int] = []
        for token in raw.split(separator: ",") {
            guard let value = Int(token), value != 0, (-31...31).contains(value)
            else { throw ParseError.invalidMonthDay }
            values.append(value)
        }
        return Array(Set(values)).sorted()
    }

    private static func parseStartDate(_ raw: String, timeZone: TimeZone) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = ISO8601DateFormatter().date(from: value) { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = value.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : timeZone
        for format in ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

// MARK: - Wake planning

public struct CodexAutomationWakePlan: Equatable, Sendable {
    public var automationID: String
    public var automationName: String
    public var scheduledRun: Date
    /// Desired wake before scheduling constraints are considered.
    public var desiredWake: Date
    /// A future date suitable for `pmset schedule`, or nil when preparation
    /// should begin immediately because the lead window has already opened.
    public var scheduledWake: Date?
    public var workingDirectories: [String]

    public init(
        automationID: String,
        automationName: String,
        scheduledRun: Date,
        desiredWake: Date,
        scheduledWake: Date?,
        workingDirectories: [String]
    ) {
        self.automationID = automationID
        self.automationName = automationName
        self.scheduledRun = scheduledRun
        self.desiredWake = desiredWake
        self.scheduledWake = scheduledWake
        self.workingDirectories = workingDirectories
    }

    public var requiresImmediatePreparation: Bool { scheduledWake == nil }

    public func diagnosticEvent(at date: Date) -> UnattendedDiagnosticEvent {
        UnattendedDiagnosticEvent(
            date: date,
            kind: .wakePlanned,
            automationID: automationID,
            scheduledRun: scheduledRun,
            scheduledWake: scheduledWake
        )
    }
}

/// One automation's next run retained by the task layer. Wake scheduling uses
/// only the first item, while the full queue remains available for grouping
/// nearby or concurrent work after wake.
public struct CodexAutomationQueuedRun: Equatable, Sendable {
    public var automationID: String
    public var automationName: String
    public var scheduledRun: Date
    public var workingDirectories: [String]

    public init(
        automationID: String,
        automationName: String,
        scheduledRun: Date,
        workingDirectories: [String]
    ) {
        self.automationID = automationID
        self.automationName = automationName
        self.scheduledRun = scheduledRun
        self.workingDirectories = workingDirectories
    }
}

/// Correlates leases created during a scheduled Codex handoff with the exact
/// automation that created them. A concurrent Claude or interactive Codex
/// lease must never satisfy an unrelated scheduled run merely because it was
/// acquired during the same time window.
public enum CodexLeaseHandoffPolicy {
    private static let acceptedAgents = Set(["codex", "codex-cli", "openai-codex"])

    /// Returns at most one lease per run and at most one run per lease.
    /// Scheduled Agents claim a run by setting `agent` to a recognized Codex
    /// identity and putting the exact automation ID in `owner`, `task`, or the
    /// forward-compatible `automation_id` metadata attribute.
    public static func matchedClaims(
        runs: [CodexAutomationQueuedRun],
        leases: [AgentWakeLease],
        excluding baseline: Set<UUID>,
        acquiredOnOrAfter handoffBeganAt: Date
    ) -> [String: UUID] {
        var unused = leases
            .filter {
                !baseline.contains($0.id)
                    && $0.acquiredAt >= handoffBeganAt
                    && isCodex($0.metadata.agent)
            }
            .sorted {
                if $0.acquiredAt != $1.acquiredAt { return $0.acquiredAt < $1.acquiredAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        var claims: [String: UUID] = [:]
        let orderedRuns = runs.sorted {
            if $0.scheduledRun != $1.scheduledRun { return $0.scheduledRun < $1.scheduledRun }
            return $0.automationID < $1.automationID
        }
        for run in orderedRuns {
            guard let index = unused.firstIndex(where: {
                metadataClaims(runID: run.automationID, metadata: $0.metadata)
            }) else { continue }
            claims[run.automationID] = unused.remove(at: index).id
        }
        return claims
    }

    // Do not filter terminal state here. A newly correlated lease that was
    // subsequently released, failed, cancelled, or timed out proves that this
    // scheduled task claimed the handoff and has already reached its explicit
    // terminal result. It should not keep scheduled demand alive until timeout.

    private static func isCodex(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return acceptedAgents.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func metadataClaims(runID: String, metadata: AgentLeaseMetadata) -> Bool {
        metadata.owner == runID
            || metadata.task == runID
            || metadata.attributes["automation_id"] == runID
    }
}

public struct CodexAutomationWakePlanningResult: Equatable, Sendable {
    /// The single nearest wake suitable for the existing pmset helper seam.
    public var wakePlan: CodexAutomationWakePlan?
    /// Every enabled local automation's next run, ordered by time then ID.
    public var queuedRuns: [CodexAutomationQueuedRun]

    public init(
        wakePlan: CodexAutomationWakePlan?,
        queuedRuns: [CodexAutomationQueuedRun]
    ) {
        self.wakePlan = wakePlan
        self.queuedRuns = queuedRuns
    }
}

/// Chooses the nearest enabled Codex run and derives the one-shot wake that
/// must precede it. The caller can apply the returned `WakeScheduleConfig`
/// through the existing helper seam.
public struct CodexAutomationWakePlanner: Equatable, Sendable {
    public var leadTime: TimeInterval
    /// `pmset schedule` needs a date safely in the future. If the desired wake
    /// is inside this guard, no stale one-shot is emitted and the caller should
    /// begin readiness immediately.
    public var minimumScheduleAdvance: TimeInterval

    public init(leadTime: TimeInterval = 5 * 60, minimumScheduleAdvance: TimeInterval = 30) {
        self.leadTime = max(0, leadTime)
        self.minimumScheduleAdvance = max(1, minimumScheduleAdvance)
    }

    public func nextPlan(
        for automations: [CodexAutomation],
        after date: Date,
        calendar: Calendar = .current
    ) -> CodexAutomationWakePlan? {
        plan(for: automations, after: date, calendar: calendar).wakePlan
    }

    public func plan(
        for automations: [CodexAutomation],
        after date: Date,
        calendar: Calendar = .current
    ) -> CodexAutomationWakePlanningResult {
        let candidates = automations.compactMap { automation -> CodexAutomationQueuedRun? in
            automation.nextRun(after: date, calendar: calendar).map {
                CodexAutomationQueuedRun(
                    automationID: automation.id,
                    automationName: automation.name,
                    scheduledRun: $0,
                    workingDirectories: automation.workingDirectories
                )
            }
        }.sorted {
            if $0.scheduledRun != $1.scheduledRun { return $0.scheduledRun < $1.scheduledRun }
            return $0.automationID < $1.automationID
        }
        guard let nearest = candidates.first else {
            return CodexAutomationWakePlanningResult(wakePlan: nil, queuedRuns: [])
        }
        let run = nearest.scheduledRun
        let desired = run.addingTimeInterval(-leadTime)
        let earliestSchedulable = date.addingTimeInterval(minimumScheduleAdvance)
        let wakePlan = CodexAutomationWakePlan(
            automationID: nearest.automationID,
            automationName: nearest.automationName,
            scheduledRun: run,
            desiredWake: desired,
            scheduledWake: desired >= earliestSchedulable ? desired : nil,
            workingDirectories: nearest.workingDirectories
        )
        return CodexAutomationWakePlanningResult(
            wakePlan: wakePlan,
            queuedRuns: candidates
        )
    }

    /// Update only the one-shot portion, preserving any user-authored repeating
    /// schedule and wake-and-brew settings.
    public func updating(
        _ existing: WakeScheduleConfig = WakeScheduleConfig(),
        with plan: CodexAutomationWakePlan?
    ) -> WakeScheduleConfig {
        var updated = existing
        updated.oneShot = plan?.scheduledWake
        return updated
    }
}

/// Joins Keepresso's user-authored wake configuration with the next Codex
/// one-shot. A consumed earlier manual wake must reveal a later Codex wake on
/// the next apply instead of leaving the system with no pending one-shot.
public enum CodexWakeSchedulePolicy {
    public static func effective(
        manual: WakeScheduleConfig?,
        codexWake: Date?,
        codexEnabled: Bool,
        at date: Date
    ) -> WakeScheduleConfig {
        var config = manual ?? WakeScheduleConfig()
        if let manualWake = config.oneShot, manualWake <= date {
            config.oneShot = nil
        }
        if codexEnabled,
           let codexWake,
           codexWake > date,
           config.oneShot == nil || codexWake < config.oneShot! {
            config.oneShot = codexWake
        }
        return config
    }
}
