import Foundation

@MainActor
final class RoomDataStore: ObservableObject {
    @Published private(set) var rooms: [RoomDataSummary] = []
    @Published var selectedRooms: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var message = ""
    @Published private(set) var errorMessage: String?

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var allSelected: Bool {
        !rooms.isEmpty && selectedRooms.count == rooms.count
    }

    func refresh() async {
        guard !isLoading && !isDeleting else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            rooms = try await client().listRooms()
            selectedRooms.formIntersection(rooms.map(\.name))
            message = rooms.isEmpty ? "No rooms currently contain stored data." : "\(rooms.count) non-empty room\(rooms.count == 1 ? "" : "s")."
        } catch {
            errorMessage = safeMessage(for: error)
        }
    }

    func toggleSelection(for room: String) {
        if selectedRooms.contains(room) {
            selectedRooms.remove(room)
        } else {
            selectedRooms.insert(room)
        }
    }

    func toggleAll() {
        selectedRooms = allSelected ? [] : Set(rooms.map(\.name))
    }

    func deleteSelected() async {
        await deleteRooms(selectedRooms)
    }

    func deleteRooms(_ pending: Set<String>) async {
        guard !pending.isEmpty && !isLoading && !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            let result = try await client().deleteRooms(pending)
            rooms.removeAll { pending.contains($0.name) }
            selectedRooms.subtract(pending)
            message = "Deleted \(result.rooms) room\(result.rooms == 1 ? "" : "s") and \(result.items) item\(result.items == 1 ? "" : "s")."
            await refreshAfterDeletion()
        } catch {
            errorMessage = safeMessage(for: error)
        }
    }

    func clearAllData() async {
        guard !isLoading && !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            let result = try await client().clearAllData()
            rooms = []
            selectedRooms = []
            message = "Deleted all stored data: \(result.rooms) room\(result.rooms == 1 ? "" : "s"), \(result.items) item\(result.items == 1 ? "" : "s"), and \(result.uploads) incomplete upload\(result.uploads == 1 ? "" : "s")."
        } catch {
            errorMessage = safeMessage(for: error)
        }
    }

    private func refreshAfterDeletion() async {
        do {
            rooms = try await client().listRooms()
            selectedRooms.formIntersection(rooms.map(\.name))
        } catch {
            errorMessage = "Deletion completed, but the room list could not be refreshed."
        }
    }

    private func client() throws -> RoomDataClient {
        let project = try settings.approvedProject()
        return try RoomDataClient(
            project: project,
            preferredDockerPath: settings.dockerPath,
            password: ClipSyncPasswordStore.currentPassword(in: project)
        )
    }

    private func safeMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "ClipSync Control could not manage room data."
    }
}
