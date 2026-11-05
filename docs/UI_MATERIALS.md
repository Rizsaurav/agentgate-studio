# Native UI materials

The `ui/native-glass` branch refines the existing SwiftUI presentation. It is based
on `f650b83` and is developed in a separate worktree so the active native runtime
and sandbox work can continue independently. It does not choose between the web,
Electron, and SwiftUI architectures or replace any execution components.

## Visual direction

- Use a real AppKit sidebar material to show the desktop through the navigation.
- Use one Liquid Glass surface for toolbar controls and another for the composer.
- Keep transcripts and security evidence on quiet, readable charcoal surfaces.
- Remove redundant panel borders, reduce title weight, and soften the violet accent.
- Preserve control labels, shortcuts, actions, and state-derived activity indicators.

This follows Apple's [materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials)
and [custom Liquid Glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).
Glass distinguishes navigation and controls; it is not applied to every content card.
No new dependencies or decorative animations are introduced.

## Compatibility and accessibility

macOS 26 and newer use SwiftUI's native `glassEffect`. The existing macOS 14 minimum
is retained, with regular system material on older systems. A compiler guard lets
older Swift toolchains build the fallback without referencing unavailable APIs.
Reduce Transparency or Increase Contrast selects an opaque surface with a stronger
edge. Reduce Motion disables the custom interactive glass reaction. The sidebar
follows the window's active/inactive state.

## Review boundaries

Build and run the Swift tests with `swift build --package-path mac` and
`swift test --package-path mac`. Visual review must not launch a second production
instance during parallel runtime work: normal startup reaps orphaned model engines.
Use an isolated preview host without the production startup/termination hooks,
without model actions, and with its own temporary data directory. Such a preview
checks presentation only; it is not evidence of model or security execution.

The native text-field prompt dropped custom colors during visual review. A small
`inputHint` view modifier draws the hint with the correct contrast, keeps it out
of hit testing, hides it when text is present, and retains the accessibility hint.
This workaround is confined to the three affected input views.

Verified on macOS 27.2: debug and release compilation, 113 Swift tests in 22 suites,
and isolated visual review of the workspace, empty conversation/composer, and
security screen. Text entry was checked without submitting a model request.
Older-macOS fallback and system accessibility toggles have not been exercised on
a separate OS installation. No live model, paid API, or security evaluation is
claimed by this UI review.
