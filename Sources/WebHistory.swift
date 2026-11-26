import SwiftUI

/// The pages visited in the browser, newest first, kept in UserDefaults (a few hundred small entries).
@Observable
final class WebHistory {
    struct Visit: Codable, Identifiable, Hashable {
        var url: URL
        var title: String
        var date: Date
        var id: URL { url }
    }

    static let shared = WebHistory()
    private static let key = "web.history"
    private static let limit = 500

    private(set) var visits: [Visit] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let v = try? JSONDecoder().decode([Visit].self, from: data) { visits = v }
    }

    /// A page was opened: it goes to the top (once only, so going back and forth doesn't fill the list).
    func record(_ url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let old = visits.first { $0.url == url }
        visits.removeAll { $0.url == url }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        visits.insert(Visit(url: url, title: t.isEmpty ? (old?.title ?? "") : t, date: .now), at: 0)
        if visits.count > Self.limit { visits.removeLast(visits.count - Self.limit) }
        save()
    }

    /// A page's title arrived after it was recorded.
    func retitle(_ url: URL, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = visits.firstIndex(where: { $0.url == url }), visits[i].title != t else { return }
        visits[i].title = t
        save()
    }

    func remove(_ visit: Visit) {
        visits.removeAll { $0.url == visit.url }
        save()
    }

    func clear() {
        visits = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(visits), forKey: Self.key)
    }
}

/// The history list, opened from the clock beside the address field.
struct WebHistoryView: View {
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirmClear = false
    private var history: WebHistory { .shared }

    private var shown: [WebHistory.Visit] {
        let s = search.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return history.visits }
        return history.visits.filter { $0.title.localizedCaseInsensitiveContains(s) || $0.url.absoluteString.localizedCaseInsensitiveContains(s) }
    }

    /// Visits grouped by day: Today, Yesterday, then dates.
    private var days: [(String, [WebHistory.Visit])] {
        let cal = Calendar.current
        var out: [(String, [WebHistory.Visit])] = []
        for v in shown {
            let name = cal.isDateInToday(v.date) ? "Today"
                : cal.isDateInYesterday(v.date) ? "Yesterday"
                : v.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            if out.last?.0 == name { out[out.count - 1].1.append(v) } else { out.append((name, [v])) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if history.visits.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Pages you open in the browser appear here."))
                } else {
                    List {
                        ForEach(days, id: \.0) { day, visits in
                            Section(day) {
                                ForEach(visits) { v in
                                    Button { open(v.url); dismiss() } label: { row(v) }
                                        .buttonStyle(.plain)
                                        .swipeActions { Button("Delete", role: .destructive) { history.remove(v) } }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: "Search history")
                    .overlay { if shown.isEmpty { ContentUnavailableView.search(text: search) } }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear") { confirmClear = true }.disabled(history.visits.isEmpty)
                }
            }
            .confirmationDialog("Clear all browsing history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { history.clear() }
            }
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 420, idealHeight: 560)
    }

    private func row(_ v: WebHistory.Visit) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(v.title.isEmpty ? (v.url.host() ?? v.url.absoluteString) : v.title).lineLimit(2)
                Text(v.url.host()?.replacingOccurrences(of: "www.", with: "") ?? v.url.absoluteString)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(v.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
