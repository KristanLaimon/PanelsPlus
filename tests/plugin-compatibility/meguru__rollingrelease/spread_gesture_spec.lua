-- Integration coverage against the selected pinned Meguru rolling checkout.
require("tests.plugin-compatibility.shared.meguru_spread")(assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE")))
