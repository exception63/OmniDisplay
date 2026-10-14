import XCTest
@testable import OmniCore

final class ModeStabilityTests: XCTestCase {
    func office() -> [Display] {
        var d = Display.samples(4)
        d[0].x=0; d[0].y=0
        d[1].x=3000; d[1].y = -104
        d[2].x=1920; d[2].y = -535; d[2].width=1080; d[2].height=1920; d[2].pixelWidth=2160; d[2].pixelHeight=3840; d[2].rotation=270
        d[3].x = -1080; d[3].y = -461; d[3].width=1080; d[3].height=1920; d[3].pixelWidth=2160; d[3].pixelHeight=3840; d[3].rotation=270
        return d
    }
    func testRecordedOfficeReconfigurationThenCorrectSnapshots() throws {
        let expected=office();var incomplete=Array(expected.prefix(3));incomplete[1].y=0;incomplete[2].y=0
        // Anonymized geometry and post-commit sample completion offsets from the
        // failed final arrange and the two valid reads before its old rollback.
        let samples: [(Double,Result<[Display],Error>)] = [(0.560,.success(incomplete)),(1.637,.failure(ObservationNotSettled())),(1.891,.success(expected)),(1.982,.success(expected))]
        var index=0,clock=0.0
        let result=try ModeStability.wait(expected:expected,office:expected,matching:true,enabling:false,mayProceed:{true},read:{
            let s=samples[index];index+=1;clock=max(clock,s.0);return try s.1.get()
        },now:{clock},pause:{clock += $0})
        XCTAssertEqual(result,expected);XCTAssertEqual(index,4);XCTAssertLessThan(clock,2.5)
    }
    func testFailureResetsStableEvidence() throws {
        let expected=office();var count=0,clock=0.0
        _ = try ModeStability.wait(expected:expected,office:expected,matching:true,enabling:false,mayProceed:{true},read:{
            count+=1;clock+=0.05;if count==2 {throw ObservationNotSettled()};return expected
        },now:{clock},pause:{clock += $0})
        XCTAssertEqual(count,4)
    }
    func testUnstableReadCannotExtendDeadline() {
        let d=office();var clock=0.0
        XCTAssertThrowsError(try ModeStability.wait(expected:d,office:d,matching:true,enabling:false,mayProceed:{true},read:{clock+=0.7;throw ObservationNotSettled()},now:{clock},pause:{clock += $0}))
        XCTAssertLessThan(clock,3.3)
    }
    func testLateCorrectReadCannotPass() {
        let d=office();var clock=0.0
        XCTAssertThrowsError(try ModeStability.wait(expected:d,office:d,matching:true,enabling:false,mayProceed:{true},read:{clock+=1.3;return d},now:{clock},pause:{clock += $0}))
    }
    func testIdentityOrTransportFailureIsNotRetried() {
        let d=office();var count=0
        XCTAssertThrowsError(try ModeStability.wait(expected:d,office:d,matching:true,enabling:false,mayProceed:{true},read:{count+=1;throw OmniError.message("invalid observation identity")},pause:{_ in}))
        XCTAssertEqual(count,1)
    }
    func testUnknownScreenFailsImmediately() {
        let d=office();var unknown=d;unknown[1].id=UUID().uuidString;var count=0
        XCTAssertThrowsError(try ModeStability.wait(expected:d,office:d,matching:true,enabling:false,mayProceed:{true},read:{count+=1;return unknown},pause:{_ in}))
        XCTAssertEqual(count,1)
    }
    func testCancellationDuringTransientFailureStopsReadRetry() {
        let d=office();var proceed=true,count=0
        XCTAssertThrowsError(try ModeStability.wait(expected:d,office:d,matching:true,enabling:false,mayProceed:{proceed},read:{count+=1;proceed=false;throw ObservationNotSettled()},pause:{_ in}))
        XCTAssertEqual(count,1)
    }
}
