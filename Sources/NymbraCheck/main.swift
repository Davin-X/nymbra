import Foundation

// Entry point for the test harness. `make test` runs this.
//
// Add new suites here as the project grows.

let harness = Harness()

keyboardSuite(harness)
screenSuite(harness)
gridSuite(harness)
viewportSuite(harness)
parserSuite(harness)
configurationSuite(harness)
paletteSuite(harness)
selectionSuite(harness)
shortcutSuite(harness)
ptySuite(harness)
paneLayoutSuite(harness)

exit(harness.report())
