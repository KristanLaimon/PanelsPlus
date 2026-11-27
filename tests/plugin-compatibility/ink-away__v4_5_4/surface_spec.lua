-- Stable 4.5.4 must exercise the public surface API rather than fallback behavior.
require("tests.compatibility_support.inkaway_surface")(assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE")), true)
