import XCTest
@testable import Scribe

@MainActor
final class NavigationAndModelTests: XCTestCase {
    private func recording(_ id: Int64, _ createdAt: Date) -> Recording {
        Recording(id: id, title: "R\(id)", fileName: "\(id).m4a", duration: 60, createdAt: createdAt, status: .done)
    }

    func testDateSections() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-24T15:00:00Z")!
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

        let sections = DateSection.group([
            recording(1, daysAgo(0)),
            recording(2, daysAgo(0.2)),
            recording(3, daysAgo(1)),
            recording(4, daysAgo(4)),
            recording(5, daysAgo(20)),
            recording(6, daysAgo(400)),
        ], now: now, calendar: calendar)

        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Previous 7 Days", "November", "October 2025"])
        XCTAssertEqual(sections.map { $0.recordings.compactMap(\.id) }, [[1, 2], [3], [4], [5], [6]])
    }

    func testSelectAdjacentMovesAndClampsAtTheEnds() {
        let state = AppState()
        let recordings = [recording(10, .now), recording(11, .now), recording(12, .now)]

        state.selectAdjacent(1, in: recordings)
        XCTAssertEqual(state.selection, 10, "with nothing selected, the first recording is picked")
        state.selectAdjacent(1, in: recordings)
        state.selectAdjacent(1, in: recordings)
        state.selectAdjacent(1, in: recordings)
        XCTAssertEqual(state.selection, 12)
        state.selectAdjacent(-5, in: recordings)
        XCTAssertEqual(state.selection, 10)
        state.selectAdjacent(1, in: [])
        XCTAssertEqual(state.selection, 10)
    }

    func testDownloadedModelsMigrateFromSingleModelSettingsAndCanBeDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeModels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fast = ModelOption.all.first { $0.name == "Fast" }!
        let best = ModelOption.recommended
        let fastFolder = root.appendingPathComponent("fast")
        let bestFolder = root.appendingPathComponent("best")
        for folder in [fastFolder, bestFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let defaults = UserDefaults(suiteName: "ScribeModels-\(UUID().uuidString)")!
        // Settings as an earlier build wrote them, plus one extra downloaded model and one whose files are gone.
        defaults.set(fast.id, forKey: "modelId")
        defaults.set(fastFolder.path, forKey: "modelFolder")
        defaults.set([best.id: bestFolder.path, "missing": root.appendingPathComponent("gone").path], forKey: "downloadedModels")

        let transcriber = Transcriber(library: try Library(root: root), modelsDirectory: root, defaults: defaults)

        XCTAssertEqual(transcriber.currentModel, fast)
        XCTAssertEqual(transcriber.downloadedModels, [fast.id: fastFolder.path, best.id: bestFolder.path])

        transcriber.deleteModel(fast)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastFolder.path), "the model in use can't be deleted")

        transcriber.deleteModel(best)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bestFolder.path))
        XCTAssertEqual(Set(transcriber.downloadedModels.keys), [fast.id])
        XCTAssertEqual(defaults.dictionary(forKey: "downloadedModels") as? [String: String], [fast.id: fastFolder.path])
    }
}
