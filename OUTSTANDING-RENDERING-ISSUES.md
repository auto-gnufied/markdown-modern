# Outstanding Rendering Issues

This report documents edge cases and rendering vulnerabilities not covered by the initial implementation in [RENDERING-FIX-PLAN.md](file:///home/hekumar/checkout/markdown-modern/RENDERING-FIX-PLAN.md).

---

## 1. Resume / Reconnect / Multi-Frame Display Transitions

The initial incident occurred after resuming a laptop from sleep. While `C-c '` indirect-buffer overlay destruction was a major bug, several display-transition and daemon/client issues remain unaddressed when a laptop wakes up, re-attaches a monitor, or reconnects an `emacsclient` frame:

### 1.1 Global Display Character Sets Are Not Frame-Local or Updated on New Frames
In [`markdown-modern-render--setup-display-chars`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L140-L167), the variables `markdown-modern-render--bullet-chars`, `markdown-modern-render--checkbox-chars`, `markdown-modern-render--hr-char`, `markdown-modern-render--blockquote-char`, and `markdown-modern-render--newline-mark` are **global** `defvar`s initialized once when [`markdown-modern-render--init`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L130-L138) runs in a buffer.
- If a buffer is opened in a daemon or non-graphical terminal (`(display-graphic-p)` is `nil` or `(char-displayable-p ?●)` is `nil`) and later viewed in a GUI frame (or vice versa after terminal reconnect after sleep), the global variables retain the old frame's capabilities and existing overlays keep their baked-in display strings (`▏` vs `│` vs `|`, `$` vs `↵`).
- Opening a buffer in a TTY frame mutates these globals for all already-open GUI buffers too.

### 1.2 Inline Images & Mermaid SVGs Do Not Invalidate on Monitor DPI / Frame Scaling Changes
When resuming from sleep (especially when docking/undocking an external display or waking a Wayland/X11 compositor), frame pixel scaling or font metrics can change.
- [`markdown-modern--refresh-layout`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern.el#L609-L624) only invalidates tables (`markdown-modern-render--tables`).
- Inline images ([`markdown-modern-render--display-image`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L661-L669)) and Mermaid SVGs ([`markdown-modern-render--mermaid`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L2117-L2160)) are not re-rendered or cleared on frame/display changes.

---

## 2. Partial Rendering & Container Boundary Edge Cases

### 2.1 Indented List Continuation Lines Lose `wrap-prefix` on Partial Renders
In [`markdown-modern-render--list`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L1215-L1227):
```elisp
(when (>= (treesit-node-start child) start)
  (markdown-modern-render--render-element (markdown-modern-ts--make-element child)))
```
And in [`markdown-modern-render--list-item`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L1229-L1324), the `list-content` overlay (which carries `wrap-prefix` for visual-line wrapping) is only applied from `content-start` to `eol` of the **first line** of the `list_item`.
1. **Continuation lines**: When `markdown-modern-join-paragraph-lines` is `nil` (or while a multi-line paragraph inside a list item is unfolded for editing), lines 2..N of the list item do not receive a `list-content` `wrap-prefix` overlay at all.
2. **Enclosing list item skipped**: When `jit-lock` partially re-renders a child block on line 2+ of a list item (`start > (treesit-node-start list_item)`), `markdown-modern-render--list` skips the `list_item` completely because `(treesit-node-start child) < start`.

### 2.2 Blockquotes Nested Inside Lists (`- > quote`) Ignore `list_item` Indentation
In [`markdown-modern-render--blockquote`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L1149-L1160):
```elisp
(when (looking-at "^\\(>+\\)[ \t]?") ...)
```
The regex requires `>` to be at column 0 (`^>+`). When a blockquote is nested inside a list item (e.g. `  > quoted text` or `- > quoted text`), `looking-at` fails to match because of leading spaces or list markers, leaving the blockquote markers completely unrendered.

### 2.3 Multi-Level Lists Inside Blockquotes (`>   - nested`)
In [`markdown-modern-render--blockquote`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L1168-L1190), after matching `^\\(>+\\)[ \t]?`, the renderer checks `(looking-at "\\([-*+]\\)[ \t]+")`.
- Because `[ \t]?` after `>+` consumes at most one space, an indented nested list item inside a blockquote (`>   - nested`) is not matched as a list item by the blockquote renderer.
- Meanwhile, the Tree-sitter `list` / `list_item` query *does* capture the `list_item`, whose own renderer ([`markdown-modern-render--list-item`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L1265)) checks `(looking-at "^\\([ \t]*\\)\\([-*+]\\)[ \t]+")`, which fails because the line starts with `>`. Thus nested lists inside blockquotes get neither bullet overlays nor nested wrap prefixes.

### 2.4 Tables Inside Blockquotes (`> | a | b |`) Are Not Rendered
[`markdown-modern-render--table`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L1677-L1697) scans for rows using `(looking-at "^[ \t]*|.+|[ \t]*$")`. If a pipe table is inside a blockquote (`> | a | b |`), Tree-sitter parses a `pipe_table` node, but `markdown-modern-render--table` fails to match any rows and renders nothing.

---

## 3. Table Layout & Window Management Issues

### 3.1 `markdown-modern-render--table-display-width` Miscomputes Width When Window Margins Are Active
In [`markdown-modern-render--table-display-width`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L1443-L1457):
```elisp
(let* ((char-px (markdown-modern-render--table-char-pixel-width window))
       (cols (floor (/ (window-body-width window t)
                       (max 1 char-px)))))
  (max 20 (- cols (or markdown-modern-left-margin 0) 1)))
```
This works because `window-body-width` excludes window margins. However, in [`markdown-modern-render--table-char-pixel-width`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L1421-L1439):
```elisp
(scale (if (and (boundp 'text-scale-mode-amount)
                (boundp 'text-scale-mode-step)
                (numberp text-scale-mode-amount)
                (not (zerop text-scale-mode-amount)))
           (expt text-scale-mode-step text-scale-mode-amount)
         1))
```
In Emacs 29/30+, `window-font-width` when given a face symbol (`'markdown-modern-table`) **already reflects `face-remapping-alist`** (which `text-scale-mode` uses!). Multiplying `window-font-width` by `(expt text-scale-mode-step text-scale-mode-amount)` in graphical Emacs **double-counts** the text scale factor when `window-font-width` returns the remapped font width, making tables shrink by $1/\text{scale}^2$ on zoom-in.

### 3.2 `markdown-modern--apply-text-width` Does Not Restore Margins When Window Switches Buffers
In [`markdown-modern--apply-text-width`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern.el#L596-L607), window margins are saved in buffer-local `markdown-modern--saved-margins` and modified on the window.
- If the user switches that window to a non-Markdown buffer (e.g. `C-x b *scratch*`) without killing or tearing down the Markdown buffer, the window retains the wide right margin applied by `markdown-modern--apply-text-width`.
- Conversely, if `markdown-modern--teardown-buffer` later runs while the window is showing another buffer, `(eq (window-buffer (car entry)) (current-buffer))` is `nil`, so the margin is never restored even if the user switches back.

### 3.3 `markdown-modern-toggle-table-scroll-view` (`C-c C-v t`) Uses `clear-all` + Synchronous Full-Buffer Render
In [`markdown-modern-toggle-table-scroll-view`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-commands.el#L755-L775):
```elisp
(markdown-modern-render--clear-all)
(markdown-modern-render--render-region (point-min) (point-max))
```
1. It re-renders `(point-min)` to `(point-max)` synchronously instead of invalidating `markdown-modern-render--tables` via `jit-lock-refontify`, freezing Emacs on large files.
2. It does not update `markdown-modern--table-width`, so the next `window-state-change-functions` invocation may unnecessarily re-invalidate or get out of sync.

---

## 4. Overlay & Change-Hook Bookkeeping Edge Cases

### 4.1 Nested or Multiple `before-change-functions` Calls Before `after-change-functions`
In [`markdown-modern-render--before-change`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L208-L211):
```elisp
(defun markdown-modern-render--before-change (start end)
  "Remember overlays in START..END that could evaporate during an edit."
  (when (eq markdown-modern-render--owner (current-buffer))
    (setq markdown-modern-render--changed-overlays (overlays-in start end))))
```
Using `setq` overwrites `markdown-modern-render--changed-overlays` instead of accumulating into it. In Emacs, certain primitives (or `combine-change-calls` / `replace-buffer-contents` / complex C edit operations) can invoke `before-change-functions` multiple times or across sub-regions before `after-change-functions` runs, or an `after-change-functions` hook earlier in the list could trigger another change. Accumulating via `nconc` or `cl-union` avoids dropping overlays captured by an earlier `before-change` call.

### 4.2 Async Remote Image Fetch Callback Bypasses Ownership & Reveal State
In [`markdown-modern-render--fetch-image-async`](file:///home/hekumar/checkout/markdown-modern/lisp/markdown-modern-render.el#L679-L716):
- When the HTTP download completes asynchronously, the callback searches `(overlays-in start end)` for `'image-placeholder` and mutates the overlay in place.
- `start` and `end` are raw integers captured when the request started; if text before the image was edited while the download was in flight, `start` and `end` point to the wrong buffer positions.
- If the buffer switched major modes (`markdown-modern--teardown-buffer`) or the cursor is currently inside the image (revealed), the callback does not check `markdown-modern--rendering-enabled` or `markdown-modern--revealed-region`.
