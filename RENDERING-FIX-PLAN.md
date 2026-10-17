# Rendering repair plan

Investigation date: 2026-10-17. The findings below record the original failures.
The repairs and regression tests have now been implemented. Suspend/resume
itself still requires verification on the laptop.

The extent fix uses bounded list and quote renderers rather than expanding a
small update to an entire enclosing container: measuring a 3,000-item list
showed that whole-list redraw took about 2.4 seconds, while bounded rendering
took about 1 ms. Complete paragraphs, code fences, and tables remain atomic.
`markdown-modern-refresh` provides explicit recovery for already-damaged buffers.

## Findings and evidence

### 1. Code editing deletes rendering elsewhere in the source buffer

This is a confirmed, reproducible cause of missing rendering. Laptop resume
is not required to trigger it. Whether it caused the original incident is
not established, but it produces the same missing-overlays/`fontified=t`
state observed in README.

The sequence is:

1. `markdown-modern-edit-code-block` creates an indirect buffer with
   `make-indirect-buffer` and `CLONE=t`. Buffer-local renderer state and the
   major-mode teardown hook are copied, including references to the source
   buffer's overlay objects.
2. Selecting the code language's major mode runs the copied
   `markdown-modern--teardown-buffer` hook in the indirect buffer.
3. `markdown-modern-render--clear-all` deletes every live overlay referenced
   by that copied list, without checking which buffer owns it.
4. The source buffer retains references to the deleted overlays and still
   has `fontified=t` on surrounding text. Finish, abort, and external kill
   render only the code block, so the rest of the document stays damaged.

In a disposable document with bold paragraphs before and after an Elisp
fence, batch execution and the real `C-c '` keybinding in the running terminal
Emacs both produced:

- Before editing: 10 live overlays, including both bold paragraphs.
- Editor open: 0 live source overlays; 7 deleted objects remain tracked;
  surrounding text still has `fontified=t`.
- Finish without edits: only 3 code-block overlays return; both bold
  paragraphs remain unrendered.
- Calling `jit-lock-fontify-now` again does not restore those paragraphs.

A scoped experiment using `CLONE=nil` preserved both bold paragraphs and left
zero dead entries through finish, abort, and external kill, including edits
inside the fence. This was an experimental override, not a package change.

Relevant code: `lisp/markdown-modern-commands.el`,
`markdown-modern-edit-code-block`; `lisp/markdown-modern.el`,
`markdown-modern--teardown-buffer`; `lisp/markdown-modern-render.el`,
`markdown-modern-render--clear-all`.

### 2. Partial list rendering creates overlays outside its cleared region

`markdown-modern-ts--containing-block-bounds` stops at the nearest block,
which can be a paragraph inside a list item. The region query also returns
an enclosing list. Its renderer visits all immediate list items, including
ones outside the region that was cleared. Those existing overlays are not
removed before replacements are added.

On a fresh copy of README, rendering positions 1..5238 and then repeatedly
rendering 1100..1150 produced duplicate counts of 0, 17, 34, and 51. The
expanded partial region was only 996..1206. The earlier live inspection found
186 duplicates. Full-buffer rendering of simple and nested list samples did
not accumulate duplicates; partial rendering is the relevant trigger.

Relevant code: `lisp/markdown-modern-ts.el`, boundary detection and block
queries; `lisp/markdown-modern-render.el`, region and list renderers;
`lisp/markdown-modern.el`, JIT and reveal callers.

### 3. Deleted overlays remain in the active registry

The 527 dead entries observed in README are consistent with the code-edit
failure, but ordinary edits can also leak entries. Deleting `**bold**` from
a freshly rendered buffer left three evaporated overlays tracked. Passing
one to `markdown-modern-render--release-overlay` still did not remove it:
the registry update is conditional on `overlay-buffer` being non-nil.

This is a bookkeeping and long-session performance problem. A dead registry
entry alone does not prove that currently visible text needs rerendering.

### 4. Window changes do not invalidate table layout

Table strings are sized at render time. The existing resize hook only
adjusts optional reading margins, and is not installed with the normal
reading-width configuration. It never invalidates tables.

In a disposable live terminal buffer, splitting the window changed the
available table width from 371 to 184 columns. After redisplay the same
371-column grid overlay remained, and its text was still `fontified=t`.

The existing margin hook is also global: teardown of one Markdown buffer
removes it for other buffers. Its callback applies margins to every
Markdown window it visits, without checking each buffer's width-management
option. The replacement must avoid these cross-buffer effects.

Relevant code: `lisp/markdown-modern.el`, setup, teardown, and size-change
handling; `lisp/markdown-modern-render.el`, table width calculation.

## Implementation order

### 1. Isolate the code editor and enforce renderer ownership

- Create the code editor with fresh buffer-local state (`CLONE=nil`). Copy
  only required context, such as the source `default-directory`, explicitly.
  Continue sharing the text and running the language's ordinary mode hooks.
- Select a plain text fallback when the language is absent or unavailable,
  so the editor never inherits an active Markdown renderer.
- Make renderer cleanup ownership-aware. A copied list must not authorize
  deleting, moving, or recycling another buffer's overlays. Apply this to
  whole-buffer cleanup and pooling, not just the code-edit command.
- Preserve the existing parser-owner guard. Keep the source's JIT hooks,
  reveal state, unrelated overlays, URL metadata, and window margins intact.
- Keep finish, abort, and external kill on one consistent source-block
  refresh path. Verify that edits through the indirect buffer invalidate
  the appropriate source region and that failed setup cleans up its editor.

Add integration regressions with already-rendered headings, prose, links,
soft breaks, and lists before and after the fence. Assert that unrelated
overlay objects remain live in the source while the editor is open and after
each exit path. Include edits, no edits, an empty fence, unknown/no language,
source-buffer shutdown, and the existing new/reused/same-window cases.
Verify source parsers, text, modified state, and hooks as well as appearance.

### 2. Make clearing, rendering, and JIT bounds describe the same extent

- Introduce a single render-extent calculation that includes complete
  enclosing containers when their renderer draws outside a child block.
  Keep this separate from the smallest-element lookup used for reveal.
- Resolve the extent before clearing. Use it for clearing, block collection,
  rendering, and the returned `jit-lock-bounds` value.
- Route JIT rendering, reveal transitions, and code-edit refresh through
  the same rule. Ensure nested containers are not dispatched twice.
- Cover zero-length table borders at region boundaries and end of buffer.
- Expand only to the required containers, not to a section or document.
  Measure the cost of very large lists before accepting the approach.

Add regressions for repeated partial rendering inside ordinary and nested
lists, blockquotes containing lists, edits at container boundaries, and
cursor reveal transitions. Compare the normalized overlay output against
a clean render with the same reveal state. Overlay counts must stabilize,
neighboring content must retain rendering, and source text must not change.

### 3. Make overlay bookkeeping safe after evaporation

- Remove a released object from the active registry even if Emacs has
  already detached it. Make repeated release idempotent and prevent
  duplicate pool entries.
- Prune evaporated entries during an appropriate edit/render maintenance
  path. Merely fixing release is insufficient because region queries cannot
  return overlays that are already detached.
- Reset all package-owned properties on reuse, including type and help
  metadata. Retain explicit handling for non-evaporating table borders.
- Avoid adding a full-registry scan to every ordinary cursor movement.

Add delete/undo/reinsert and repeated edit/render regressions. Verify that
live tracked overlays belong to the current buffer, the pool contains only
detached objects, neither collection contains duplicate objects, and dead
entries do not accumulate across repeated cycles. Preserve foreign overlays.

### 4. Invalidate table layout when its effective width changes

- Track the effective layout inputs: displaying windows, usable body width,
  margins, fixed-pitch metrics, and text scale. Compare them on window-state
  and relevant scale changes; unchanged inputs must do no rendering work.
- Separate layout invalidation from optional reading-margin management.
  Hooks must have correct buffer/window lifetimes; closing one buffer must
  not disable updates in another. Respect existing user margins.
- Invalidate affected tables for JIT rendering. Tables outside the viewport
  must also become stale, so scrolling back cannot resurrect the old width.
  Use tracked layout state or table extents rather than reparsing the whole
  document on every window event.
- Resolve the existing multiwindow ambiguity explicitly. For the current
  buffer-wide overlay design, use the narrowest live displaying window as
  the automatic width budget. This gives a stable layout that fits every
  window when the configured minimum column widths permit it; a wider
  window may have spare space. Preserve the explicit
  `markdown-modern-table-max-width` behavior and document this policy.
- Handle window appearance/disappearance and frame changes as well as
  resize. Do not depend on which window `get-buffer-window` happens to return.
- Preserve the active editable row, source positions, and paragraph reveal
  state while replacing table layout.

Add resize-down/up, split/delete, hide/redisplay, two-buffer teardown,
different-width windows, margins, explicit width, and text-scale tests.
Assert layout recomputation only when the effective budget changes, with
no duplicate grid borders and no loss of the active editable row.

## Verification and recovery

The existing three `integration/code-edit-*` tests passed during this
investigation even though the new reproducer failed. They check text,
parsers, narrowing, and windows, but not surrounding rendered content.
The new regressions must fail against the current implementation first.

For implementation, run the package load check and `make check-syntax`, then
the parser, rendering, and integration suites. Run `make test` after the
combined lifecycle and rendering changes. Avoid stale `.elc` files and do
not use broad cleanup that removes user artifacts. Compare the rendering
benchmark before/after, including repeated partial rendering in a large list.

Repeat the normal code-edit keys and resize sequence in disposable live
buffers. Test graphical Emacs for font scaling and pixel layout; the present
investigation validated terminal buffer/overlay state, not graphical pixels.
Finally exercise the laptop's actual suspend/resume or terminal reconnect
path. No suspend/resume cycle has been reproduced in this investigation.

Once the fixes are loaded, recover already-damaged buffers with a deliberate
one-time owned-overlay cleanup and JIT invalidation, preserving text, point,
modified state, and user margins. Recompute reveal state and let the viewport
render normally. A blanket periodic or focus-triggered full-buffer rerender
is not needed to fix the demonstrated code-editor ownership failure.

Completion requires preserved surrounding rendering after every editor exit,
stable overlay counts under repeated partial rendering, bounded bookkeeping
under deletion, and correct table reflow after geometry changes. Any remaining
resume-only failure should be investigated separately with event and overlay
ownership evidence rather than inferred from the timing of the symptom.

## Implementation verification

- Package load and `make check-syntax` passed without compilation warnings.
- `make test`: 249 tests passed, including 19 added regressions. The initial
  five regressions were first observed failing against the original code.
- Live terminal `C-c '` retained both surrounding bold paragraphs, with zero
  dead overlays after finishing. Splitting a window reflowed a 371-column
  grid to 184 columns, matching the new available width.
- Open Markdown buffers were explicitly refreshed with text, point, modified
  state, and window margins preserved. Hidden regions remain unfontified
  until requested by JIT rendering.
- With both revisions byte-compiled, the standard viewport benchmark stayed
  around 3 ms from 500 to 25,000 lines (before: 2.75–3.01 ms;
  after: 3.06–3.30 ms). Full-render times remained proportional to document size.
- This environment provides terminal Emacs only; graphical pixel layout and
  an actual laptop suspend/resume cycle remain unverified.
