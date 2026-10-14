import XCTest
@testable import OmniCore

final class RotationWaitTests: XCTestCase {
    func testDelayedAngleAfterOld650msLimitCompletesWithoutRetryingWrite() throws {
        var clock=0.0, reads=0
        let original=Display.samples(2)
        let result=try RotationWait.wait(target:original[1].id,degrees:270,timeout:2.5,read:{
            reads+=1;var sample=original
            sample[1].rotation=clock >= 1.1 ? 270 : 0
            return sample
        },now:{clock},pause:{clock+=$0})
        XCTAssertEqual(result[1].rotation,270)
        XCTAssertGreaterThan(clock,0.65);XCTAssertLessThan(clock,2.5)
        XCTAssertGreaterThan(reads,10)
    }
    func testUnchangedWrongAngleNeverCountsAsCompletion() {
        var clock=0.0
        let original=Display.samples(2)
        XCTAssertThrowsError(try RotationWait.wait(target:original[1].id,degrees:270,timeout:2.5,read:{original},now:{clock},pause:{clock+=$0})) { error in
            XCTAssertTrue(error.localizedDescription.contains("最近读数0.0"))
        }
        XCTAssertEqual(clock,2.5,accuracy:0.001)
    }
    func testIdentityValidationFailureImmediatelyStopsWaiting() {
        var clock=0.0, reads=0
        XCTAssertThrowsError(try RotationWait.wait(target:"target",degrees:270,timeout:2.5,read:{
            reads+=1;throw OmniError.message("identity changed")
        },now:{clock},pause:{clock+=$0}))
        XCTAssertEqual(reads,1);XCTAssertEqual(clock,0)
    }
}
