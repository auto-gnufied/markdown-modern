;;; markdown-modern-jit-test.el --- Tests for jit-lock rendering and reveal -*- lexical-binding: t; no-byte-compile: t; -*-

;; This file is part of markdown-modern.

;;; Commentary:

;; Tests for the jit-lock fontify entry point, block-level region extension,
;; reveal-at-point element detection, the reveal guard, and the mermaid image
;; cache. Both Markdown grammars are required.

;;; Code:

(require 'ert)
(require 'markdown-modern)

(defmacro markdown-modern-jit-test--with-buffer (text &rest body)
  "Insert TEXT in a temp buffer with Markdown parsers and run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (setq-local markdown-modern--rendering-enabled t)
     (markdown-modern-render--init)
     (insert ,text)
     (markdown-modern-ts--init)
     (goto-char (point-min))
     ,@body))

(defun markdown-modern-jit-test--markdown-modern-overlays (start end)
  "Return markdown-modern overlays overlapping START..END."
  (seq-filter (lambda (ov) (overlay-get ov 'markdown-modern))
              (overlays-in start end)))

;;; jit-lock fontify entry

(ert-deftest jit/fontify-returns-bounds-and-renders ()
  "`markdown-modern--jit-fontify' renders overlays and returns a jit-lock-bounds cons."
  (markdown-modern-jit-test--with-buffer "# Heading\n\nSome **bold** text.\n"
    (let ((result (markdown-modern--jit-fontify (point-min) (point-max))))
      (should (eq (car result) 'jit-lock-bounds))
      (should (integerp (cadr result)))
      (should (integerp (cddr result)))
      (should (> (length (markdown-modern-jit-test--markdown-modern-overlays
                          (point-min) (point-max)))
                 0)))))

(ert-deftest jit/fontify-disabled-renders-nothing ()
  "With rendering disabled the fontify function does no work."
  (markdown-modern-jit-test--with-buffer "# Heading\n"
    (setq-local markdown-modern--rendering-enabled nil)
    (should-not (markdown-modern--jit-fontify (point-min) (point-max)))
    (should (= 0 (length (markdown-modern-jit-test--markdown-modern-overlays
                          (point-min) (point-max)))))))

;;; Block-level region extension

(ert-deftest jit/extend-region-covers-fenced-block ()
  "A sub-range inside a fenced code block expands to the whole block."
  (markdown-modern-jit-test--with-buffer
      "before\n\n```python\nline1\nline2\nline3\n```\n\nafter\n"
    (let* ((fence-open (progn (goto-char (point-min))
                              (search-forward "```python")
                              (match-beginning 0)))
           (mid (progn (search-forward "line2") (match-beginning 0)))
           (bounds (markdown-modern--extend-region-to-blocks mid mid)))
      ;; The extended region must include the opening fence and the closing one.
      (should (<= (car bounds) fence-open))
      (should (>= (cdr bounds)
                  (progn (goto-char (point-max))
                         (search-backward "```")
                         (match-end 0)))))))

;;; Reveal-at-point granularity

(ert-deftest jit/markup-element-at-heading ()
  "Point on a heading reveals the whole heading block."
  (markdown-modern-jit-test--with-buffer "# Heading One\n\nbody\n"
    (goto-char 4) ;; inside "Heading"
    (let ((r (markdown-modern--markup-element-at (point))))
      (should r)
      (should (= (car r) 1))
      ;; spans at least through the heading text
      (should (>= (cdr r) 13)))))

(ert-deftest jit/markup-element-at-emphasis ()
  "Point inside emphasis reveals just that inline span, not the paragraph."
  (markdown-modern-jit-test--with-buffer "plain *emph* word\n"
    (let ((star (progn (goto-char (point-min)) (search-forward "*emph") (match-beginning 0))))
      (goto-char (1+ star)) ;; inside the emphasis run
      (let ((r (markdown-modern--markup-element-at (point))))
        (should r)
        ;; The span is the emphasis element, much smaller than the whole line.
        (should (< (- (cdr r) (car r)) 10))
        (should (<= (car r) star))))))

(ert-deftest jit/markup-element-at-plain-prose-is-nil ()
  "Point in plain prose reveals nothing."
  (markdown-modern-jit-test--with-buffer "just some plain words here\n"
    (goto-char 6)
    (should-not (markdown-modern--markup-element-at (point)))))

;;; Reveal keeps styling

(ert-deftest jit/reveal-shows-markup-but-keeps-styling ()
  "Revealing an element shows its raw markers but preserves its face.
After reveal there must be no marker-hiding (display) overlays in the span,
but the styling face overlay (bold) must remain."
  (markdown-modern-jit-test--with-buffer "text **bold** end\n"
    (let* ((pos (progn (goto-char (point-min)) (search-forward "bold") (match-beginning 0)))
           (region (markdown-modern--markup-element-at pos)))
      (should region)
      (setq markdown-modern--revealed-region region)
      ;; Re-render the whole buffer the way jit-lock would on scroll; the
      ;; reveal guard should re-reveal markup while keeping faces.
      (markdown-modern--jit-fontify (point-min) (point-max))
      (let ((display-ovs 0) (face-ovs 0))
        (dolist (ov (markdown-modern-jit-test--markdown-modern-overlays (car region) (cdr region)))
          (when (overlay-get ov 'display) (setq display-ovs (1+ display-ovs)))
          (when (and (overlay-get ov 'face) (not (overlay-get ov 'display)))
            (setq face-ovs (1+ face-ovs))))
        ;; Markers are visible (no display overlays hide them) ...
        (should (= display-ovs 0))
        ;; ... but the bold styling is preserved.
        (should (> face-ovs 0))))))

;;; Mermaid image cache idempotency

(ert-deftest jit/mermaid-image-is-cached ()
  "Rendering the same SVG twice reuses the cached image object."
  (markdown-modern-jit-test--with-buffer "xxxxx\n"
    (let ((svg "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
          (image-calls 0)
          img1 img2)
      ;; Check caching even on builds without image support.
      (cl-letf (((symbol-function 'create-image)
                 (lambda (&rest args)
                   (cl-incf image-calls)
                   (cons 'image args))))
        (markdown-modern-render--display-mermaid-svg 1 2 svg "k")
        (setq img1 (overlay-get (car (markdown-modern-jit-test--markdown-modern-overlays 1 2)) 'display))
        (markdown-modern-render--display-mermaid-svg 1 2 svg "k")
        (setq img2 (overlay-get (car (markdown-modern-jit-test--markdown-modern-overlays 1 2)) 'display))
        (should img1)
        (should (eq img1 img2))
        (should (= image-calls 1))))))

;;; Inline markup inside headings (tree-sitter path)

(ert-deftest jit/heading-renders-inline-code-span ()
  "Inline code spans inside a heading are rendered (backticks hidden).
The heading renderer must descend into its own inline markup."
  (with-temp-buffer
    (setq-local markdown-modern--rendering-enabled t)
    (markdown-modern-render--init)
    (insert "## A `code` and `more` heading\n")
    (markdown-modern-ts--init)
    (markdown-modern--jit-fontify (point-min) (point-max))
    (let ((delims 0) (contents 0))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (pcase (overlay-get ov 'markdown-modern-type)
          ('code-delim (setq delims (1+ delims)))
          ('code-content (setq contents (1+ contents)))))
      ;; Two spans: 4 hidden delimiter overlays, 2 styled content overlays.
      (should (= delims 4))
      (should (= contents 2)))))

;;; Mouse wheel scrolling

(ert-deftest jit/wheel-optional-amount ()
  (let (calls)
    (cl-letf (((symbol-function 'scroll-up)
               (lambda (&optional amount) (push (list 'up amount) calls)))
              ((symbol-function 'scroll-down)
               (lambda (&optional amount) (push (list 'down amount) calls))))
      (markdown-modern--wheel-up)
      (markdown-modern--wheel-down)
      (should (equal (nreverse calls) '((up nil) (down nil)))))))

(ert-deftest jit/wheel-bounded-retry ()
  (dolist (amount '(nil 0 1 -1 2 -2 100))
    (let (calls)
      (markdown-modern--wheel-scroll
       (lambda (n) (push n calls)) amount)
      (should (equal (nreverse calls)
                     (if (memq amount '(1 -1))
                         (list amount (* 2 amount)) (list amount)))))))

(ert-deftest jit/wheel-no-retry-after-progress ()
  (dolist (pixel-progress '(nil t))
    (let ((start 1) (pixels 0) calls)
      (cl-letf (((symbol-function 'window-start) (lambda (&rest _) start))
                ((symbol-function 'window-vscroll) (lambda (&rest _) pixels)))
        (markdown-modern--wheel-scroll
         (lambda (n)
           (push n calls)
           (if pixel-progress (setq pixels 1) (setq start 2))) 1)
        (should (equal calls '(1)))))))

(ert-deftest jit/wheel-boundary-signals ()
  (dolist (boundary '(beginning-of-buffer end-of-buffer))
    (let ((calls 0))
      (should-error
       (markdown-modern--wheel-scroll
        (lambda (_) (setq calls (1+ calls)) (signal boundary nil)) 1)
       :type boundary)
      (should (= calls 1)))))

(ert-deftest jit/wheel-real-wheel-boundaries ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *wheel-boundary-regression*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (dotimes (n 200) (insert (format "Line %d\n" n)))
            (set-buffer-modified-p nil)
            (markdown-modern-mode)
            (let ((mouse-wheel-follow-mouse nil)
                  (mouse-wheel-progressive-speed nil)
                  (mouse-wheel-scroll-amount '(1))
                  (mouse-wheel-inhibit-click-time nil))
              (dolist (direction '(wheel-up wheel-down))
                (goto-char (if (eq direction 'wheel-up) (point-min) (point-max)))
                (recenter)
                (redisplay t)
                ;; Exercise mwheel's zero-argument boundary recovery, repeatedly.
                (dotimes (_ 10)
                  (mwheel-scroll (list direction (posn-at-point)))
                  (redisplay t))))
            (should-not (buffer-modified-p)))
        (kill-buffer buffer)))))

(ert-deftest jit/wheel-rendered-row ()
  (skip-unless (display-graphic-p))
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *wheel-rendered-row-regression*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "| table row |\n")
            (dotimes (n 100) (insert (format "Line %d\n" n)))
            (set-buffer-modified-p nil)
            (let ((overlay (make-overlay (point-min)
                                         (save-excursion (goto-char (point-min))
                                                         (line-end-position)))))
              (overlay-put overlay 'display "| wrapped table |\n| second line   |"))
            (goto-char (point-min))
            (set-window-start nil (point-min))
            (redisplay t)
            (let ((start (window-start)))
              (scroll-up 1)
              (redisplay t)
              (goto-char (point-min))
              (set-window-start nil start)
              (redisplay t)
              (markdown-modern--wheel-up 1)
              (redisplay t)
              (should (> (window-start) start)))
            (should-not (buffer-modified-p)))
        (kill-buffer buffer)))))

(ert-deftest jit/wheel-preserve-screen-position-scoped ()
  (let ((scroll-preserve-screen-position nil) seen)
    (markdown-modern--wheel-scroll
     (lambda (_) (setq seen scroll-preserve-screen-position)) nil)
    (should (eq seen 'always))
    (should-not scroll-preserve-screen-position)))

(ert-deftest jit/wheel-mode-lifecycle ()
  "Mode activation installs local callbacks and teardown releases them."
  (with-temp-buffer
    (insert "# Heading\n\nText.\n")
    (markdown-modern-mode)
    (should (local-variable-p 'mwheel-scroll-up-function))
    (should (eq mwheel-scroll-up-function #'markdown-modern--wheel-up))
    (should (eq mwheel-scroll-down-function #'markdown-modern--wheel-down))
    (markdown-modern--teardown-buffer)
    (should-not (local-variable-p 'mwheel-scroll-up-function))
    (should-not (local-variable-p 'mwheel-scroll-down-function))))

(ert-deftest jit/wheel-teardown-preserves-user-override ()
  "Cleanup does not discard a callback changed after activation."
  (with-temp-buffer
    (markdown-modern-mode)
    (setq-local mwheel-scroll-down-function #'ignore)
    (markdown-modern--teardown-buffer)
    (should (local-variable-p 'mwheel-scroll-down-function))
    (should (eq mwheel-scroll-down-function #'ignore))))

(provide 'markdown-modern-jit-test)
;;; markdown-modern-jit-test.el ends here
