-- Integration coverage against the selected immutable Meguru v1.8.10 pin.
require("tests.compatibility_support.meguru_spread")(assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE")))
