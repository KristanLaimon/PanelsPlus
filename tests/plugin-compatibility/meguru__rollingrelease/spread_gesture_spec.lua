-- Integration coverage against the selected pinned Meguru rolling checkout.
require("tests.compatibility_support.meguru_spread")(assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE")))
