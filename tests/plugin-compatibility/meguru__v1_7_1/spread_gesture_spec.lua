-- Integration coverage against the selected immutable Meguru v1.7.1 pin.
require("tests.plugin-compatibility.shared.meguru_spread")(assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE")))
