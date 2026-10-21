import XCTest
@testable import OmniCore

/// omnidisplay 命令行（agent 控制）：编号、过期、收件箱读写。真实写入仍由 App 的事务流程做，这里不碰显示器。
final class AgentControlTests: XCTestCase {
    /// 和 Studio 现场同形：左竖屏、主屏、竖屏、右横屏。
    func studio() -> [Display] {
        var d = Display.samples(4)
        d[0].main = false; d[0].x = -1080; d[0].y = -461; d[0].width = 1080; d[0].height = 1920; d[0].rotation = 270
        d[1].main = true;  d[1].x = 0;     d[1].y = 0
        d[2].main = false; d[2].x = 1920;  d[2].y = -535; d[2].width = 1080; d[2].height = 1920; d[2].rotation = 270
        d[3].main = false; d[3].x = 3000;  d[3].y = -104
        return d.reversed() // 输入顺序无关
    }

    func testAllConnectedCountsLeftToRight() {
        let d = studio()
        let order = ScreenNumbering.ordered(current: d, references: [])
        XCTAssertEqual(order.map(\.x), [-1080, 0, 1920, 3000])
        XCTAssertTrue(order[1].main)
        XCTAssertEqual(AgentScreen(number: 1, display: order[0]).portrait, true)
        XCTAssertEqual(AgentScreen(number: 4, display: order[3]).portrait, false)
    }

    func testMiddleDisconnectedKeepsNumbersFromFullArrangement() throws {
        let full = studio()
        let original = Snapshot(boot: "simulation", displays: full)
        // 断开第 3 块后剩下的靠拢：第 4 块挪到了 1920；第 3 块离线，位置是旧的。
        var current = full
        let third = full.first { $0.x == 1920 }!.id, fourth = full.first { $0.x == 3000 }!.id
        current = current.map { var c = $0; if c.id == third { c.active = false }; if c.id == fourth { c.x = 1920 }; return c }
        let order = ScreenNumbering.ordered(current: current, references: [original])
        XCTAssertEqual(order[2].id, third)
        XCTAssertEqual(order[3].id, fourth)
        XCTAssertFalse(order[2].active)
    }

    func testReferenceMustCoverAllKnownScreens() {
        var d = studio()
        let partial = Snapshot(boot: "simulation", displays: Array(d.prefix(2)))
        let full = Snapshot(boot: "simulation", displays: d)
        d = d.map { var c = $0; if c.x == 3000 { c.active = false; c.x = 9999 }; return c }
        let order = ScreenNumbering.ordered(current: d, references: [partial, full])
        XCTAssertEqual(order.last?.active, false)   // 按完整那份，离线的仍是第 4 块
        XCTAssertEqual(order.count, 4)
    }

    func testUnknownScreenIsAppendedNotRenumbered() {
        let d = studio()
        var extra = Display.samples(5)[4]; extra.x = -5000; extra.active = true
        var current = d.map { var c = $0; if c.x == 1920 { c.active = false }; return c }
        current.append(extra)
        let order = ScreenNumbering.ordered(current: current, references: [Snapshot(boot: "simulation", displays: d)])
        XCTAssertEqual(order.map(\.id).prefix(4), ScreenNumbering.ordered(current: d, references: []).map(\.id).prefix(4))
        XCTAssertEqual(order.last?.id, extra.id)
    }

    func testStaleAndFutureRequestsExpire() {
        let now = Date()
        XCTAssertFalse(AgentMailbox.expired(AgentRequest(command: .disconnect, number: 4, now: now), now: now.addingTimeInterval(5)))
        XCTAssertTrue(AgentMailbox.expired(AgentRequest(command: .disconnect, number: 4, now: now), now: now.addingTimeInterval(AgentMailbox.maxAge + 1)))
        XCTAssertTrue(AgentMailbox.expired(AgentRequest(command: .disconnect, number: 4, now: now.addingTimeInterval(60)), now: now))
    }

    func testMailboxRoundTripIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = AgentMailbox.directory(support: root, instanceKey: "com.example.Omni Display.production")
        try AgentMailbox.prepare(dir)
        XCTAssertTrue(dir.path.hasSuffix("OmniDisplay/Agent/com.example.Omni_Display.production"))
        let request = AgentRequest(command: .rotate, number: 3, rotation: "clockwise")
        let file = AgentMailbox.requests(dir).appendingPathComponent("1-\(request.id).json")
        try AgentMailbox.write(request, to: file)
        let back = try AgentMailbox.read(AgentRequest.self, from: file)
        XCTAssertEqual(back.id, request.id); XCTAssertEqual(back.command, .rotate); XCTAssertEqual(back.number, 3)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: AgentMailbox.requests(dir).path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertFalse(AgentMailbox.instanceRunning(support: root, instanceKey: "com.example.Omni Display.production"))
    }

    func testOriginIsPartOfConsentDigest() throws {
        let snap = Snapshot(boot: "x", displays: Display.samples(2))
        var request = Request(operation: .disconnect, before: snap, office: snap, keep: snap.displays[0].id, confirmedPhysical: true, simulation: false, target: snap.displays[1].id)
        let plain = try LiveTestConsent.digest(request)
        request.origin = "agent"
        XCTAssertNotEqual(plain, try LiveTestConsent.digest(request))
        let consent = try LiveTestConsent.grant(request: request, confirmedTarget: snap.displays[1].id, riskAcknowledged: true)
        request.liveConsent = consent
        XCTAssertNoThrow(try LiveTestConsent.validate(request))
        request.origin = nil   // 事后改来源，许可作废
        XCTAssertThrowsError(try LiveTestConsent.validate(request))
    }
}
