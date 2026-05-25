import Foundation

/// Stores Bluetooth authentication access codes per device UUID.
///
/// Pelagic dive computers (i330R/DSX) require a PIN-based pairing on first
/// connect; the device returns an access code that must be supplied on every
/// subsequent connect. The access code is persisted across app launches.
@objc public class AccessCodeStorage: NSObject {
    public static let shared = AccessCodeStorage()

    private let defaults = UserDefaults.standard
    private let storageKey = "com.libdc.accessCodes"

    private var codes: [String: Data] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
        load()
    }

    private func load() {
        guard let raw = defaults.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([String: Data].self, from: raw) {
            codes = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(codes) {
            defaults.set(data, forKey: storageKey)
        }
    }

    public func getAccessCode(uuid: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return codes[uuid]
    }

    public func setAccessCode(uuid: String, code: Data) {
        lock.lock(); defer { lock.unlock() }
        codes[uuid] = code
        save()
    }

    public func clearAccessCode(uuid: String) {
        lock.lock(); defer { lock.unlock() }
        codes.removeValue(forKey: uuid)
        save()
    }
}
