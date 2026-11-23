// Claude Usage — macOS menu bar app
// • Plan limits (5-hour session, weekly, extra usage) for the Claude account signed in to Claude Code
// • Claude status (status.claude.com)
// • Local Claude Code usage from ~/.claude/projects/**/*.jsonl

import SwiftUI
import AppKit
import Charts
import ServiceManagement

// MARK: - Model

struct TokenTotals {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var cost = 0.0
    var messages = 0
    var total: Int { input + output + cacheWrite + cacheRead }
    mutating func add(_ o: TokenTotals) {
        input += o.input; output += o.output; cacheWrite += o.cacheWrite; cacheRead += o.cacheRead
        cost += o.cost; messages += o.messages
    }
}

struct LimitWindow: Identifiable, Codable {
    let id: String
    let title: String
    let subtitle: String?
    let badge: String?
    let percent: Double          // 0...100
    let resetsAt: Date?
    let windowLength: TimeInterval
}

struct ExtraUsage: Codable { let percent: Double; let used: Double; let limit: Double }

struct DayCost: Identifiable { let day: Int; let cost: Double; var id: Int { day } }

/// Last good plan-limit response, saved so a restart never needs to re-ask right away.
struct PlanCache: Codable {
    var limits: [LimitWindow] = []
    var extra: ExtraUsage? = nil
    var fetchedAt: Date? = nil
    var nextFetch: Date = .distantPast
    var backoff: TimeInterval = 600
}

struct Snapshot {
    var last5h = TokenTotals()
    var today = TokenTotals()
    var month = TokenTotals()
    var monthTopModel: String? = nil
    var monthByModel: [(String, Double)] = []
    var monthDaily: [DayCost] = []
    var updated = Date()
}

// MARK: - Pricing (USD per million tokens, approximate API-equivalent)

func price(for model: String) -> (inp: Double, out: Double) {
    let m = model.lowercased()
    if m.contains("opus") {
        if m.contains("opus-4-0") || m.contains("opus-4-1") || m.range(of: #"opus-4-\d{8}"#, options: .regularExpression) != nil || m.contains("3-opus") {
            return (15, 75)
        }
        return (5, 25)
    }
    if m.contains("haiku") {
        if m.contains("3-5-haiku") || m.contains("haiku-3-5") { return (0.8, 4) }
        if m.contains("3-haiku") { return (0.25, 1.25) }
        return (1, 5)
    }
    return (3, 15)
}

func prettyModel(_ id: String) -> String {
    var s = id.replacingOccurrences(of: "claude-", with: "")
    if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
    let parts = s.split(separator: "-")
    guard let name = parts.first else { return id }
    let ver = parts.dropFirst().joined(separator: ".")
    return "Claude " + name.prefix(1).uppercased() + name.dropFirst() + (ver.isEmpty ? "" : " " + ver)
}

// MARK: - Log scanner

final class LogScanner {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let iso1: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private let iso2 = ISO8601DateFormatter()

    func scan() -> Snapshot {
        let now = Date()
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        let startMonth = cal.dateInterval(of: .month, for: now)!.start
        let since5h = now.addingTimeInterval(-5 * 3600)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)!.count

        var snap = Snapshot()
        var seen = Set<String>()
        var byModel: [String: Double] = [:]
        var byDay = [Double](repeating: 0, count: daysInMonth + 1)

        func process(_ line: Data) {
            guard line.count > 50, line.range(of: Data("\"usage\"".utf8)) != nil else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = iso1.date(from: ts) ?? iso2.date(from: ts),
                  date >= startMonth else { return }
            let key = "\(msg["id"] as? String ?? UUID().uuidString)|\(obj["requestId"] as? String ?? "")"
            if !seen.insert(key).inserted { return }
            let model = msg["model"] as? String ?? "unknown"
            if model == "<synthetic>" { return }

            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            var t = TokenTotals()
            t.input = n("input_tokens"); t.output = n("output_tokens")
            t.cacheWrite = n("cache_creation_input_tokens"); t.cacheRead = n("cache_read_input_tokens")
            t.messages = 1
            var w5m = t.cacheWrite, w1h = 0
            if let cc = usage["cache_creation"] as? [String: Any] {
                w1h = (cc["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
                w5m = (cc["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? max(0, t.cacheWrite - w1h)
            }
            let p = price(for: model)
            t.cost = (Double(t.input) * p.inp + Double(t.output) * p.out
                      + Double(w5m) * p.inp * 1.25 + Double(w1h) * p.inp * 2
                      + Double(t.cacheRead) * p.inp * 0.1) / 1_000_000

            snap.month.add(t)
            byModel[prettyModel(model), default: 0] += t.cost
            let d = cal.component(.day, from: date)
            if d < byDay.count { byDay[d] += t.cost }
            if date >= startToday { snap.today.add(t) }
            if date >= since5h { snap.last5h.add(t) }
        }

        let fm = FileManager.default
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod < startMonth { continue }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                var start = data.startIndex
                while start < data.endIndex {
                    let end = data[start...].firstIndex(of: 10) ?? data.endIndex
                    if end > start { process(data[start..<end]) }
                    start = end + 1
                }
            }
        }

        snap.monthTopModel = byModel.max { $0.value < $1.value }?.key
        snap.monthByModel = byModel.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        let today = cal.component(.day, from: now)
        snap.monthDaily = (1...today).map { DayCost(day: $0, cost: byDay[$0]) }
        snap.updated = now
        return snap
    }
}

// MARK: - Log (~/Library/Logs/ClaudeUsage.log)

func appLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeUsage.log")
    let line = "\(Date().formatted(.iso8601)) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: url) }
}

// MARK: - Remote data

enum Remote {
    static let iso: (String) -> Date? = { s in
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f1.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Claude Code OAuth access token from the login Keychain (macOS asks the first time).
    /// There can be several "Claude Code-credentials" items (e.g. one holding only MCP logins),
    /// so try the one for the current macOS user first and keep the first that has claudeAiOauth.
    /// Uses /usr/bin/security, which Claude Code itself uses to write the item.
    static func token() -> String? {
        let attempts: [[String]] = [["-a", NSUserName()], []]
        for extra in attempts {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", "Claude Code-credentials"] + extra + ["-w"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { appLog("keychain attempt \(extra.isEmpty ? "any" : "user") exit=\(p.terminationStatus)") }
            guard p.terminationStatus == 0,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let o = j["claudeAiOauth"] as? [String: Any],
                  let t = o["accessToken"] as? String else { continue }
            return t
        }
        return nil
    }

    static func planUsage() async throws -> ([LimitWindow], ExtraUsage?) {
        guard let tok = token() else { throw err("ไม่พบการล็อกอิน Claude Code ใน Keychain — รัน `claude` แล้วล็อกอินก่อน") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { appLog("usage HTTP \(code) body=\(String(decoding: data.prefix(400), as: UTF8.self))") }
        guard code == 200 else {
            let retry = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            throw NSError(domain: "usage", code: code, userInfo: [
                NSLocalizedDescriptionKey: code == 401 ? "Token หมดอายุ — เปิด Claude Code อีกครั้งเพื่อรีเฟรช"
                    : code == 429 ? "ถูกจำกัดการเรียกชั่วคราว (429)" : "โหลดลิมิตไม่สำเร็จ (HTTP \(code))",
                "retryAfter": retry as Any])
        }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }

        let defs: [(String, String, String?, String?, TimeInterval)] = [
            ("five_hour", "Session Usage", "5-hour rolling window", nil, 5 * 3600),
            ("seven_day", "All models", nil, "Weekly", 7 * 86400),
            ("seven_day_opus", "Opus", nil, "Weekly", 7 * 86400),
            ("seven_day_sonnet", "Sonnet", nil, "Weekly", 7 * 86400),
        ]
        let windows: [LimitWindow] = defs.compactMap { key, title, sub, badge, len in
            guard let w = j[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(id: key, title: title, subtitle: sub, badge: badge, percent: u,
                               resetsAt: (w["resets_at"] as? String).flatMap(iso), windowLength: len)
        }
        var extra: ExtraUsage? = nil
        if let e = j["extra_usage"] as? [String: Any], (e["is_enabled"] as? Bool) == true {
            let used = (e["used_credits"] as? NSNumber)?.doubleValue ?? 0       // cents
            let limit = (e["monthly_limit"] as? NSNumber)?.doubleValue ?? 0     // cents
            let pct = (e["utilization"] as? NSNumber)?.doubleValue ?? (limit > 0 ? used / limit * 100 : 0)
            extra = ExtraUsage(percent: pct, used: used / 100, limit: limit / 100)
        }
        return (windows, extra)
    }

    static func status() async -> (String, String) {
        guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "https://status.claude.com/api/v2/status.json")!),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = j["status"] as? [String: Any] else { return ("unknown", "Status unavailable") }
        return (s["indicator"] as? String ?? "unknown", s["description"] as? String ?? "")
    }

    static func err(_ m: String) -> NSError { NSError(domain: "usage", code: 0, userInfo: [NSLocalizedDescriptionKey: m]) }
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published var snap = Snapshot()
    @Published var limits: [LimitWindow] = []
    @Published var extra: ExtraUsage?
    @Published var limitError: String?
    @Published var statusIndicator = "unknown"
    @Published var statusText = "Checking status…"
    @Published var loading = false
    @Published var showSettings = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("planLimitsEnabled") var showPlanLimits = true { didSet { refresh(force: true) } }
    @AppStorage("titleMode") var titleMode = "limit" // limit | cost | tokens

    private let scanner = LogScanner()
    private var timer: Timer?

    init() {
        #if PREVIEW
        return
        #endif
        loadCache()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setLaunchAtLogin(_ v: Bool) {
        do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // Plan limits: the endpoint is rate-limited, so ask rarely.
    // • every 10 min in the background, or when the menu is opened and data is > 3 min old
    // • after HTTP 429: wait (Retry-After or doubling) up to 1 hour
    // • the last answer and the next allowed time survive restarts (UserDefaults)
    static let baseInterval: TimeInterval = 600
    @Published var limitsFetchedAt: Date?
    @Published var spinStart: Date?      // refresh icon spins while set
    @Published var introStart: Date?     // ring fills in while set
    static let spinPeriod: TimeInterval = 0.75

    /// Spin at least one full turn, keep going while work is running, stop on a whole turn.
    private func spinWhileBusy() {
        guard spinStart == nil else { return }
        let start = Date()
        spinStart = start
        Task { @MainActor in
            // the view eases in, which lags the angle by 1/8 turn: whole turns happen at n + 0.125 periods
            let lag = 0.125 * Self.spinPeriod
            try? await Task.sleep(for: .seconds(Self.spinPeriod + lag))
            var waited = 0
            while (loading || planInFlight) && waited < 150 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
            let el = Date().timeIntervalSince(start) - lag
            let rest = Self.spinPeriod - el.truncatingRemainder(dividingBy: Self.spinPeriod)
            if rest < Self.spinPeriod - 0.01 { try? await Task.sleep(for: .seconds(rest)) }
            spinStart = nil
        }
    }
    private var cache = PlanCache()
    private var planInFlight = false

    private func loadCache() {
        if let d = UserDefaults.standard.data(forKey: "planCache"),
           let c = try? JSONDecoder().decode(PlanCache.self, from: d) {
            cache = c; limits = c.limits; extra = c.extra; limitsFetchedAt = c.fetchedAt
        }
    }
    private func saveCache() {
        if let d = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(d, forKey: "planCache") }
    }

    func menuOpened() {
        let t = Date()
        introStart = t
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if introStart == t { introStart = nil }
        }
        guard showPlanLimits else { return }
        let stale = (limitsFetchedAt.map { Date().timeIntervalSince($0) } ?? .infinity) > 180
        let inBackoff = cache.backoff > Self.baseInterval && Date() < cache.nextFetch
        if stale && !inBackoff { fetchPlan() }
    }

    private func fetchPlanIfDue(force: Bool) {
        if force { menuOpened() } else if Date() >= cache.nextFetch { fetchPlan() }
    }

    private func fetchPlan() {
        guard !planInFlight else { return }
        planInFlight = true
        Task {
            defer { planInFlight = false; saveCache() }
            do {
                let (l, e) = try await Task.detached { try await Remote.planUsage() }.value
                limits = l; extra = e; limitError = nil
                cache.limits = l; cache.extra = e; cache.fetchedAt = Date(); limitsFetchedAt = cache.fetchedAt
                cache.backoff = Self.baseInterval
                cache.nextFetch = Date().addingTimeInterval(Self.baseInterval)
            } catch {
                let ns = error as NSError
                if ns.code == 429 {
                    let ra = ns.userInfo["retryAfter"] as? Double
                    cache.backoff = min(max(ra ?? cache.backoff * 2, Self.baseInterval), 3600)
                    limitError = limits.isEmpty ? "รอโควตาจาก Anthropic — จะลองใหม่ \(Date().addingTimeInterval(cache.backoff).formatted(date: .omitted, time: .shortened))" : nil
                } else {
                    cache.backoff = Self.baseInterval
                    limitError = ns.localizedDescription
                }
                cache.nextFetch = Date().addingTimeInterval(cache.backoff)
                appLog("plan error: \(ns.localizedDescription) next=\(cache.nextFetch.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    func refresh(force: Bool = false) {
        if force { spinWhileBusy() }
        guard !loading else { return }
        loading = true
        let scanner = self.scanner
        Task.detached(priority: .utility) {
            let s = scanner.scan()
            await MainActor.run { self.snap = s; self.loading = false }
        }
        Task { let (i, t) = await Remote.status(); statusIndicator = i; statusText = t }
        if showPlanLimits {
            if limits.isEmpty && !cache.limits.isEmpty { loadCache() }
            fetchPlanIfDue(force: force)
        }
        else { limits = []; extra = nil; limitError = nil; limitsFetchedAt = nil }
    }

    var titlePercent: Double? {
        (limits.first(where: { $0.id == "five_hour" }) ?? limits.first(where: { $0.id == "seven_day" }))?.percent
    }

    var title: String {
        switch titleMode {
        case "tokens": return fmtTokens(snap.today.total)
        case "cost": return fmtCost(snap.today.cost)
        default:
            // 5-hour session if the plan reports one, otherwise the weekly limit
            if let f = limits.first(where: { $0.id == "five_hour" }) ?? limits.first(where: { $0.id == "seven_day" }) {
                return "\(Int(f.percent.rounded()))%"
            }
            return "–%"
        }
    }
}

// MARK: - Formatting

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
    return "\(n)"
}
func fmtCost(_ c: Double) -> String { c >= 1000 ? String(format: "US$%.0f", c) : String(format: "US$%.2f", c) }

func fmtReset(_ d: Date) -> String {
    let s = max(0, Int(d.timeIntervalSinceNow))
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    let rel = days > 0 ? "\(days)d \(h)h" : "\(h)h \(m)m"
    let cal = Calendar.current
    let f = DateFormatter()
    if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return "Resets in \(rel) (Today \(f.string(from: d)))" }
    if cal.isDateInTomorrow(d) { f.dateFormat = "HH:mm"; return "Resets in \(rel) (Tomorrow \(f.string(from: d)))" }
    f.dateFormat = "MMM d, HH:mm"
    return "Resets in \(rel) (\(f.string(from: d)))"
}

func usageColor(_ pct: Double) -> Color {
    pct >= 80 ? Color(red: 0.95, green: 0.38, blue: 0.35)
    : pct >= 50 ? Color(red: 0.96, green: 0.65, blue: 0.30)
    : Color(red: 0.40, green: 0.80, blue: 0.42)
}
let accentOrange = Color(red: 0.76, green: 0.47, blue: 0.25)

// MARK: - Theme

enum Theme {
    static let bgTop = Color(red: 0.115, green: 0.105, blue: 0.098)
    static let bgBottom = Color(red: 0.075, green: 0.070, blue: 0.066)
    static let card = Color.white.opacity(0.045)
    static let stroke = Color.white.opacity(0.075)
    static let coral = Color(red: 0.87, green: 0.50, blue: 0.36)
    static let coralLight = Color(red: 0.96, green: 0.68, blue: 0.52)
    static let good = Color(red: 0.42, green: 0.82, blue: 0.55)
    static let warn = Color(red: 0.98, green: 0.72, blue: 0.33)
    static let bad = Color(red: 0.96, green: 0.42, blue: 0.40)
    static let modelColors: [Color] = [coral, Color(red: 0.86, green: 0.76, blue: 0.56),
                                       Color(red: 0.55, green: 0.72, blue: 0.62), Color(red: 0.52, green: 0.60, blue: 0.80),
                                       Color.white.opacity(0.35)]
    static func level(_ pct: Double) -> Color { pct >= 85 ? bad : pct >= 60 ? warn : good }
}

func rounded(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .rounded) }

func money(_ c: Double) -> String {
    if c >= 10_000 { return String(format: "$%.1fK", c / 1000) }
    if c >= 1000 { let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return "$" + (f.string(from: c as NSNumber) ?? "\(Int(c))") }
    if c >= 10 { return String(format: "$%.0f", c) }
    return String(format: "$%.2f", c)
}

func thaiDuration(_ s: TimeInterval) -> String {
    let s = max(0, Int(s)); let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d) วัน \(h) ชม." }
    if h > 0 { return "\(h) ชม. \(m) นาที" }
    return "\(m) นาที"
}

func thaiDate(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "th_TH"); f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = Calendar.current.isDateInToday(d) ? "'วันนี้' HH:mm" : Calendar.current.isDateInTomorrow(d) ? "'พรุ่งนี้' HH:mm" : "EEE d MMM HH:mm"
    return f.string(from: d)
}

/// How far through the window we are (0...1), from the reset time.
func elapsedFraction(_ w: LimitWindow) -> Double? {
    guard let r = w.resetsAt else { return nil }
    return min(1, max(0, 1 - r.timeIntervalSinceNow / w.windowLength))
}

// MARK: - Building blocks

struct Panel<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct Chip: View {
    let text: String; let color: Color; var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let i = icon { Image(systemName: i).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct Ring: View {
    let percent: Double
    let elapsed: Double?
    var introStart: Date? = nil
    var size: CGFloat = 104
    var line: CGFloat = 11
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: introStart == nil)) { ctx in
            let x = introStart.map { min(1, max(0, ctx.date.timeIntervalSince($0) / 0.9)) } ?? 1
            let k = 1 - pow(1 - x, 3)      // ease-out cubic
            face(shown: percent * k, dotOpacity: k)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder func face(shown: Double, dotOpacity: Double) -> some View {
        let percent = shown
        let p = min(1, max(0, percent / 100))
        let c = Theme.level(percent)
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.004, p))
                .stroke(AngularGradient(colors: [c.opacity(0.55), c], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(p, 0.01))),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: c.opacity(0.45), radius: 6)
            if let e = elapsed {
                // where we "should" be if usage were spread evenly over the window
                let a = Angle.degrees(360 * e - 90)
                let r = size / 2
                Circle().fill(Color.white).frame(width: 5, height: 5)
                    .offset(x: r * CGFloat(cos(a.radians)), y: r * CGFloat(sin(a.radians)))
                    .opacity(dotOpacity)
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
            VStack(spacing: 0) {
                Text("\(Int(percent.rounded()))").font(rounded(size * 0.31, .bold)).monospacedDigit()
                + Text("%").font(rounded(size * 0.15, .semibold)).foregroundColor(.secondary)
                Text("ใช้ไปแล้ว").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sections

struct HeroLimit: View {
    let w: LimitWindow
    var introStart: Date? = nil
    var body: some View {
        Panel(padding: 16) {
            HStack(spacing: 18) {
                Ring(percent: w.percent, elapsed: elapsedFraction(w), introStart: introStart)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(w.id == "five_hour" ? "Session" : w.title).font(rounded(17, .bold))
                        Text(w.badge ?? "5 ชม.").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.09)))
                    }
                    if let r = w.resetsAt {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("รีเซ็ตใน \(thaiDuration(r.timeIntervalSinceNow))").font(.system(size: 12, weight: .medium))
                            Text(thaiDate(r)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    pace
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder var pace: some View {
        if let e = elapsedFraction(w), e > 0.02 {
            let diff = w.percent - e * 100
            let projected = min(999, w.percent / e)
            VStack(alignment: .leading, spacing: 4) {
                if abs(diff) < 4 {
                    Chip(text: "ตามเวลาพอดี", color: Theme.warn, icon: "equal")
                } else if diff < 0 {
                    Chip(text: "ช้ากว่าเวลา \(Int(-diff))%", color: Theme.good, icon: "tortoise.fill")
                } else {
                    Chip(text: "เร็วกว่าเวลา \(Int(diff))%", color: projected >= 100 ? Theme.bad : Theme.warn, icon: "hare.fill")
                }
                Text(projected >= 100 ? "ถ้าใช้แบบนี้ต่อจะชนลิมิตก่อนรีเซ็ต" : "คาดว่าจะใช้ ~\(Int(projected))% ก่อนรีเซ็ต")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }
}

struct CompactLimit: View {
    let title: String; let badge: String?; let percent: Double; let detail: String?; let elapsed: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let b = badge { Text(b).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                Spacer()
                Text("\(Int(percent.rounded()))%").font(rounded(14, .bold)).foregroundStyle(Theme.level(percent)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(LinearGradient(colors: [Theme.level(percent).opacity(0.6), Theme.level(percent)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, g.size.width * min(1, percent / 100)))
                    if let e = elapsed {
                        Capsule().fill(Color.white).frame(width: 2, height: 10).offset(x: g.size.width * e - 1)
                    }
                }
            }.frame(height: 6)
            if let d = detail { Text(d).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
    }
}

struct StatTile: View {
    let label: String; let icon: String; let t: TokenTotals; var highlight = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 10.5, weight: .semibold))
            }.foregroundStyle(highlight ? Theme.coralLight : .secondary)
            Text(money(t.cost)).font(rounded(18, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text("\(fmtTokens(t.total)) tokens").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(highlight ? AnyShapeStyle(LinearGradient(colors: [Theme.coral.opacity(0.22), Theme.coral.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.white.opacity(0.045)))
        )
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(highlight ? Theme.coral.opacity(0.35) : Theme.stroke))
    }
}

struct DailyChartView: View {
    let days: [DayCost]
    var body: some View {
        let active = days.filter { $0.cost > 0 }
        let avg = active.isEmpty ? 0 : active.map(\.cost).reduce(0, +) / Double(active.count)
        let today = days.last?.day ?? 0
        let n = max(days.count, 7)
        Panel {
            HStack(alignment: .firstTextBaseline) {
                Text("ค่าใช้จ่ายรายวัน").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("เฉลี่ย \(money(avg))/วัน").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(days) { d in
                    BarMark(x: .value("วัน", d.day), y: .value("USD", d.cost),
                            width: .fixed(CGFloat(max(3, min(12, 200 / n)))))
                        .foregroundStyle(d.day == today
                            ? AnyShapeStyle(LinearGradient(colors: [Theme.coralLight, Theme.coral], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(LinearGradient(colors: [Theme.coral.opacity(0.75), Theme.coral.opacity(0.35)], startPoint: .top, endPoint: .bottom)))
                        .cornerRadius(3)
                }
                if avg > 0 {
                    RuleMark(y: .value("avg", avg))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .chartXScale(domain: 0.5...(Double(n) + 0.5))
            .chartXAxis {
                AxisMarks(values: Array(stride(from: 1, through: n, by: n > 14 ? 5 : 2))) { v in
                    AxisValueLabel { if let i = v.as(Int.self) { Text("\(i)").font(.system(size: 9)).foregroundStyle(.secondary) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel { if let c = v.as(Double.self) { Text(c == 0 ? "" : money(c)).font(.system(size: 9)).foregroundStyle(.tertiary) } }
                }
            }
            .frame(height: 104)
        }
    }
}

struct ModelBreakdown: View {
    let models: [(String, Double)]
    var body: some View {
        let total = max(models.map(\.1).reduce(0, +), 0.0001)
        let top = Array(models.prefix(4))
        let rest = models.dropFirst(4).map(\.1).reduce(0, +)
        let rows: [(String, Double)] = rest > 0 ? top + [("อื่นๆ", rest)] : top
        Panel {
            Text("ตามโมเดล · เดือนนี้").font(.system(size: 13, weight: .semibold))
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        Rectangle().fill(Theme.modelColors[min(i, Theme.modelColors.count - 1)])
                            .frame(width: max(2, (g.size.width - CGFloat(rows.count - 1) * 2) * r.1 / total))
                    }
                }
                .clipShape(Capsule())
            }.frame(height: 8)
            VStack(spacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 7) {
                        Circle().fill(Theme.modelColors[min(i, Theme.modelColors.count - 1)]).frame(width: 7, height: 7)
                        Text(r.0.replacingOccurrences(of: "Claude ", with: "")).font(.system(size: 12))
                        Spacer()
                        Text("\(Int((r.1 / total * 100).rounded()))%").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        Text(money(r.1)).font(rounded(12, .semibold)).monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                }
            }.padding(.top, 2)
        }
    }
}

// MARK: - Popover

struct MenuContent: View {
    @ObservedObject var store: UsageStore

    var statusColor: Color {
        switch store.statusIndicator {
        case "none": return Theme.good
        case "minor": return Theme.warn
        case "major", "critical": return Theme.bad
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.showSettings { settings } else { content }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .background(LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
        .onAppear { store.menuOpened() }
    }

    var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.coralLight, Theme.coral], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "chart.pie.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Theme.coral.opacity(0.4), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Usage").font(rounded(15, .bold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6).shadow(color: statusColor, radius: 3)
                    Text(store.statusText).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { store.refresh(force: true) } label: {
                TimelineView(.animation(minimumInterval: nil, paused: store.spinStart == nil)) { ctx in
                    let turns = store.spinStart.map { ctx.date.timeIntervalSince($0) / UsageStore.spinPeriod } ?? 0
                    // ease the first quarter turn in so the start isn't abrupt
                    let eased = turns < 0.25 ? turns * turns * 2 : turns - 0.125
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(eased * 360))
                        .foregroundStyle(store.spinStart == nil ? Color.primary : Theme.coralLight)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(store.spinStart == nil ? Color.white.opacity(0.07) : Theme.coral.opacity(0.18)))
                        .overlay(Circle().strokeBorder(store.spinStart == nil ? Theme.stroke : Theme.coral.opacity(0.45)))
                        .scaleEffect(store.spinStart == nil ? 1 : 0.94)
                }
            }.buttonStyle(.plain).help("รีเฟรช")
            iconButton(store.showSettings ? "xmark" : "slider.horizontal.3") { store.showSettings.toggle() }
        }
        .padding(.bottom, 2)
    }

    func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .overlay(Circle().strokeBorder(Theme.stroke))
        }.buttonStyle(.plain)
    }

    @ViewBuilder var content: some View {
        if store.showPlanLimits {
            if let hero = store.limits.first {
                HeroLimit(w: hero, introStart: store.introStart)
                let others = Array(store.limits.dropFirst())
                if !others.isEmpty || store.extra != nil {
                    Panel {
                        VStack(spacing: 12) {
                            ForEach(others) { w in
                                CompactLimit(title: w.title, badge: w.badge, percent: w.percent,
                                             detail: w.resetsAt.map { "รีเซ็ตใน \(thaiDuration($0.timeIntervalSinceNow))" }, elapsed: elapsedFraction(w))
                            }
                            if let e = store.extra {
                                CompactLimit(title: "Extra usage", badge: "รายเดือน", percent: e.percent,
                                             detail: String(format: "$%.2f จาก $%.2f", e.used, e.limit), elapsed: nil)
                            }
                        }
                    }
                }
            } else {
                Panel {
                    HStack(spacing: 8) {
                        if let e = store.limitError {
                            Image(systemName: "hourglass").foregroundStyle(Theme.warn)
                            Text(e).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("กำลังโหลดลิมิต…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        HStack(spacing: 8) {
            StatTile(label: "วันนี้", icon: "sun.max.fill", t: store.snap.today, highlight: true)
            StatTile(label: "5 ชม.", icon: "clock.fill", t: store.snap.last5h)
            StatTile(label: "เดือนนี้", icon: "calendar", t: store.snap.month)
        }

        DailyChartView(days: store.snap.monthDaily)

        if !store.snap.monthByModel.isEmpty { ModelBreakdown(models: store.snap.monthByModel) }
    }

    var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle").font(.system(size: 9))
            Text("ค่าใช้จ่ายคิดเป็นราคา API โดยประมาณ")
            Spacer()
            if let t = store.limitsFetchedAt {
                Text("ลิมิตอัปเดต \(t.formatted(.relative(presentation: .named).locale(Locale(identifier: "th_TH"))))")
            } else {
                Text("อัปเดต \(store.snap.updated.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        .padding(.horizontal, 2)
    }

    var settings: some View {
        Panel(padding: 16) {
            Text("ตั้งค่า").font(rounded(15, .bold)).padding(.bottom, 2)
            Toggle(isOn: $store.showPlanLimits) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("แสดงลิมิตแพลน").font(.system(size: 12, weight: .medium))
                    Text("อ่านล็อกอิน Claude Code จาก Keychain").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).controlSize(.small).tint(Theme.coral)
            Divider().opacity(0.4)
            HStack {
                Text("เมนูบาร์แสดง").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: $store.titleMode) {
                    Text("% ลิมิต").tag("limit")
                    Text("ค่าใช้จ่ายวันนี้").tag("cost")
                    Text("โทเค็นวันนี้").tag("tokens")
                }.labelsHidden().frame(width: 140)
            }
            Divider().opacity(0.4)
            HStack {
                Image(systemName: "power").foregroundStyle(.secondary)
                Text("เปิดเองทุกครั้งที่ล็อกอิน").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("ออกจากแอป") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
    }
}

// MARK: - Menu bar icon

/// Small progress ring drawn as a template image so it follows the menu bar's colour.
func ringImage(_ percent: Double?) -> NSImage {
    let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        let c = NSPoint(x: 8, y: 8), r: CGFloat = 6
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.2
        NSColor.black.withAlphaComponent(percent == nil ? 0.6 : 0.28).setStroke()
        track.stroke()
        if let p = percent, p > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(1, p / 100)), clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - App

#if !PREVIEW
@main
struct ClaudeUsageApp: App {
    @StateObject private var store = UsageStore()
    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            HStack(spacing: 4) {
                if store.titleMode == "limit" { Image(nsImage: ringImage(store.titlePercent)) }
                else { Image(systemName: "sparkle") }
                Text(store.title).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
