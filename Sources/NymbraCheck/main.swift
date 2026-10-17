import Foundation

// Entry point for the test harness. `make test` runs this.
//
// Add new suites here as the project grows.

let harness = Harness()

keyboardSuite(harness)
screenSuite(harness)
viewportSuite(harness)
parserSuite(harness)
configurationSuite(harness)

exit(harness.report())
