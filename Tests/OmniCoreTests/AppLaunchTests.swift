import XCTest
@testable import OmniCore

final class AppLaunchTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/tmp/launch-tests")
    func testProductionNeverAcceptsDemoArguments() throws {
        XCTAssertThrowsError(try AppLaunch.resolve(arguments: ["app", "--demo", "4"], bundleID: "example.app", simulationBundle: false, support: support))
        let live = try AppLaunch.resolve(arguments: ["app"], bundleID: "example.app", simulationBundle: false, support: support)
        XCTAssertFalse(live.simulation); XCTAssertEqual(live.demoCount, 0)
    }
    func testSimulationBundleAlwaysSimulatesEvenFromSearch() throws {
        let demo = try AppLaunch.resolve(arguments: ["app"], bundleID: "example.app.simulation", simulationBundle: true, support: support, savedProductionDirectory: "/tmp/real-data")
        XCTAssertTrue(demo.simulation); XCTAssertEqual(demo.demoCount, 4)
        XCTAssertEqual(demo.dataDirectory.path, "/tmp/launch-tests/OmniDisplay/Simulation")
        XCTAssertThrowsError(try AppLaunch.resolve(arguments: ["app"], bundleID: "example.app", simulationBundle: true, support: support))
        XCTAssertThrowsError(try AppLaunch.resolve(arguments: ["app"], bundleID: "example.app.simulation", simulationBundle: false, support: support))
    }
    func testDataAndNotificationCannotCrossModes() throws {
        let args = ["app", "--data-dir", "/tmp/shared"]
        let live = try AppLaunch.resolve(arguments: args, bundleID: "example.app", simulationBundle: false, support: support)
        let demo = try AppLaunch.resolve(arguments: args, bundleID: "example.app.simulation", simulationBundle: true, support: support)
        XCTAssertEqual(live.dataDirectory.path, "/tmp/shared")
        XCTAssertEqual(demo.dataDirectory.path, "/tmp/shared/Simulation")
        XCTAssertNotEqual(live.instanceKey, demo.instanceKey)
        XCTAssertNotEqual(live.notificationName, demo.notificationName)
    }
    func testProductionSearchReusesSavedDirectory() throws {
        let saved = try AppLaunch.resolve(arguments: ["app"], bundleID: "example.app", simulationBundle: false, support: support, savedProductionDirectory: "/tmp/existing-runtime")
        XCTAssertEqual(saved.dataDirectory.path, "/tmp/existing-runtime")
        let explicit = try AppLaunch.resolve(arguments: ["app", "--data-dir", "/tmp/explicit"], bundleID: "example.app", simulationBundle: false, support: support, savedProductionDirectory: "/tmp/existing-runtime")
        XCTAssertEqual(explicit.dataDirectory.path, "/tmp/explicit")
    }
    func testMalformedArgumentsFailClosed() {
        for args in [["app", "--demo"], ["app", "--demo", "0"], ["app", "--demo", "25"], ["app", "--demo", "x"], ["app", "--data-dir"], ["app", "--data-dir", "--demo", "4"]] {
            XCTAssertThrowsError(try AppLaunch.resolve(arguments: args, bundleID: "example.app.simulation", simulationBundle: true, support: support))
        }
    }
    func testInstanceLockSeparatesModesAndReleasesOnExit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var owner = try AppInstanceLock(directory: dir, key: "production")
        XCTAssertNotNil(owner)
        XCTAssertNil(try AppInstanceLock(directory: dir, key: "production"))
        let simulation = try AppInstanceLock(directory: dir, key: "simulation")
        XCTAssertNotNil(simulation)
        owner = nil
        let replacement = try AppInstanceLock(directory: dir, key: "production")
        XCTAssertNotNil(replacement)
        withExtendedLifetime((simulation, replacement)) {}
    }
}
