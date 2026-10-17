# Smooth transition styles

The CSS term is **easing function**, also called a **timing function**. It describes how an animation progresses over time: whether it moves steadily, accelerates, or slows down before finishing. “Ease styles” is understandable, but “easing functions” is the usual name.

In Panels+, open the transition button's options and tap **Smooth style** to cycle through the choices below. The CSS-named styles control both camera movement and gradual zoom during transitions between panels on the same page or extracted image.

| Style | Timing | What it feels like | CSS equivalent |
| --- | --- | --- | --- |
| `linear` | Progress changes evenly throughout the transition. | Steady movement without deliberate acceleration or deceleration. | `linear` |
| `ease` **(default)** | Starts slowly, accelerates early, then slows down toward the destination. | A quick movement with a gentle landing; the acceleration and deceleration are not symmetrical. | `cubic-bezier(0.25, 0.1, 0.25, 1)` |
| `ease-in` | Starts slowly and accelerates toward the end. | Builds momentum as it approaches the next panel. | `cubic-bezier(0.42, 0, 1, 1)` |
| `ease-out` | Starts quickly and decelerates toward the end. | Responds quickly, then settles gently onto the next panel. | `cubic-bezier(0, 0, 0.58, 1)` |
| `ease-in-out` | Accelerates through the first half and decelerates through the second half. | A balanced slow start and slow finish, with faster movement in the middle. | `cubic-bezier(0.42, 0, 0.58, 1)` |
| **Classic** | Uses linear timing with the earlier fixed-zoom camera pan. | Slides between panels at the destination's zoom instead of gradually zooming in or out. | No direct CSS equivalent: Classic changes the rendering approach, not just the timing curve. |

**Classic here is a Smooth style.** It is separate from the top-level **Classic navigation mode**, which switches panels without a Smooth animation.

## Duration, frames, and previews

- **Duration** controls the transition's timing budget. The default is **400 ms**. Rendering and display updates can make the actual transition take longer.
- **Frames** controls the number of animation steps, not a guaranteed FPS. The maximum is **60**. First-install defaults are **24 frames on Android/desktop** and **2 frames on e-readers**. Existing saved values are preserved.
- Changing an easing function does not change the configured duration or frame count. Panel sizes, zoom, and device performance can still affect the perceived speed.
- **Preview smooth transitions** plays a round trip, hides the Panels+ controls, restores the original panel, and reopens settings. At the last panel, it previews backward first.

Older **Modern**, `step-start`, and `step-end` selections are treated as `linear`; they are no longer separate choices.

The CSS timing definitions follow the [W3C CSS Easing Functions specification](https://www.w3.org/TR/css-easing-1/#cubic-bezier-easing-functions). Panels+ implements these curves in [src/_naveasing.lua](../src/_naveasing.lua).
