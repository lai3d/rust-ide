import Foundation
import Testing
@testable import RustIDECore

@Suite struct MacroExpansionTests {
    @Test func parsesAndNamesTheTab() throws {
        #expect(MacroExpansion(json: .null) == nil)
        let expansion = try #require(MacroExpansion(json: ["name": "vec!", "expansion": "<[_]>::into_vec(...)"]))
        #expect(expansion.fileName == "vec! expansion.rs")
        #expect(MacroExpansion(name: "a/b", expansion: "").fileName == "a_b! expansion.rs")
        #expect(expansion.documentText.hasPrefix("// Recursive expansion of vec! macro\n"))
        #expect(expansion.documentText.hasSuffix("<[_]>::into_vec(...)\n"))
    }

    @Test(.enabled(if: RustAnalyzerHarness.available), .timeLimit(.minutes(2)))
    func expandsFunctionLikeMacros() async throws {
        let source = """
            #[derive(Debug)]
            struct Point { x: i32 }

            macro_rules! double { ($e:expr) => { $e * 2 }; }

            fn main() {
                let p = Point { x: double!(21) };
                println!("{:?}", p);
            }

            """
        let ra = try await RustAnalyzerHarness(files: ["src/main.rs": source])
        try await ra.open("src/main.rs")
        let double = MacroExpansion(json: try await ra.request("rust-analyzer/expandMacro", ra.at("src/main.rs", 6, 25)))
        #expect(double?.name == "double", "\(String(describing: double))")
        #expect(double?.expansion.contains("21*2") == true || double?.expansion.contains("21 * 2") == true,
                "\(String(describing: double))")
        let println = MacroExpansion(json: try await ra.request("rust-analyzer/expandMacro", ra.at("src/main.rs", 7, 6)))
        #expect(println?.name == "println" && println?.expansion.contains("_print") == true, "\(String(describing: println))")
        let none = try await ra.request("rust-analyzer/expandMacro", ra.at("src/main.rs", 5, 3))
        #expect(MacroExpansion(json: none) == nil)
        await ra.shutdown()
    }
}
