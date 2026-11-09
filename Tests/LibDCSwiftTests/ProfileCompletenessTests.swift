import XCTest
@testable import LibDCSwift

final class ProfileCompletenessTests: XCTestCase {
    private func dive(profileUntil span: TimeInterval, reported: TimeInterval?, step: TimeInterval = 2) -> DiveData {
        let profile = stride(from: 0, through: span, by: step).map { DiveProfilePoint(time: $0, depth: 10) }
        return DiveData(
            number: 1, datetime: Date(timeIntervalSince1970: 0),
            maxDepth: 10, avgDepth: 8, divetime: min(span, reported ?? span), temperature: 20,
            profile: profile, tankPressure: [], gasMix: nil, gasMixCount: nil, gasMixes: nil,
            salinity: nil, atmospheric: nil, surfaceTemperature: nil, minTemperature: nil, maxTemperature: nil,
            tankCount: nil, tanks: nil, diveMode: nil, decoModel: nil, location: nil,
            rbt: nil, heartbeat: nil, bearing: nil, setpoint: nil, ppo2Readings: [], cns: nil, decoStop: nil,
            reportedDivetime: reported)
    }

    func testOSTC5TransferLossIsDetected() {
        // debug/393218_68_1a0b08093a.bin: 828 samples à 2 s vs. 43:48 stated by the computer.
        let data = dive(profileUntil: 1656, reported: 2628)
        XCTAssertTrue(data.isProfileIncomplete)
        XCTAssertEqual(data.profileSpan, 1656)
    }

    func testCompleteProfileIsNotFlagged() {
        XCTAssertFalse(dive(profileUntil: 2620, reported: 2628).isProfileIncomplete)
    }

    func testWholeMinuteRoundingAndShortSurfacePhaseAreTolerated() {
        // 3 min short on a 60 min dive: below the 15 % margin.
        XCTAssertFalse(dive(profileUntil: 3420, reported: 3600).isProfileIncomplete)
        // Short dive: 2 min short is within the 3 min floor.
        XCTAssertFalse(dive(profileUntil: 480, reported: 600).isProfileIncomplete)
    }

    func testProfileLongerThanStatedTimeIsNotFlagged() {
        // Suunto keeps sampling at the surface after the dive.
        XCTAssertFalse(dive(profileUntil: 2220, reported: 1922).isProfileIncomplete)
    }

    func testWithoutStatedTimeOrProfileNothingIsFlagged() {
        XCTAssertFalse(dive(profileUntil: 1000, reported: nil).isProfileIncomplete)
        var empty = dive(profileUntil: 0, reported: 2628)
        empty.profile = []
        XCTAssertFalse(empty.isProfileIncomplete)
    }

    func testReportedDivetimeSurvivesCodableAndOldPayloadsStillDecode() throws {
        let data = dive(profileUntil: 1656, reported: 2628)
        let decoded = try JSONDecoder().decode(DiveData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded.reportedDivetime, 2628)
        XCTAssertTrue(decoded.isProfileIncomplete)

        // Payload stored before the field existed.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any])
        json.removeValue(forKey: "reportedDivetime")
        let old = try JSONDecoder().decode(DiveData.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.reportedDivetime)
        XCTAssertFalse(old.isProfileIncomplete)
    }

    /// Real OSTC 5 dive (firmware 1.7.5) downloaded over BLE on iOS: the BT
    /// module dropped ~5.8 kB in the middle, the stream still ended with FD FD.
    func testRealOSTC5DiveWithTransferLossIsFlagged() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ostc5_ble_loss_1a0b08093a", withExtension: "bin"))
        let raw = try Data(contentsOf: url)
        let data = try raw.withUnsafeBytes { buffer in
            try GenericParser.parseDiveData(
                family: .hwOstc3, model: 0x44, diveNumber: 1,
                diveData: buffer.bindMemory(to: UInt8.self).baseAddress!, dataSize: raw.count)
        }
        XCTAssertEqual(data.reportedDivetime, 43 * 60 + 48)
        XCTAssertTrue(data.isProfileIncomplete, "profile covers \(data.profileSpan) s")
    }

    func testDeferredFingerprintIsOnlyStoredOnCommit() {
        let viewModel = DiveDataViewModel()
        viewModel.defersFingerprintCommit = true
        let serial = "test-\(UUID().uuidString)"
        defer { viewModel.clearFingerprint(forDeviceType: "Test", serial: serial) }

        viewModel.saveFingerprint(Data([1, 2, 3]), deviceType: "Test", serial: serial)
        XCTAssertNil(viewModel.getFingerprint(forDeviceType: "Test", serial: serial))

        viewModel.discardPendingFingerprint()
        viewModel.commitPendingFingerprint()
        XCTAssertNil(viewModel.getFingerprint(forDeviceType: "Test", serial: serial))

        viewModel.saveFingerprint(Data([4, 5, 6]), deviceType: "Test", serial: serial)
        viewModel.commitPendingFingerprint()
        XCTAssertEqual(viewModel.getFingerprint(forDeviceType: "Test", serial: serial), Data([4, 5, 6]))
    }
}
