;;; outline-stars.el --- Outshine-style star headings for outline-minor-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Hsin-ti McClelland

;; Author: Paul Hsin-ti McClelland <PaulHMcClelland@protonmail.com>
;; Version: 0.3.0
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
;;   - Optional overline on top-level headings for visual section breaks
;;   - `imenu' integration for heading navigation
;;   - Subtree promote/demote that optionally updates all child headings
;;   - Global visibility cycling (all → headings → top-level → all)
;;   - Alphabetical sorting of sibling headings
;;   - Section numbering (1, 1.1, 1.1.2, ...) with insert and strip commands
;;   - Automatic TAB cycling on headings via `outline-minor-mode-cycle'
;;   - Nullifies `outline-search-function' (Emacs 29+) so custom regexps work
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
;; By default, headings use the section-comment convention where
;; available, adding one extra comment character for single-character
;; comment starters.  This produces headings that degrade gracefully
;; in vanilla Emacs:
;;   ;;; * Top level       (elisp)
;;   ### * Top level       (R/Python)
;;   ## * Top level        (shell)
;;   // * Top level        (C/C++ — unchanged, avoids Doxygen conflict)
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
  "Outshine-style star headings for outline-minor-mode."
  :group 'outline
  :prefix "outline-stars-")

(defcustom outline-stars-max-level 8
  "Maximum heading depth for star-based headings."
  :type 'integer
  :group 'outline-stars)

(defcustom outline-stars-modes '(prog-mode)
  "List of major modes (or parent modes) where outline-stars should activate.
Each entry is checked with `derived-mode-p', so specifying `prog-mode'
covers all programming modes."
  :type '(repeat symbol)
  :group 'outline-stars)

(defcustom outline-stars-promote-subtree-p t
  "Whether promote/demote commands operate on the entire subtree.
When non-nil (the default), `outline-stars-promote' and
`outline-stars-demote' adjust all child headings along with
the current heading.  When nil, only the current heading is changed."
  :type 'boolean
  :group 'outline-stars)

(defcustom outline-stars-section-comments t
  "Whether to use section-level comments for heading prefixes.
When non-nil (the default), one extra comment character is added
for modes with single-character comment starters, producing headings
that follow the section-comment convention:
  elisp: ;;; *   R: ### *   shell: ## *

This is useful because ;;; headings degrade gracefully in vanilla
Emacs (which recognizes ;;; as a section heading), and ### is a
semi-established section convention in R and Python.

Modes with multi-character comment starters (// in C, C++, Java)
are unaffected regardless of this setting, avoiding conflicts with
documentation comment syntax like Doxygen.

When nil, headings use the classic outshine convention:
  elisp: ;; *    R: ## *    shell: # *"
  :type 'boolean
  :group 'outline-stars)

(defcustom outline-stars-level-1-overline nil
  "Whether to add an overline to top-level heading text.
When non-nil, `outline-stars-level-1' headings are fontified with
an overline, creating a visual section break.  The overline color
is inherited from the heading face foreground."
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
  "Buffer-local storage for font-lock keywords added by outline-stars.
Used for clean removal when the mode is deactivated.")

(defvar-local outline-stars--cycle-state 'show-all
  "Current state of global visibility cycling.
One of `show-all', `headings-only', or `top-level'.")

;;; * 2 Comment Prefix

(defun outline-stars--comment-prefix ()
  "Return the comment prefix for outshine-style headings.
Derives the base prefix from `comment-start' and `comment-add'.
When `outline-stars-section-comments' is non-nil and the base
comment character is a single character, one extra character is
appended to produce section-level comments.  Multi-character
comment starters (like //) are never extended, avoiding
conflicts with documentation comment syntax."
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
  "Build `outline-heading-alist' entries for PREFIX.
Pre-seeds the alist with all heading strings up to
`outline-stars-max-level', mapping each to its level number.
This allows `outline-level' to use a fast alist lookup
instead of regexp matching on every call."
  (let (alist)
    (cl-loop for level from outline-stars-max-level downto 1
             do (push (cons (concat prefix " " (make-string level ?*) " ")
                            level)
                      alist))
    alist))

(defun outline-stars--level ()
  "Return the heading level for the current match.
Uses `outline-heading-alist' for fast lookup, falling back to
star counting if the matched string is not in the alist."
  (or (cdr (assoc (match-string 0) outline-heading-alist))
      (length (replace-regexp-in-string
               "[^*]" ""
               (match-string-no-properties 0)))))

;;; ** 3.2 Activation

(defun outline-stars-setup ()
  "Set up outline-minor-mode with outshine-style star headings.
Configures `outline-regexp', `outline-level', heading alist,
fontification, imenu, and TAB cycling.  Intended to be called
from `after-change-major-mode-hook' via `outline-stars-mode'."
  (when-let* ((prefix (outline-stars--comment-prefix)))
    (let* ((qprefix (regexp-quote prefix))
           (star-re (format "[*]\\{1,%d\\}" outline-stars-max-level))
           (out-regexp (concat qprefix " " star-re " ")))
      ;; Activate first so our settings override the mode's defaults.
      (outline-minor-mode 1)
      ;; Emacs 29+ modes can set outline-search-function, which takes
      ;; precedence over outline-regexp and silently breaks custom regexps.
      (setq-local outline-search-function nil)
      (setq-local outline-regexp out-regexp)
      ;; Pre-seed the heading alist for fast level lookup.
      (setq-local outline-heading-alist
                  (outline-stars--build-heading-alist prefix))
      (setq-local outline-level #'outline-stars--level)
      ;; Enable TAB cycling on headings.
      (setq-local outline-minor-mode-cycle t)
      ;; Imenu: expose headings as navigable entries.
      (let ((heading-entry
             `("Headings" ,(concat "^" qprefix " " star-re " \\(.*\\)$") 1)))
        (if imenu-generic-expression
            (add-to-list 'imenu-generic-expression heading-entry)
          (setq-local imenu-generic-expression (list heading-entry))))
      ;; Fontification: per-level faces on heading text.
      (outline-stars--add-font-lock qprefix))))

;;; ** 3.3 Fontification

(defun outline-stars--add-font-lock (qprefix)
  "Add font-lock keywords for star headings using QPREFIX.
Faces apply to the heading text only (group 1), not the comment
prefix or stars.  When `outline-stars-level-1-overline' is non-nil,
level 1 headings receive an overline for visual section breaks."
  (let ((keywords
         (cl-loop for level from 1 to outline-stars-max-level
                  for face = (intern (format "outline-stars-level-%d" level))
                  for face-spec = (if (and (= level 1)
                                           outline-stars-level-1-overline)
                                      `(:inherit ,face :overline t)
                                    face)
                  collect
                  `(,(format "^%s %s \\(.*\\)"
                             qprefix
                             (format "[*]\\{%d\\}" level))
                    (1 ',face-spec t)))))
    (setq outline-stars--font-lock-keywords keywords)
    (font-lock-add-keywords nil keywords)
    (when font-lock-mode
      (font-lock-flush))))

;;; ** 3.4 Deactivation

(defun outline-stars-teardown ()
  "Remove font-lock keywords and deactivate outline-minor-mode."
  (when outline-stars--font-lock-keywords
    (font-lock-remove-keywords nil outline-stars--font-lock-keywords)
    (setq outline-stars--font-lock-keywords nil)
    (when font-lock-mode
      (font-lock-flush)))
  (when outline-minor-mode
    (outline-minor-mode -1)))

;;; * 4 Global Minor Mode

(defun outline-stars--maybe-setup ()
  "Activate outline-stars if the current mode derives from a listed mode."
  (when (apply #'derived-mode-p outline-stars-modes)
    (outline-stars-setup)))

(defun outline-stars--maybe-teardown ()
  "Deactivate outline-stars in buffers where it was set up."
  (when outline-stars--font-lock-keywords
    (outline-stars-teardown)))

;;;###autoload
(define-minor-mode outline-stars-mode
  "Global minor mode for outshine-style star headings via outline-minor-mode.
When enabled, buffers in modes listed in `outline-stars-modes' will
automatically get star-based heading detection, fontification, and
imenu support."
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
  "Insert a new heading at the current level using outshine-style stars."
  (interactive)
  (let* ((prefix (outline-stars--comment-prefix))
         (level (save-excursion
                  (condition-case nil
                      (progn
                        (unless (outline-on-heading-p t)
                          (outline-back-to-heading t))
                        (funcall outline-level))
                    (error 1)))))
    (end-of-line)
    (newline)
    (insert prefix " " (make-string level ?*) " ")))

;;; ** 5.3 Promote/Demote

;;;###autoload
(defun outline-stars-promote ()
  "Promote the current heading by removing one star.
When `outline-stars-promote-subtree-p' is non-nil, all child
headings are promoted as well."
  (interactive)
  (if outline-stars-promote-subtree-p
      (outline-stars-promote-subtree)
    (outline-stars--promote-single)))

;;;###autoload
(defun outline-stars-demote ()
  "Demote the current heading by adding one star.
When `outline-stars-promote-subtree-p' is non-nil, all child
headings are demoted as well."
  (interactive)
  (if outline-stars-promote-subtree-p
      (outline-stars-demote-subtree)
    (outline-stars--demote-single)))

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
  "Promote the current heading and all its children by one level.
Refuses to promote if the top heading is already at level 1."
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
              (forward-line 1))))))))

;;;###autoload
(defun outline-stars-demote-subtree ()
  "Demote the current heading and all its children by one level.
Refuses to demote if any heading in the subtree is at max level."
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
            (forward-line 1)))))))

;;; * 6 Visibility Cycling

;;;###autoload
(defun outline-stars-cycle-buffer ()
  "Cycle global visibility: show all -> headings only -> top level -> show all.
Works from any point in the buffer, unlike `outline-cycle-buffer' which
requires point to be on a heading."
  (interactive)
  (pcase outline-stars--cycle-state
    ('show-all
     (outline-show-all)
     (outline-hide-region-body (point-min) (point-max))
     (setq outline-stars--cycle-state 'headings-only)
     (message "Headings only"))
    ('headings-only
     (outline-hide-sublevels 1)
     (setq outline-stars--cycle-state 'top-level)
     (message "Top-level headings"))
    ('top-level
     (outline-show-all)
     (setq outline-stars--cycle-state 'show-all)
     (message "Show all"))))

;;; * 7 Sorting

;;;###autoload
(defun outline-stars-sort-siblings (&optional reverse-p)
  "Sort sibling headings alphabetically under the current parent.
Each heading is moved with its entire subtree.  With prefix argument
REVERSE-P, sort in reverse alphabetical order."
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
      ;; Collect siblings: (heading-text start-pos end-pos)
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
          ;; Only rearrange if the order actually changed
          (unless (equal (mapcar #'car siblings) (mapcar #'car sorted))
            ;; Replace from last to first to preserve positions
            (let ((pairs (cl-mapcar #'cons
                                    (reverse siblings)
                                    (reverse sorted-texts))))
              (dolist (pair pairs)
                (let ((orig (car pair))
                      (new-text (cdr pair)))
                  (delete-region (nth 1 orig) (nth 2 orig))
                  (goto-char (nth 1 orig))
                  (insert new-text))))))))))

;;; * 8 Section Numbering

(defconst outline-stars--number-regexp
  "\\([0-9]+\\(?:\\.[0-9]+\\)*\\) "
  "Regexp matching a section number followed by a space.
Used by `outline-stars-number-headings' and `outline-stars-strip-numbers'
to identify existing numbers in heading text.")

;;;###autoload
(defun outline-stars-number-headings ()
  "Insert or update hierarchical section numbers on all headings.
Numbers are placed between the stars and the heading text, using
dotted notation (1, 1.1, 1.1.2, etc.).  Existing numbers are
stripped before re-numbering, making the command idempotent.

Example result:
  ;;; * 1 Foundation
  ;;; ** 1.1 Customization
  ;;; ** 1.2 Faces
  ;;; * 2 Buffer Setup
  ;;; ** 2.1 Activation"
  (interactive)
  (outline-stars-strip-numbers)
  (save-excursion
    (goto-char (point-min))
    (let ((counters (make-vector (1+ outline-stars-max-level) 0)))
      (while (not (eobp))
        (when (and (outline-on-heading-p t)
                   (looking-at outline-regexp))
          (let* ((level (funcall outline-level))
                 (match-end-pos (match-end 0)))
            ;; Increment counter at this level, reset all deeper levels.
            (aset counters level (1+ (aref counters level)))
            (cl-loop for i from (1+ level) to outline-stars-max-level
                     do (aset counters i 0))
            ;; Build the number string: "1.2.3 "
            (let ((number-str
                   (concat
                    (mapconcat (lambda (i) (number-to-string (aref counters i)))
                               (number-sequence 1 level)
                               ".")
                    " ")))
              (goto-char match-end-pos)
              (insert number-str))))
        (forward-line 1)))))

;;;###autoload
(defun outline-stars-strip-numbers ()
  "Remove section numbers from all headings.
Strips any dotted number prefix (e.g., \"1.2.3 \") that appears
immediately after the stars in each heading line."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when (and (outline-on-heading-p t)
                 (looking-at outline-regexp))
        (goto-char (match-end 0))
        (when (looking-at outline-stars--number-regexp)
          (delete-region (match-beginning 0) (match-end 0))))
      (forward-line 1))))

;;; * 9 Provide

(provide 'outline-stars)
;;; outline-stars.el ends here
