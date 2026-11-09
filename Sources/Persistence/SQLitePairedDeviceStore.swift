import CompanionProtocol
import Foundation

public final class SQLitePairedDeviceStore: PairedDeviceStoring, Sendable {
    private let connection: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        connection = database
    }

    public convenience init(path: String) {
        self.init(database: SQLiteDatabase(path: path))
    }

    public func loadAll() async throws -> [PairedDevice] {
        try await connection.ensureReady()
        return try await connection.query(
            "SELECT device_id, name, token_hash, created_at, last_seen_at FROM paired_devices ORDER BY created_at",
            map: { row in
                PairedDevice(
                    deviceId: row.string(0) ?? "",
                    name: row.string(1) ?? "",
                    tokenHash: row.string(2) ?? "",
                    createdAt: row.string(3).flatMap(Self.date) ?? Date(timeIntervalSince1970: 0),
                    lastSeenAt: row.string(4).flatMap(Self.date)
                )
            }
        )
    }

    public func insert(_ device: PairedDevice) async throws {
        try await connection.ensureReady()
        try await connection.run(
            "INSERT INTO paired_devices (device_id, name, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)",
            [
                .text(device.deviceId),
                .text(device.name),
                .text(device.tokenHash),
                .text(Self.string(device.createdAt)),
                device.lastSeenAt.map { .text(Self.string($0)) } ?? .null,
            ]
        )
    }

    public func updateLastSeen(deviceId: String, at date: Date) async throws {
        try await connection.ensureReady()
        try await connection.run("UPDATE paired_devices SET last_seen_at = ? WHERE device_id = ?", [.text(Self.string(date)), .text(deviceId)])
    }

    public func delete(deviceId: String) async throws {
        try await connection.ensureReady()
        try await connection.run("DELETE FROM paired_devices WHERE device_id = ?", [.text(deviceId)])
    }

    public func deleteAll() async throws {
        try await connection.ensureReady()
        try await connection.run("DELETE FROM paired_devices")
    }

    private static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
