-- Surface integration when testing the feature worktree; upstream fallback otherwise.
require("tests.plugin-compatibility.shared.inkaway_surface")(assert(os.getenv("PANELSPLUS_COMPATIBILITY_REFERENCE")))
