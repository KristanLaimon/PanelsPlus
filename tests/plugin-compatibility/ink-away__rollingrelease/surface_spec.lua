-- Surface integration when testing the feature worktree; upstream fallback otherwise.
require("tests.compatibility_support.inkaway_surface")(assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE")))
