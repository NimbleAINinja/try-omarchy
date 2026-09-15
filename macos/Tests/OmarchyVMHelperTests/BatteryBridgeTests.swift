import Foundation
import Testing

@testable import OmarchyVMHelper

@Suite struct HostBatterySnapshotTests {
    private func description(
        percent: Int = 57,
        max: Int = 100,
        state: String = "Battery Power",
        charging: Bool = false,
        charged: Bool = false,
        toEmptyMinutes: Int = 135,
        toFullMinutes: Int = -1
    ) -> [String: Any] {
        [
            "Type": "InternalBattery",
            "Is Present": true,
            "Current Capacity": percent,
            "Max Capacity": max,
            "Power Source State": state,
            "Is Charging": charging,
            "Is Charged": charged,
            "Time to Empty": toEmptyMinutes,
            "Time to Full Charge": toFullMinutes,
        ]
    }

    @Test func dischargingSnapshotEncodesTheWireContract() throws {
        let snapshot = HostBatterySnapshot(descriptions: [description()])
        #expect(snapshot.present)
        #expect(snapshot.percentage == 57)
        #expect(snapshot.state == "discharging")
        #expect(!snapshot.acConnected)
        #expect(snapshot.timeToEmptySeconds == 135 * 60)
        #expect(snapshot.timeToFullSeconds == nil)
        let line = String(data: snapshot.encode(), encoding: .utf8)!
        #expect(line.hasSuffix("\n"))
        let object = try JSONSerialization.jsonObject(
            with: snapshot.encode()) as! [String: Any]
        #expect(object["type"] as? String == "state")
        #expect(object["percentage"] as? Int == 57)
        #expect(object["timeToFullSeconds"] is NSNull)
    }

    @Test func chargingAndChargedMapToTheProtocolTokens() {
        let charging = HostBatterySnapshot(descriptions: [
            description(state: "AC Power", charging: true, toEmptyMinutes: -1, toFullMinutes: 45)
        ])
        #expect(charging.state == "charging")
        #expect(charging.acConnected)
        #expect(charging.timeToFullSeconds == 45 * 60)
        let full = HostBatterySnapshot(descriptions: [
            description(percent: 100, state: "AC Power", charged: true, toEmptyMinutes: -1)
        ])
        #expect(full.state == "full")
        let idle = HostBatterySnapshot(descriptions: [
            description(state: "AC Power", toEmptyMinutes: -1)
        ])
        #expect(idle.state == "not-charging")
    }

    @Test func desktopMacReportsNoBatteryOnMains() {
        let snapshot = HostBatterySnapshot(descriptions: [])
        #expect(!snapshot.present)
        #expect(snapshot.percentage == nil)
        #expect(snapshot.acConnected)
        #expect(snapshot.state == "unknown")
    }

    @Test func percentageIsScaledByMaxCapacity() {
        let snapshot = HostBatterySnapshot(descriptions: [
            description(percent: 40, max: 80)
        ])
        #expect(snapshot.percentage == 50)
    }
}

@Suite struct BatterySendPolicyTests {
    @Test func duplicateSnapshotsAreCoalescedUntilForced() {
        var policy = BatterySendPolicy()
        let snapshot = HostBatterySnapshot(descriptions: [])
        #expect(policy.shouldSend(snapshot, forced: false))
        policy.markSent(snapshot)
        #expect(!policy.shouldSend(snapshot, forced: false))
        #expect(policy.shouldSend(snapshot, forced: true))
    }

    @Test func changedSnapshotAlwaysSends() {
        var policy = BatterySendPolicy()
        let mains = HostBatterySnapshot(descriptions: [])
        policy.markSent(mains)
        let battery = HostBatterySnapshot(descriptions: [[
            "Type": "InternalBattery",
            "Is Present": true,
            "Current Capacity": 12,
            "Max Capacity": 100,
            "Power Source State": "Battery Power",
            "Is Charging": false,
            "Is Charged": false,
            "Time to Empty": -1,
            "Time to Full Charge": -1,
        ]])
        #expect(policy.shouldSend(battery, forced: false))
    }
}

@Suite struct BatteryGuestRequestTests {
    @Test func refreshLineIsRecognizedAndOthersAreIgnored() {
        #expect(NativeBatteryBridge.isRefreshRequest(Data(#"{"type":"refresh"}"#.utf8)))
        #expect(!NativeBatteryBridge.isRefreshRequest(Data(#"{"type":"state"}"#.utf8)))
        #expect(!NativeBatteryBridge.isRefreshRequest(Data("garbage".utf8)))
    }
}
