import Foundation
import Testing
@testable import RustIDECore

@Suite struct CoverageTests {
    @Test func parsesLCOV() throws {
        let lcov = """
            SF:/r/src/lib.rs
            FN:1,add
            FNDA:1,add
            DA:1,1
            DA:2,1
            DA:4,0
            DA:5,0
            LF:4
            LH:2
            end_of_record
            SF:/r/src/lib.rs
            DA:4,3
            end_of_record
            SF:/Users/me/.cargo/registry/src/serde/lib.rs
            DA:1,9
            end_of_record
            SF:/rust/library/core/src/fmt.rs
            DA:10,1
            end_of_record
            SF:/r/src/empty.rs
            end_of_record
            """
        let report = CoverageReport.parseLCOV(lcov, root: "/r")
        #expect(Set(report.files.keys) == ["/r/src/lib.rs"])
        let lib = try #require(report.files["/r/src/lib.rs"])
        #expect(lib.lines == [0: true, 1: true, 3: true, 4: false])  // line 4 ran in the second record
        #expect(lib.statements == 4 && lib.coveredStatements == 3 && lib.percent == 75)
        #expect(report.percent == 75)
        #expect(CoverageReport.parseLCOV(lcov, root: "/r/").files.count == 1)
    }
}
