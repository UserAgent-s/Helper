import CompanionProtocol
import Foundation
import Testing
@testable import Persistence

@Suite struct SQLitePairedDeviceStoreTests {
    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("useragent057-paired-\(UUID().uuidString).sqlite3")
            .path
    }

    @Test func pairingSurvivesReopenAndRevokeDeletesRows() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = PairingStore(storage: SQLitePairedDeviceStore(path: path))
        let grant = try await first.redeem(code: await first.issueCode(.qr128).value, deviceName: "MacBook M1")
        _ = try await first.authenticate(token: grant.deviceToken)

        let reopenedStorage = SQLitePairedDeviceStore(path: path)
        let rows = try await reopenedStorage.loadAll()
        #expect(rows.count == 1)
        #expect(rows[0].tokenHash == CompanionSecrets.sha256Hex(grant.deviceToken))
        #expect(rows[0].lastSeenAt != nil)

        let second = PairingStore(storage: reopenedStorage)
        #expect(try await second.authenticate(token: grant.deviceToken)?.deviceId == grant.deviceId)
        try await second.revoke(deviceId: grant.deviceId)
        #expect(try await reopenedStorage.loadAll().isEmpty)
    }

    @Test func rawTokenNeverReachesDatabaseFile() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(storage: SQLitePairedDeviceStore(path: path))
        let grant = try await store.redeem(code: await store.issueCode(.numeric6).value, deviceName: "A")
        let database = SQLiteDatabase(path: path)
        try await database.ensureReady()
        let all = try await database.query("SELECT device_id || name || token_hash || created_at FROM paired_devices", map: { $0.string(0) ?? "" })
        #expect(all.count == 1)
        #expect(!all[0].contains(grant.deviceToken))
    }

    @Test func deleteAllClearsTable() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let storage = SQLitePairedDeviceStore(path: path)
        try await storage.insert(PairedDevice(deviceId: "a", name: "A", tokenHash: "h1", createdAt: Date()))
        try await storage.insert(PairedDevice(deviceId: "b", name: "B", tokenHash: "h2", createdAt: Date()))
        try await storage.deleteAll()
        #expect(try await storage.loadAll().isEmpty)
    }
}
