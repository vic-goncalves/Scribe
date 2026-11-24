import AVFoundation
import Foundation
import GRDB
import Observation

enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Scribe", isDirectory: true)
    }()
    static let models = root.appendingPathComponent("Models", isDirectory: true)
}

struct Recording: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    enum Status: String, Codable, DatabaseValueConvertible {
        case queued, transcribing, done, failed
    }

    var id: Int64?
    var title: String
    var fileName: String
    var duration: Double
    var createdAt: Date
    var status: Status
    var errorMessage: String?
    var language: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Segment: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var recordingId: Int64
    var start: Double
    var end: Double
    var text: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct SearchHit: Identifiable, Hashable {
    let segment: Segment
    let recordingTitle: String
    let score: Double
    var id: Int64 { segment.id ?? 0 }
}

/// Owns the on-disk library: copied audio files plus a SQLite database of recordings and their transcript segments.
@Observable
@MainActor
final class Library {
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aif", "aiff", "flac", "caf"]

    private(set) var recordings: [Recording] = []
    let audioDirectory: URL
    private let db: DatabaseQueue

    /// `root` holds `library.sqlite` and an `Audio` folder with the imported files.
    init(root: URL = AppPaths.root) throws {
        audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        db = try DatabaseQueue(path: root.appendingPathComponent("library.sqlite").path)
        try Self.migrator.migrate(db)
        // A transcription interrupted by quitting the app starts over on next launch.
        try db.write { db in
            try db.execute(sql: "UPDATE recording SET status = 'queued' WHERE status = 'transcribing'")
        }
        reload()
    }

    /// Every write goes through this class, so refreshing after each one keeps `recordings` in sync.
    private func reload() {
        recordings = (try? db.read { try Recording.order(Column("createdAt").desc, Column("id").desc).fetchAll($0) }) ?? []
    }

    private func write(_ updates: (Database) throws -> Void) {
        do {
            try db.write(updates)
        } catch {
            print("Library write failed: \(error)")
        }
        reload()
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "recording") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("duration", .double).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("errorMessage", .text)
                t.column("language", .text)
            }
            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("recording", onDelete: .cascade).notNull()
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("text", .text).notNull()
            }
            // Trigram tokens give substring matching and let search tolerate typos (see `search`).
            try db.create(virtualTable: "segment_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("text")
            }
        }
        return migrator
    }

    func recording(id: Int64) -> Recording? {
        recordings.first { $0.id == id }
    }

    func audioURL(for recording: Recording) -> URL {
        audioDirectory.appendingPathComponent(recording.fileName)
    }

    // MARK: Importing

    /// Copies each audio file into the library and queues it for transcription. Returns the ids of the new recordings.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [Int64] {
        var ids: [Int64] = []
        for url in urls where Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let fileName = "\(UUID().uuidString).\(url.pathExtension.lowercased())"
            let destination = audioDirectory.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                let duration = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? 0
                let recording = Recording(
                    title: url.deletingPathExtension().lastPathComponent,
                    fileName: fileName,
                    duration: duration.isFinite ? duration : 0,
                    createdAt: Date(),
                    status: .queued
                )
                let inserted = try await db.write { db -> Recording in
                    var copy = recording
                    try copy.insert(db)
                    return copy
                }
                if let id = inserted.id { ids.append(id) }
                reload()
            } catch {
                try? FileManager.default.removeItem(at: destination)
                print("Import of \(url.lastPathComponent) failed: \(error)")
            }
        }
        return ids
    }

    // MARK: Transcripts

    func segments(for recordingId: Int64) -> [Segment] {
        (try? db.read { db in
            try Segment.filter(Column("recordingId") == recordingId).order(Column("start")).fetchAll(db)
        }) ?? []
    }

    func nextQueued() -> Recording? {
        recordings.filter { $0.status == .queued }.min { $0.createdAt < $1.createdAt }
    }

    func setStatus(_ status: Recording.Status, for id: Int64, error: String? = nil) {
        write { db in
            try db.execute(
                sql: "UPDATE recording SET status = ?, errorMessage = ? WHERE id = ?",
                arguments: [status.rawValue, error, id]
            )
        }
    }

    func saveTranscript(for id: Int64, segments: [(start: Double, end: Double, text: String)], language: String?) {
        write { db in
            try Segment.filter(Column("recordingId") == id).deleteAll(db)
            for item in segments {
                var segment = Segment(recordingId: id, start: item.start, end: item.end, text: item.text)
                try segment.insert(db)
            }
            try db.execute(
                sql: "UPDATE recording SET status = 'done', errorMessage = NULL, language = ? WHERE id = ?",
                arguments: [language, id]
            )
        }
    }

    func requeue(_ id: Int64) {
        setStatus(.queued, for: id)
    }

    func rename(_ id: Int64, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        write { db in
            try db.execute(sql: "UPDATE recording SET title = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    func delete(_ id: Int64) {
        guard let recording = recording(id: id) else { return }
        write { db in
            _ = try Recording.deleteOne(db, key: id)
        }
        try? FileManager.default.removeItem(at: audioURL(for: recording))
    }

    // MARK: Search

    /// Fuzzy search over every transcript. Candidates come from the trigram index (any shared trigram);
    /// a candidate matches when every query word is a prefix of, or a small typo away from, some word in it.
    func search(_ rawQuery: String, limit: Int = 200) -> [SearchHit] {
        let query = Self.normalize(rawQuery)
        guard query.count >= 2 else { return [] }
        let queryTrigrams = Self.trigrams(of: query)
        let titles = Dictionary(uniqueKeysWithValues: recordings.compactMap { r in r.id.map { ($0, r.title) } })

        let candidates: [Segment] = (try? db.read { db in
            if queryTrigrams.isEmpty {
                return try Segment.fetchAll(db, sql: "SELECT * FROM segment WHERE text LIKE ? LIMIT 2000", arguments: ["%\(query)%"])
            }
            let match = queryTrigrams.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
            return try Segment.fetchAll(db, sql: """
                SELECT segment.* FROM segment
                JOIN segment_fts ON segment_fts.rowid = segment.id
                WHERE segment_fts MATCH ?
                LIMIT 5000
                """, arguments: [match])
        }) ?? []

        let queryWords = query.split(separator: " ").map(String.init)
        let hits: [SearchHit] = candidates.compactMap { segment in
            let text = Self.normalize(segment.text)
            let score: Double
            if text.contains(query) {
                score = 2
            } else if let fuzzy = Self.fuzzyScore(queryWords: queryWords, text: text) {
                score = fuzzy
            } else {
                return nil
            }
            guard let title = titles[segment.recordingId] else { return nil }
            return SearchHit(segment: segment, recordingTitle: title, score: score)
        }
        return Array(hits.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.segment.recordingId != b.segment.recordingId { return a.segment.recordingId > b.segment.recordingId }
            return a.segment.start < b.segment.start
        }.prefix(limit))
    }

    static func normalize(_ string: String) -> String {
        string.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 1 when every query word prefixes a word in the text, lower for each typo-tolerant match, nil if any word is missing.
    static func fuzzyScore(queryWords: [String], text: String) -> Double? {
        let textWords = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var total = 0.0
        for queryWord in queryWords {
            let allowedTypos = queryWord.count >= 8 ? 2 : queryWord.count >= 4 ? 1 : 0
            var best = 0.0
            for word in textWords {
                if word.hasPrefix(queryWord) {
                    best = 1
                    break
                }
                if allowedTypos > 0, abs(word.count - queryWord.count) <= allowedTypos {
                    let distance = editDistance(queryWord, word)
                    if distance <= allowedTypos {
                        best = max(best, 1 - Double(distance) / Double(queryWord.count))
                    }
                }
            }
            guard best > 0 else { return nil }
            total += best
        }
        return total / Double(queryWords.count)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return a.isEmpty ? b.count : previous[b.count]
    }

    /// Trigrams are taken per word so punctuation and spacing differences between query and transcript don't matter.
    static func trigrams(of query: String) -> Set<String> {
        var result = Set<String>()
        for word in query.split(separator: " ") {
            let chars = Array(word)
            guard chars.count >= 3 else { continue }
            for i in 0...(chars.count - 3) {
                result.insert(String(chars[i..<(i + 3)]))
            }
        }
        return result
    }
}
