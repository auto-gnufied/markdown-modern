# AGENTS.md

Guidance for AI agents working in this repository.

## Scope

This repository contains `markdown-modern`, an Emacs Lisp major mode for inline
Markdown rendering and reveal-at-point editing. It is derived from `text-mode`
and is a fork of `mark-graf`. These instructions apply to the entire repository.

The package requires Emacs 30.1 or later with Tree-sitter support. Editing and
rendering require both the `markdown` and `markdown-inline` grammars; there is no
regex parser fallback. Loading the package without grammars must remain possible,
and mode activation must report missing prerequisites with actionable errors.
Opening a buffer must not download grammars automatically.

Agents should also treat the straight.el package checkout directory as available
source context:

```text
~/.emacs.d/straight/repos
```

When investigating dependency behavior, read the relevant installed package or
Emacs built-in source instead of guessing APIs. Do not modify files under
`~/.emacs.d/straight/repos` unless explicitly asked; changes for this package
should normally be made here.

## Repository layout

- `lisp/markdown-modern.el` defines the major mode, customization, faces, and
  rendering lifecycle, and loads the other package modules.
- `lisp/markdown-modern-ts.el` handles Tree-sitter parsing and grammar setup.
- `lisp/markdown-modern-render.el` and `lisp/markdown-modern-elements.el` handle
  visual rendering and reveal-at-point behavior.
- `lisp/markdown-modern-commands.el` implements editing and navigation commands.
- `lisp/markdown-modern-mermaid.el` implements the built-in SVG diagram renderer.
- `lisp/markdown-modern-export.el` implements HTML and optional Pandoc export.
- `test/` contains ERT suites, the `markdown-modern-test.el` runner, and a
  rendering benchmark.
- `Makefile` provides compilation, testing, linting, packaging, and CI targets.
- `scripts/` contains setup, packaging, installation, lint, and screenshot tools.
- `.github/workflows/ci.yml` checks Emacs 30.1 and 31.1 and grammar compatibility.
- `README.md` documents installation, usage, customization, and development.
- `CHANGELOG.md` records release changes; `TODO.md` tracks planned work.
- `images/demo.md` and `images/screenshot.png` provide the README demonstration.
- `recipes/markdown-modern` contains the MELPA recipe.

## Emacs Lisp conventions

- Preserve `lexical-binding: t` in Lisp files.
- Keep library headers, feature names, and footers consistent with their
  filenames. The main feature is `markdown-modern`; the major mode command is
  `markdown-modern-mode`.
- Keep package metadata in `lisp/markdown-modern.el` consistent with supported
  Emacs versions and actual dependencies.
- Prefix package-owned functions and variables with `markdown-modern-`; follow
  each module's existing naming for internal helpers, such as
  `markdown-modern--` and `markdown-modern-ts--`.
- Use `defcustom` with an appropriate type and group for user-facing options.
  Update `README.md` when public behavior, commands, bindings, installation, or
  customization changes.
- Follow the existing style and keep edits surgical. Avoid broad `ignore-errors`
  or silent compatibility fallbacks; failures should remain diagnosable.
- Preserve the reveal-at-point editing model and viewport-driven `jit-lock`
  rendering. Rendering must not change the buffer's source text, and routine
  scrolling or cursor movement should not introduce full-buffer work.
- Keep built-in rendering and HTML export independent of external tools.
  Pandoc export and `tex2svg` math rendering are optional integrations.

## Working with installed packages

- straight.el dependency source, when present, is expected at
  `~/.emacs.d/straight/repos/<package-name>`. Emacs built-ins such as `treesit`
  and `jit-lock` should be traced in the source for the Emacs version in use.
- straight.el build directories under `~/.emacs.d/straight/build` may be added
  to `load-path` when needed, but source checkouts remain the primary reference
  for package APIs. Standard validation here uses `emacs -Q` and this repo's
  `lisp/` and `test/` directories.
- Prefer focused compatibility changes here over modifying installed sources.
  If a dependency source change is explicitly requested, call out that it is
  outside this repository and may be overwritten by package updates unless
  maintained as a fork or patch.
- Keep installation examples consistent with the README's package-vc,
  use-package, release tarball, and manual installation paths. Preserve the
  `lisp/` layout used by packaging and installation scripts.

## Using Emacs mcp server

If available the agent can use emacs MCP server configured via ~/.emacs.d/straight/repos/emacs-mcp-server/ for Emacs-aware operations such as evaluating Elisp, inspecting buffers, and collecting diagnostics. The server is started in Emacs through `mcp-server-start-unix`; the agent-shell config will start it on demand if it is not already running.

## Validation

Use the smallest check that covers the change. Documentation-only edits need
review against the referenced files and commands; they do not require Lisp
compilation or tests. For Lisp changes, at minimum load the package and run
`make check-syntax`, which treats byte-compilation warnings as errors:

```sh
emacs --batch -Q -L lisp -l markdown-modern
make check-syntax
```

Run the relevant ERT suites after code changes. Focused Makefile targets include:

```sh
make test-cmd          # Editing commands
make test-export       # Export
make test-ts           # Parser and setup
make test-integration  # Integration
make test-setup        # Fresh-process loading and errors without grammars
```

For suites without a dedicated target, load the corresponding test file and
select its ERT prefix, for example:

```sh
emacs --batch -Q -L lisp -L test \
  -l markdown-modern -l markdown-modern-render-test \
  --eval '(ert-run-tests-batch-and-exit "^render/")'
```

Parser-dependent tests require both Markdown grammars. Install missing grammars
with `M-x markdown-modern-install-grammars`, or the batch equivalent below;
installation needs network access, Git, and a C compiler:

```sh
emacs --batch -Q -L lisp -l markdown-modern-ts \
  -f markdown-modern-install-grammars
```

Additional checks are available when the change warrants them:

- `make test` runs all eight suites and requires both grammars.
- `make lint` installs package-lint under `.build/` if needed and checks libraries.
- `make test-package` builds, installs, and loads the release tarball in isolation.
- `make ci` runs cleanup, setup, compilation, lint, all tests, and tarball checks.
- `make bench` measures rendering performance; it is not a pass/fail test.

For rendering, reveal-at-point, table layout, mouse interaction, images, or
window-width changes, supplement batch checks with focused interactive testing
in a disposable Markdown buffer. Use graphical Emacs when checking pixel layout
or image display. Report which behavior was tested interactively and which was
covered only by batch checks.

If checks fail because of the local Emacs version, missing grammars, unavailable
optional tools, or network restrictions, report the exact environmental failure
and perform narrower checks where possible. Do not describe skipped tests as
passing. Compilation creates `.elc` files; avoid validating stale compiled code.
`make clean` removes compiled libraries and `dist/`, so preserve any user
artifacts before using cleanup targets.

## Git hygiene

- Do not rewrite history or discard user changes.
- Keep edits focused and avoid reformatting unrelated Emacs Lisp or replacing
  screenshots unless the requested behavior changes them.
- Do not commit changes unless explicitly requested.
