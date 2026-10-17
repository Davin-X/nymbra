import Foundation

/// A dependency-free test harness.
///
/// XCTest and swift-testing both require a full Xcode install; this project
/// targets the Command Line Tools only, so tests run via `swift run NymbraCheck`
/// (or `make test`) — locally and in CI, identically.
///
/// It is also the right tool for the job ahead: VT conformance is thousands of
/// input/expected-output pairs, which this harness can feed from fixtures.
final class Harness {
    private var suiteName = "<no suite>"
    private(set) var checks = 0
    private(set) var failures: [String] = []

    func suite(_ name: String) {
        suiteName = name
    }

    /// Assert a condition.
    func expect(
        _ condition: Bool,
        _ what: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        checks += 1
        if !condition {
            failures.append("\(suiteName) :: \(what)  [\(file):\(line)]")
        }
    }

    /// Assert two values are equal, reporting both when they are not.
    func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ what: String = "",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        checks += 1
        if actual != expected {
            let label = what.isEmpty ? "" : "\(what): "
            failures.append("\(suiteName) :: \(label)expected \(expected), got \(actual)  [\(file):\(line)]")
        }
    }

    /// Print a summary and return the process exit code.
    func report() -> Int32 {
        if failures.isEmpty {
            print("\u{2713} \(checks) checks passed")
            return 0
        }
        print("\u{2717} \(checks) checks, \(failures.count) failure(s)")
        for failure in failures {
            print("   FAIL  \(failure)")
        }
        return 1
    }
}
