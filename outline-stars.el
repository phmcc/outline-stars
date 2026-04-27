;;; outline-stars.el --- Outshine-style star headings for outline-minor-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Hsin-ti McClelland

;; Author: Paul Hsin-ti McClelland <PaulHMcClelland@protonmail.com>
;; Version: 0.4.3
;; Package-Requires: ((emacs "29.1"))
;; URL: https://codeberg.org/phmcc/outline-stars
;; Keywords: outlines, convenience

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `outline-stars' provides `outshine'-convention star headings (;; * , ;; ** ,
;; ## * , etc.) using the built-in `outline-minor-mode'.  It is a lightweight,
;; modern replacement for `outshine' that attempts to solve the same problems
;; in fewer lines on a stable core.
;;
;; Features:
;;   - Comment-aware heading detection using `comment-start' and `comment-add'
;;   - Per-level fontification via `outline-stars-level-N' faces
;;   - Optional overline on heading lines (top-level only, or all levels)
;;   - `imenu' integration for heading navigation
;;   - Subtree promote/demote that optionally updates all child headings
;;   - Global visibility cycling (folded → content → show-all)
;;   - Startup visibility state (folded, content, show-all) per-buffer or per-mode
;;   - Alphabetical sorting of sibling headings
;;   - Section numbering (0, 0.1, ... or 1, 1.1, ...) with insert/strip/auto
;;   - Scoped numbering: whole buffer, current subtree, or active region
;;   - Automatic TAB cycling on headings via `outline-minor-mode-cycle'
;;   - Installs an `outline-regexp'-driven `outline-search-function' (Emacs 29+)
;;   - Runs on `after-change-major-mode-hook' to override mode-specific defaults
;;
;; Usage:
;;   (require 'outline-stars)
;;   (outline-stars-mode 1)
;;
;; Or with use-package:
;;   (use-package outline-stars
;;     :config (outline-stars-mode 1))
;;
;; Set `outline-stars-section-comments' to nil for classic outshine
;; behavior (;; *, ## *, # *, // *).

;;; Code:

;;; * 0 Prerequisites

(require 'outline)
(require 'cl-lib)

;;; * 1 Foundation

;;; ** 1.1 Customization

(defgroup outline-stars nil
  "Outshine-style star headings for `outline-minor-mode'."
  :group 'outline
  :prefix "outline-stars-")

(defcustom outline-stars-max-level 8
  "Maximum heading depth for star-based headings."
  :type 'integer
  :group 'outline-stars)

(defcustom outline-stars-modes '(prog-mode)
  "Major modes where outline-stars should activate.
Checked with `derived-mode-p', so `prog-mode' covers all
programming modes."
  :type '(repeat symbol)
  :group 'outline-stars)

(defcustom outline-stars-promote-subtree-p t
  "Whether promote/demote operates on the entire subtree.
When nil, only the current heading is changed."
  :type 'boolean
  :group 'outline-stars)

(defcustom outline-stars-section-comments t
  "Whether to use section-level comments for heading prefixes.
When non-nil, one extra comment character is added for modes with
single-character comment starters (;; → ;;;, ## → ###).  Modes
with multi-character starters (// in C) are unaffected.
When nil, uses the classic outshine convention (;; *, ## *, # *)."
  :type 'boolean
  :group 'outline-stars)

(defcustom outline-stars-overline nil
  "Whether to add an overline to heading lines.
nil draws no overline.  `level-1' draws only on top-level
headings.  t draws on all levels, each in its face color.
Color is resolved at setup time; re-run `outline-stars-setup'
after theme changes."
  :type '(choice (const :tag "No overline" nil)
                 (const :tag "Top-level only" level-1)
                 (const :tag "All levels" t))
  :group 'outline-stars)

(defcustom outline-stars-default-state nil
  "Initial visibility when outline-stars activates in a buffer.
nil leaves the buffer as-is.  `folded' shows only top-level
headings.  `content' shows all headings with body hidden.
`show-all' shows everything.  Overridable per-mode via
`outline-stars-default-state-alist' or per-file via local variables."
  :type '(choice (const :tag "No action" nil)
                 (const :tag "Folded (top-level only)" folded)
                 (const :tag "Content (all headings)" content)
                 (const :tag "Show all" show-all))
  :group 'outline-stars)
;;;###autoload(put 'outline-stars-default-state 'safe-local-variable
;;;###autoload  (lambda (v) (memq v '(nil folded content show-all))))

(defcustom outline-stars-default-state-alist nil
  "Per-mode overrides for `outline-stars-default-state'.
An alist of (MODE . STATE) pairs checked with `derived-mode-p'.
The first match wins."
  :type '(alist :key-type symbol :value-type
                (choice (const nil) (const folded)
                        (const content) (const show-all)))
  :group 'outline-stars)

(defcustom outline-stars-number-start 1
  "Starting number for section numbering (0 or 1)."
  :type '(choice (const :tag "Zero-based (0, 0.1, ...)" 0)
                 (const :tag "One-based (1, 1.1, ...)" 1))
  :group 'outline-stars)

(defcustom outline-stars-auto-number t
  "Whether to automatically insert section numbers on heading insertion.
When non-nil, promote/demote also renumber the parent subtree."
  :type 'boolean
  :group 'outline-stars)

;;; ** 1.2 Faces

(defgroup outline-stars-faces nil
  "Faces for outline star headings."
  :group 'outline-stars
  :group 'faces)

(defface outline-stars-level-1 '((t :inherit outline-1))
  "Face for level 1 headings." :group 'outline-stars-faces)
(defface outline-stars-level-2 '((t :inherit outline-2))
  "Face for level 2 headings." :group 'outline-stars-faces)
(defface outline-stars-level-3 '((t :inherit outline-3))
  "Face for level 3 headings." :group 'outline-stars-faces)
(defface outline-stars-level-4 '((t :inherit outline-4))
  "Face for level 4 headings." :group 'outline-stars-faces)
(defface outline-stars-level-5 '((t :inherit outline-5))
  "Face for level 5 headings." :group 'outline-stars-faces)
(defface outline-stars-level-6 '((t :inherit outline-6))
  "Face for level 6 headings." :group 'outline-stars-faces)
(defface outline-stars-level-7 '((t :inherit outline-7))
  "Face for level 7 headings." :group 'outline-stars-faces)
(defface outline-stars-level-8 '((t :inherit outline-8))
  "Face for level 8 headings." :group 'outline-stars-faces)

;;; ** 1.3 Internal Variables

(defvar-local outline-stars--font-lock-keywords nil
  "Font-lock keywords added by outline-stars in this buffer.")

(defvar-local outline-stars--cycle-state 'show-all
  "Current state of global visibility cycling.")

(defvar-local outline-stars--active nil
  "Non-nil if outline-stars is active in this buffer.")

(defconst outline-stars--number-regexp
  "\\([0-9]+\\(?:\\.[0-9]+\\)*\\) "
  "Regexp matching a section number followed by a space.
Used both by the section-numbering machinery and by subtree
promote/demote when reading a parent heading's number.")

;;; * 2 Comment Prefix

(defun outline-stars--comment-prefix ()
  "Return the comment prefix for star headings.
Derives from `comment-start' and the variable `comment-add'.
Appends one extra character when `outline-stars-section-comments'
is non-nil and `comment-start' is a single character."
  (when comment-start
    (let* ((cs (string-trim comment-start))
           (result (if (or (not comment-add) (zerop comment-add))
                       cs
                     (let ((acc cs))
                       (dotimes (_ comment-add)
                         (setq acc (concat acc cs)))
                       acc))))
      (when (and outline-stars-section-comments
                 (= (length cs) 1))
        (setq result (concat result cs)))
      result)))

;;; * 3 Buffer Setup

;;; ** 3.1 Heading Alist

(defun outline-stars--build-heading-alist (prefix)
  "Build `outline-heading-alist' for PREFIX."
  (let (alist)
    (cl-loop for level from outline-stars-max-level downto 1
             do (push (cons (concat prefix " " (make-string level ?*) " ")
                            level)
                      alist))
    alist))

(defun outline-stars--level ()
  "Return the heading level for the current match."
  (or (cdr (assoc (match-string 0) outline-heading-alist))
      (length (replace-regexp-in-string
               "[^*]" ""
               (match-string-no-properties 0)))))

;;; ** 3.2 Search Function

(defun outline-stars--search-function (&optional bound move backward looking-at)
  "Generic `outline-search-function' driven by `outline-regexp'.
See the docstring of `outline-search-function' for the meaning of
BOUND, MOVE, BACKWARD, and LOOKING-AT.  This is a local
reimplementation of the helper being proposed for upstream
inclusion as `outline-search-from-regexp'; once that lands in a
future Emacs, this function can be replaced with a direct use of
the core helper and the minimum-version requirement bumped."
  (if looking-at
      (looking-at outline-regexp)
    (funcall (if backward #'re-search-backward #'re-search-forward)
             (concat "^\\(?:" outline-regexp "\\)")
             bound
             (if move 'move t))))

;;; ** 3.3 Activation

(defun outline-stars-setup ()
  "Set up `outline-minor-mode' with star headings in the current buffer."
  (when-let* ((prefix (outline-stars--comment-prefix)))
    (let* ((qprefix (regexp-quote prefix))
           (star-re (format "[*]\\{1,%d\\}" outline-stars-max-level))
           (out-regexp (concat qprefix " " star-re " ")))
      (outline-minor-mode 1)
      (setq-local outline-search-function #'outline-stars--search-function)
      (setq-local outline-regexp out-regexp)
      (setq-local outline-heading-alist
                  (outline-stars--build-heading-alist prefix))
      (setq-local outline-level #'outline-stars--level)
      (setq-local outline-minor-mode-cycle t)
      (setq-local outline-stars--active t)
      ;; Imenu
      (let ((heading-entry
             `("Headings" ,(concat "^" qprefix " " star-re " \\(.*\\)$") 1)))
        (if imenu-generic-expression
            (add-to-list 'imenu-generic-expression heading-entry)
          (setq-local imenu-generic-expression (list heading-entry))))
      ;; Fontification
      (outline-stars--add-font-lock qprefix)
      ;; Default visibility
      (outline-stars--apply-default-state)
      (add-hook 'hack-local-variables-hook
                #'outline-stars--apply-default-state nil t))))

;;; ** 3.4 Fontification

(defun outline-stars--add-font-lock (qprefix)
  "Add font-lock keywords for star headings using QPREFIX."
  (let ((keywords
         (cl-loop for level from 1 to outline-stars-max-level
                  for face = (intern (format "outline-stars-level-%d" level))
                  for re = (format "^%s %s \\(.*\\)"
                                   qprefix
                                   (format "[*]\\{%d\\}" level))
                  collect `(,re (1 ',face t))
                  when (or (eq outline-stars-overline t)
                           (and (eq outline-stars-overline 'level-1)
                                (= level 1)))
                  collect `(,re (0 '(:overline ,(face-foreground
                                                  face nil t))
                                append)))))
    (setq outline-stars--font-lock-keywords keywords)
    (font-lock-add-keywords nil keywords)
    (when font-lock-mode
      (font-lock-flush))))

;;; ** 3.5 Default Visibility State

(defun outline-stars--resolve-default-state ()
  "Return the effective default state for the current buffer.
Priority: file-local variable > per-mode alist > global default."
  (if (local-variable-p 'outline-stars-default-state)
      outline-stars-default-state
    (or (cl-loop for (mode . state) in outline-stars-default-state-alist
                 when (derived-mode-p mode) return state)
        outline-stars-default-state)))

(defun outline-stars--apply-default-state ()
  "Apply the resolved default visibility state to the current buffer."
  (when outline-stars--active
    (pcase (outline-stars--resolve-default-state)
      ('folded  (outline-hide-sublevels 1))
      ('content (outline-show-all)
                (outline-hide-region-body (point-min) (point-max)))
      ('show-all (outline-show-all))
      (_ nil))))

;;; ** 3.6 Deactivation

(defun outline-stars-teardown ()
  "Remove font-lock keywords and deactivate `outline-minor-mode'."
  (when outline-stars--font-lock-keywords
    (font-lock-remove-keywords nil outline-stars--font-lock-keywords)
    (setq outline-stars--font-lock-keywords nil)
    (when font-lock-mode
      (font-lock-flush)))
  (setq outline-stars--active nil)
  (remove-hook 'hack-local-variables-hook
               #'outline-stars--apply-default-state t)
  (when outline-minor-mode
    (outline-minor-mode -1)))

;;; * 4 Global Minor Mode

(defun outline-stars--maybe-setup ()
  "Activate outline-stars if the current mode is in `outline-stars-modes'."
  (when (apply #'derived-mode-p outline-stars-modes)
    (outline-stars-setup)))

(defun outline-stars--maybe-teardown ()
  "Deactivate outline-stars if it was set up in this buffer."
  (when outline-stars--active
    (outline-stars-teardown)))

;;;###autoload
(define-minor-mode outline-stars-mode
  "Global minor mode for outshine-style star headings."
  :global t
  :group 'outline-stars
  (if outline-stars-mode
      (add-hook 'after-change-major-mode-hook #'outline-stars--maybe-setup)
    (remove-hook 'after-change-major-mode-hook #'outline-stars--maybe-setup)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (outline-stars--maybe-teardown)))))

;;; * 5 Structure Editing

;;; ** 5.1 Narrowing

;;;###autoload
(defun outline-stars-narrow-to-subtree ()
  "Narrow to the current subtree, moving to the heading first if needed."
  (interactive)
  (unless (outline-on-heading-p t)
    (outline-back-to-heading t))
  (let ((beg (point)))
    (outline-end-of-subtree)
    (narrow-to-region beg (point))))

;;; ** 5.2 Insert Heading

;;;###autoload
(defun outline-stars-insert-heading ()
  "Insert a new heading at the current level.
Auto-numbers when `outline-stars-auto-number' is non-nil.
Determines the spacing convention from the nearest heading (how
many blank lines precede it), then inserts the new heading with
that same spacing above and below, normalizing whatever
whitespace currently exists around point."
  (interactive)
  (let* ((prefix (outline-stars--comment-prefix))
         (on-heading (outline-on-heading-p t))
         (level (save-excursion
                  (condition-case nil
                      (progn
                        (unless on-heading
                          (outline-back-to-heading t))
                        (funcall outline-level))
                    (error 1))))
         (number-str (when outline-stars-auto-number
                       (outline-stars--next-number)))
         (heading-text (concat prefix " " (make-string level ?*) " "
                               (or number-str "")
                               (if number-str " " "")))
         ;; Style: count blank lines before the nearest heading
         (style
          (save-excursion
            (condition-case nil
                (progn
                  (outline-back-to-heading t)
                  (let ((count 0))
                    (while (and (not (bobp))
                                (progn (forward-line -1)
                                       (looking-at-p "^[[:blank:]]*$")))
                      (setq count (1+ count)))
                    count))
              (error 0))))
         (on-blank (save-excursion
                     (forward-line 0)
                     (looking-at-p "^[[:blank:]]*$"))))
    (cond
     ;; On a heading: insert after it with style spacing
     (on-heading
      (end-of-line)
      (insert (make-string (1+ style) ?\n) heading-text))
     ;; On a blank line: replace the surrounding blank-line gap with
     ;; a properly spaced heading
     (on-blank
      (let ((gap-start (save-excursion
                         (forward-line 0)
                         (while (and (not (bobp))
                                     (looking-at-p "^[[:blank:]]*$"))
                           (forward-line -1))
                         (if (looking-at-p "^[[:blank:]]*$")
                             (point)
                           (line-beginning-position 2))))
            (gap-end (save-excursion
                       (forward-line 0)
                       (while (and (not (eobp))
                                   (looking-at-p "^[[:blank:]]*$"))
                         (forward-line 1))
                       (point))))
        (delete-region gap-start gap-end)
        (goto-char gap-start)
        (unless (bobp)
          (insert (make-string style ?\n)))
        (insert heading-text)
        (unless (eobp)
          (save-excursion
            (insert (make-string (1+ style) ?\n))))))
     ;; On a non-blank body line: insert after it with style spacing
     (t
      (end-of-line)
      (insert (make-string (1+ style) ?\n) heading-text)))))

;;; ** 5.3 Promote/Demote

;;;###autoload
(defun outline-stars-promote ()
  "Promote heading (or subtree if `outline-stars-promote-subtree-p')."
  (interactive)
  (if outline-stars-promote-subtree-p
      (outline-stars-promote-subtree)
    (outline-stars--promote-single)
    (when outline-stars-auto-number
      (outline-stars--renumber-parent-subtree)
      (outline-back-to-heading t)
      (end-of-line))))

;;;###autoload
(defun outline-stars-demote ()
  "Demote heading (or subtree if `outline-stars-promote-subtree-p')."
  (interactive)
  (if outline-stars-promote-subtree-p
      (outline-stars-demote-subtree)
    (outline-stars--demote-single)
    (when outline-stars-auto-number
      (outline-stars--renumber-parent-subtree)
      (outline-back-to-heading t)
      (end-of-line))))

(defun outline-stars--promote-single ()
  "Promote only the current heading by one star."
  (save-excursion
    (outline-back-to-heading t)
    (when (looking-at outline-regexp)
      (let ((level (funcall outline-level)))
        (when (> level 1)
          (re-search-forward "[*]+" (line-end-position))
          (replace-match (make-string (1- level) ?*)))))))

(defun outline-stars--demote-single ()
  "Demote only the current heading by one star."
  (save-excursion
    (outline-back-to-heading t)
    (when (looking-at outline-regexp)
      (let ((level (funcall outline-level)))
        (when (< level outline-stars-max-level)
          (re-search-forward "[*]+" (line-end-position))
          (replace-match (make-string (1+ level) ?*)))))))

;;; ** 5.4 Subtree Promote/Demote

;;;###autoload
(defun outline-stars-promote-subtree ()
  "Promote the current heading and all children by one level."
  (interactive)
  (save-excursion
    (outline-back-to-heading t)
    (let ((level (funcall outline-level)))
      (when (> level 1)
        (let ((beg (point))
              (end (save-excursion (outline-end-of-subtree) (point))))
          (save-restriction
            (narrow-to-region beg end)
            (goto-char (point-min))
            (while (not (eobp))
              (when (looking-at outline-regexp)
                (let ((cur-level (funcall outline-level)))
                  (when (> cur-level 1)
                    (re-search-forward "[*]+" (line-end-position) t)
                    (replace-match (make-string (1- cur-level) ?*)))))
              (forward-line 1)))))))
  (when outline-stars-auto-number
    (outline-stars--renumber-parent-subtree)
    (outline-back-to-heading t)
    (end-of-line)))

;;;###autoload
(defun outline-stars-demote-subtree ()
  "Demote the current heading and all children by one level."
  (interactive)
  (save-excursion
    (outline-back-to-heading t)
    (let ((beg (point))
          (end (save-excursion (outline-end-of-subtree) (point)))
          (can-demote t))
      (save-excursion
        (save-restriction
          (narrow-to-region beg end)
          (goto-char (point-min))
          (while (and can-demote (not (eobp)))
            (when (looking-at outline-regexp)
              (when (>= (funcall outline-level) outline-stars-max-level)
                (setq can-demote nil)))
            (forward-line 1))))
      (when can-demote
        (save-restriction
          (narrow-to-region beg end)
          (goto-char (point-min))
          (while (not (eobp))
            (when (looking-at outline-regexp)
              (let ((cur-level (funcall outline-level)))
                (re-search-forward "[*]+" (line-end-position) t)
                (replace-match (make-string (1+ cur-level) ?*))))
            (forward-line 1))))))
  (when outline-stars-auto-number
    (outline-stars--renumber-parent-subtree)
    (outline-back-to-heading t)
    (end-of-line)))

(defun outline-stars--renumber-parent-subtree ()
  "Renumber the subtree of the current heading's parent.
If no parent exists, renumber the whole buffer."
  (save-excursion
    (when (outline-on-heading-p t)
      (outline-back-to-heading t))
    (let* ((current-level (funcall outline-level))
           (parent-pos nil))
      (save-excursion
        (while (and (not parent-pos)
                    (not (bobp))
                    (condition-case nil
                        (progn (outline-previous-heading) t)
                      (error nil)))
          (when (and (outline-on-heading-p t)
                     (looking-at outline-regexp)
                     (< (funcall outline-level) current-level))
            (setq parent-pos (point)))))
      (if (not parent-pos)
          (outline-stars-number-headings)
        (goto-char parent-pos)
        (looking-at outline-regexp)
        (let* ((parent-level (funcall outline-level))
               (parent-counters
                (when (save-excursion
                        (goto-char (match-end 0))
                        (looking-at outline-stars--number-regexp))
                  (mapcar #'string-to-number
                          (split-string (match-string-no-properties 1) "\\."))))
               (implied-ancestors (max 0 (- current-level parent-level 1)))
               (initial-counters
                (when parent-counters
                  (append parent-counters
                          (make-list implied-ancestors
                                     outline-stars-number-start))))
               (beg (save-excursion (forward-line 1) (point)))
               (end (save-excursion (outline-end-of-subtree) (point))))
          (outline-stars--number-in-region beg end nil initial-counters))))))

;;; * 6 Visibility Cycling

;;;###autoload
(defun outline-stars-cycle-buffer ()
  "Cycle global visibility: folded → content → show all → folded."
  (interactive)
  (pcase outline-stars--cycle-state
    ('show-all
     (outline-hide-sublevels 1)
     (setq outline-stars--cycle-state 'folded)
     (message "Folded"))
    ('folded
     (outline-show-all)
     (outline-hide-region-body (point-min) (point-max))
     (setq outline-stars--cycle-state 'content)
     (message "Content"))
    ('content
     (outline-show-all)
     (setq outline-stars--cycle-state 'show-all)
     (message "Show all"))))

;;; * 7 Sorting

;;;###autoload
(defun outline-stars-sort-siblings (&optional reverse-p)
  "Sort sibling headings alphabetically under the current parent.
With prefix argument REVERSE-P, sort in reverse order."
  (interactive "P")
  (save-excursion
    (condition-case nil
        (outline-up-heading 1 t)
      (error (goto-char (point-min))))
    (let* ((parent-level (if (outline-on-heading-p t)
                             (funcall outline-level)
                           0))
           (child-level (1+ parent-level))
           siblings)
      (save-excursion
        (when (outline-on-heading-p t)
          (outline-end-of-heading))
        (while (not (eobp))
          (outline-next-heading)
          (when (and (outline-on-heading-p t)
                     (= (funcall outline-level) child-level))
            (let ((beg (line-beginning-position))
                  (title (save-excursion
                           (looking-at outline-regexp)
                           (buffer-substring-no-properties
                            (match-end 0) (line-end-position))))
                  (end (save-excursion
                         (outline-end-of-subtree)
                         (if (and (not (eobp)) (bolp))
                             (point)
                           (progn (forward-line 1) (point))))))
              (push (list title beg end) siblings)))))
      (when (>= (length siblings) 2)
        (setq siblings (nreverse siblings))
        (let* ((sorted (sort (copy-sequence siblings)
                             (lambda (a b)
                               (if reverse-p
                                   (string> (car a) (car b))
                                 (string< (car a) (car b))))))
               (sorted-texts (mapcar (lambda (s)
                                       (buffer-substring (nth 1 s) (nth 2 s)))
                                     sorted)))
          (unless (equal (mapcar #'car siblings) (mapcar #'car sorted))
            (let ((pairs (cl-mapcar #'cons
                                    (reverse siblings)
                                    (reverse sorted-texts))))
              (dolist (pair pairs)
                (let ((orig (car pair))
                      (new-text (cdr pair)))
                  (delete-region (nth 1 orig) (nth 2 orig))
                  (goto-char (nth 1 orig))
                  (insert new-text)))))))))
  (when outline-stars-auto-number
    (outline-stars-number-headings)))

;;; * 8 Section Numbering

;; The shared regexp `outline-stars--number-regexp' is defined in
;; section 1.3 (Internal Variables) so it is available to both this
;; section and the subtree-promote machinery in section 5.4.

(defun outline-stars--next-number ()
  "Return the next section number by incrementing the current heading's.
Returns nil if the current heading has no number or no heading exists."
  (condition-case nil
      (save-excursion
        (outline-back-to-heading t)
        (when (and (looking-at outline-regexp)
                   (save-excursion
                     (goto-char (match-end 0))
                     (looking-at outline-stars--number-regexp)))
          (let* ((num-str (match-string-no-properties 1))
                 (parts (mapcar #'string-to-number
                                (split-string num-str "\\.")))
                 (incremented (append (butlast parts)
                                      (list (1+ (car (last parts)))))))
            (mapconcat #'number-to-string incremented "."))))
    (error nil)))

(defun outline-stars--strip-numbers-in-region (beg end)
  "Remove section numbers from headings between BEG and END."
  (save-excursion
    (goto-char beg)
    (while (< (point) end)
      (when (and (outline-on-heading-p t)
                 (looking-at outline-regexp))
        (goto-char (match-end 0))
        (when (looking-at outline-stars--number-regexp)
          (delete-region (match-beginning 0) (match-end 0))))
      (forward-line 1))))

(defun outline-stars--number-in-region (beg end &optional base-level initial-counters)
  "Insert section numbers on headings between BEG and END.
BASE-LEVEL is the level just above the top of the numbering
hierarchy (default 0, so level 1 is top).  INITIAL-COUNTERS
seeds the counter array for inheriting from preceding headings.
Strips existing numbers first.  Uses a marker for END so
boundary tracking survives text changes."
  (let ((end-marker (copy-marker end)))
    (unwind-protect
        (progn
          (outline-stars--strip-numbers-in-region beg end-marker)
          (let ((base (or base-level 0)))
            (save-excursion
              (goto-char beg)
              (let ((counters (make-vector (1+ outline-stars-max-level)
                                           (1- outline-stars-number-start))))
                (when initial-counters
                  (cl-loop for val in initial-counters
                           for i from 1
                           do (aset counters i val)))
                (while (< (point) end-marker)
                  (when (and (outline-on-heading-p t)
                             (looking-at outline-regexp))
                    (let* ((level (funcall outline-level))
                           (rel-level (- level base))
                           (match-end-pos (match-end 0)))
                      (when (> rel-level 0)
                        (aset counters rel-level (1+ (aref counters rel-level)))
                        (cl-loop for i from (1+ rel-level) to outline-stars-max-level
                                 do (aset counters i (1- outline-stars-number-start)))
                        (let ((number-str
                               (concat
                                (mapconcat (lambda (i)
                                            (number-to-string (aref counters i)))
                                           (number-sequence 1 rel-level)
                                           ".")
                                " ")))
                          (goto-char match-end-pos)
                          (insert number-str)))))
                  (forward-line 1))))))
      (set-marker end-marker nil))))

;;;###autoload
(defun outline-stars-number-headings ()
  "Insert or update section numbers on all headings in the buffer."
  (interactive)
  (outline-stars--number-in-region (point-min) (point-max)))

;;;###autoload
(defun outline-stars-number-subtree ()
  "Number headings within the current parent's subtree."
  (interactive)
  (save-excursion
    (condition-case nil
        (outline-up-heading 1 t)
      (error (goto-char (point-min))))
    (let* ((parent-level (if (outline-on-heading-p t)
                             (funcall outline-level)
                           0))
           (beg (save-excursion
                  (when (outline-on-heading-p t)
                    (forward-line 1))
                  (point)))
           (end (save-excursion
                  (if (outline-on-heading-p t)
                      (progn (outline-end-of-subtree) (point))
                    (point-max)))))
      (outline-stars--number-in-region beg end parent-level))))

;;;###autoload
(defun outline-stars-number-region (beg end)
  "Number headings between BEG and END at the shallowest level found.
Inherits from the last numbered heading before the region."
  (interactive "r")
  (let ((min-level outline-stars-max-level)
        (initial-counters nil))
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (when (and (outline-on-heading-p t)
                   (looking-at outline-regexp))
          (setq min-level (min min-level (funcall outline-level))))
        (forward-line 1)))
    (when (<= min-level outline-stars-max-level)
      (save-excursion
        (goto-char beg)
        (let ((found nil))
          (while (and (not found)
                      (not (bobp))
                      (condition-case nil
                          (progn (outline-previous-heading) t)
                        (error nil)))
            (when (and (outline-on-heading-p t)
                       (looking-at outline-regexp)
                       (= (funcall outline-level) min-level)
                       (save-excursion
                         (goto-char (match-end 0))
                         (looking-at outline-stars--number-regexp)))
              (let* ((num-str (match-string-no-properties 1))
                     (parts (mapcar #'string-to-number
                                    (split-string num-str "\\.")))
                     (last-part (car (last parts)))
                     (prefix-parts (butlast parts)))
                (setq initial-counters
                      (append prefix-parts (list last-part)))
                (setq found t))))))
      (outline-stars--number-in-region beg end nil initial-counters))))

;;;###autoload
(defun outline-stars-strip-numbers ()
  "Remove section numbers from all headings in the buffer."
  (interactive)
  (outline-stars--strip-numbers-in-region (point-min) (point-max)))

;;; * 9 Provide

(provide 'outline-stars)
;;; outline-stars.el ends here
