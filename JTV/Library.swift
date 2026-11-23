import Foundation
import SwiftUI

// MARK: - Favorites

struct FavoriteRecord: Codable, Identifiable {
    var pluginId: String = ""
    var movie: Movie = Movie()
    var addedAt: Date = Date()

    var id: String { pluginId + "|" + movie.id }
}

@MainActor
final class FavoritesManager: ObservableObject {
    @Published private(set) var records: [FavoriteRecord] = []

    private let defaultsKey = "jtv_favorites"

    init() { load() }

    func isFavorite(pluginId: String, movieId: String) -> Bool {
        records.contains { $0.pluginId == pluginId && $0.movie.id == movieId }
    }

    func toggle(pluginId: String, movie: Movie) {
        if isFavorite(pluginId: pluginId, movieId: movie.id) {
            records.removeAll { $0.pluginId == pluginId && $0.movie.id == movie.id }
        } else {
            records.insert(FavoriteRecord(pluginId: pluginId, movie: movie, addedAt: Date()), at: 0)
        }
        save()
        Haptics.select()
    }

    func remove(_ record: FavoriteRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func remove(pluginId: String, movieId: String) {
        records.removeAll { $0.pluginId == pluginId && $0.movie.id == movieId }
        save()
    }

    /// Re-keys a stored favorite whose snapshot carries a bad
    /// movie id (older builds could store the detail's empty
    /// or plugin-internal id, which made the entry impossible
    /// to open and the heart impossible to match). Matched by
    /// plugin + old id + title so sibling entries stay put.
    func repairMovieId(pluginId: String, from oldId: String, title: String, to newId: String) {
        guard oldId != newId,
              let idx = records.firstIndex(where: {
                  $0.pluginId == pluginId && $0.movie.id == oldId && $0.movie.title == title
              }) else { return }
        records[idx].movie.id = newId
        save()
    }

    func clearAll() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([FavoriteRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Watch history / continue watching

struct HistoryRecord: Codable, Identifiable {
    var pluginId: String = ""
    var pluginName: String = ""
    var isManga: Bool = false
    var movie: Movie = Movie()
    var serverName: String = ""
    var episodeName: String = ""
    var episodeId: String = ""        // play target used to (re)resolve the episode
    var streamURL: String = ""        // last resolved direct stream URL (fast resume)
    var lastPosition: Double = 0      // seconds for video; image index for manga
    var duration: Double = 0
    var updatedAt: Date = Date()

    var id: String { pluginId + "|" + movie.id }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, lastPosition / duration))
    }

    var isFinished: Bool { duration > 0 && progress > 0.92 }
}

@MainActor
final class WatchHistoryManager: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []

    private let defaultsKey = "jtv_watch_history"
    private let maxRecords = 60
    private var lastSaveAt: [String: Date] = [:]

    init() { load() }

    func record(for pluginId: String, movieId: String) -> HistoryRecord? {
        records.first { $0.pluginId == pluginId && $0.movie.id == movieId }
    }

    /// Upserts a progress record. Saves are throttled to one per 2 seconds
    /// per movie unless `force` is set (pause / exit paths).
    func upsert(_ record: HistoryRecord, force: Bool = false) {
        let key = record.id
        if !force, let last = lastSaveAt[key], Date().timeIntervalSince(last) < 2 {
            return
        }
        lastSaveAt[key] = Date()
        var updated = record
        updated.updatedAt = Date()
        if let idx = records.firstIndex(where: { $0.id == key }) {
            records[idx] = updated
        } else {
            records.insert(updated, at: 0)
        }
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        save()
    }

    func remove(_ record: HistoryRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clearAll() {
        records.removeAll()
        lastSaveAt.removeAll()
        save()
    }

    /// Records not yet (nearly) finished — the Continue Watching rows.
    var continueWatching: [HistoryRecord] {
        records.filter { !$0.isFinished }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return }
        records = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Playback presentation

/// Shared presenter so any tab can hand a PlaybackRequest to the
/// full-screen player cover hosted by ContentView.
@MainActor
final class PlaybackPresenter: ObservableObject {
    @Published var request: PlaybackRequest?
}
