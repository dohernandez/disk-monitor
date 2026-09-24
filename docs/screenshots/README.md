# Documentation screenshots

These PNGs render the current app’s SwiftUI views with illustrative data from
`fixture.swift`. They are not captured from a live monitor or an account, and are
not evidence of real usage, disk capacity, provider limits, or model availability.

From the project root on macOS with Command Line Tools installed:

```sh
python3 docs/screenshots/render.py
```

The script creates a temporary source copy and executable, selects the documented
pages, and renders an offscreen AppKit hosting view. Preview-only application/window
subclasses report an active state; some native controls still render in neutral
gray offscreen. Alert text and custom badge colors retain their assigned colors. It does not change `main.swift`,
replace the installed app, create a menu bar icon, or request screen-capture access.
No collector, folder scanner, or normal app delegate is started. Disk Monitor’s
initializer is stripped of saved-state loading, filesystem queries and timers in
the temporary copy. Token Monitor’s collector is never started.

Review the PNGs before committing them. Source-rewriting assertions should fail if
the expected entry-point structure changes; update this helper alongside such changes.
These previews check static presentation, not popup interactions or menu bar behavior.

The renderer also compiles `Updates.swift`. Build first, or set `SPARKLE_TOOLS` to
the built `sparkle` directory. Rendering never starts the updater; its manual check
button is disabled and its version label says Preview in documentation images.

The Settings preview uses a taller canvas to show controls normally reached by scrolling.

Render only the illustrative manual Spotlight action with `python3 docs/screenshots/render.py spotlight` (set `SPARKLE_TOOLS` for an isolated build). This never invokes the action or authorization.
