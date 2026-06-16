;;; toggle-edit.el --- Toggle read-only mode in buffers   -*- lexical-binding: t -*-

;; Author: IceAsteroid
;; Keywords: convenience, files
;; Homepage: https://github.com/IceAsteroid/toggle-edit
;; Version: 0.1

;; This file is NOT part of GNU Emacs.

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
;; This global minor mode manages read-only status intelligently across buffers,
;; integrating with Treemacs, Company, and theme changes.

;;; TODO
;; 1. Standardize keybindings.

(require 'seq)

(eval-when-compile
  (defvar company-mode nil)
  (defvar corfu-mode nil)
  (declare-function company-abort "company")
  (declare-function corfu-quit "corfu"))

;;; Customization Group
(defgroup toggle-edit nil
  "Toggle read-only mode configurations."
  :group 'convenience)

;;; User Options (defcustom)

(defcustom tedit-enable-derived-mode-list '(prog-mode text-mode conf-mode)
  "List of derived modes where `toggle-edit-mode' should enforce read-only status."
  :type '(repeat symbol)
  :group 'toggle-edit)

(defcustom tedit-enable-major-mode-list '()
  "List of specific major modes where `toggle-edit-mode' should enforce read-only
status."
  :type '(repeat symbol)
  :group 'toggle-edit)

(defcustom tedit-ignored-buffer-regexps '()
  "List of regexps for buffers where saving should NOT be triggered.
Buffers like `*scratch*' are handled automatically."
  :type '(repeat regexp)
  :group 'toggle-edit)

(defcustom tedit-find-file-enable t
  "If non-nil, automatically check read-only status when visiting new files."
  :type 'boolean
  :group 'toggle-edit)

(defcustom tedit-toggle-key "C-`"
  "Key sequence to toggle toggle-edit mode (save and toggle read-only).
Note: This requires restarting the mode to take effect if changed."
  :type 'string
  :group 'toggle-edit)

(defcustom tedit-read-only-cursor-color "red2"
  "The default cursor color when buffer is read-only."
  :type 'string
  :group 'toggle-edit)

(defcustom tedit-cursor-update-delay 0.1
  "The delay to update cursor after idle."
  :type 'number
  :group 'toggle-edit)

;;; Internal Variables

(defvar-local tedit--pending-readonly-check nil
  "Buffer-local flag indicating this buffer needs a read-only check when visible.")

(defvar tedit--theme-cursor-color nil
  "Cache for the current theme's cursor color.")

(defvar tedit--cursor-update-timer nil
  "Timer to handle cursor color updates.")

(defvar tedit--cursor-needs-update-p nil
  "Flag to debounce cursor color updates.")

(defvar tedit--saved-tick nil
  "Tracks the buffer modification tick to prevent redundant hook execution.")

(defvar tedit--treemacs-persist-active-p t
  "Internal flag to manage interaction with Treemacs persistence.")

(defvar tedit-no-save-buffer-hook nil
  "Hook run when `tedit-save-buffer-toggle' is called on an ignored buffer.
This replaces `before-save-hook' and `after-save-hook' for these special
buffers.")

(defvar tedit-mode-map (make-sparse-keymap)
  "Keymap for `toggle-edit-mode'.")

;;; Core Logic

(defun tedit--update-keymap ()
  "Bind the toggle key in the minor mode map."
  (define-key tedit-mode-map (kbd tedit-toggle-key) #'tedit-save-buffer-toggle))

(defun tedit--should-enable-readonly-p ()
  "Return t if the current buffer should be made read-only."
  (or (seq-some #'derived-mode-p tedit-enable-derived-mode-list)
      (memq major-mode tedit-enable-major-mode-list)))

(defun tedit--check-buffers-in-windows ()
  "Scan visible windows and enable read-only mode if the buffer is flagged."
  (catch 'return
    ;; Handle Treemacs edge case
    (unless tedit--treemacs-persist-active-p
      (setq tedit--treemacs-persist-active-p t)
      (throw 'return t))

    (dolist (win (window-list))
      (with-selected-window win
        (when tedit--pending-readonly-check
          (when (tedit--should-enable-readonly-p)
            (read-only-mode 1))
          (setq tedit--pending-readonly-check nil))))))

(defun tedit--flag-current-buffer-for-check ()
  "Mark the current buffer to be checked for read-only status."
  (setq tedit--pending-readonly-check t))

(defun tedit--treemacs-suspend-check (&rest _)
  "Temporarily disable checks during treemacs persistence operations."
  (setq tedit--treemacs-persist-active-p nil))

;;; Cursor Management

(defun tedit--cache-cursor-color (&rest _)
  "Store the default cursor color from the current face."
  (setq tedit--theme-cursor-color (face-attribute 'cursor :background)))

(defun tedit--schedule-cursor-update ()
  "Schedule a cursor color update on the next command loop."
  (setq tedit--cursor-needs-update-p t))

(defun tedit--update-cursor-color ()
  "Update cursor color based on read-only status.
Runs via idle timer to avoid performance hits during rapid input."
  (when tedit--cursor-needs-update-p
    (while-no-input
      (if (not tedit--theme-cursor-color)
          (tedit--cache-cursor-color)
        (set-cursor-color
         (if buffer-read-only tedit-read-only-cursor-color tedit--theme-cursor-color)))
      (setq tedit--cursor-needs-update-p nil))))

;;; Interactive Commands

(defun tedit-save-buffer-toggle ()
  "Toggle `read-only-mode' and save the buffer if appropriate.
If the buffer is ignored (see `tedit-no-save-buffer-regexps'),
it runs `tedit-no-save-buffer-hook' instead of saving."
  (interactive)
  (unless buffer-read-only
    (if (and (buffer-file-name)
             (not (seq-some (lambda (re) (string-match-p re (buffer-name)))
                            tedit-no-save-buffer-regexps)))
        ;; Normal file: save it
        (basic-save-buffer)
      ;; Special buffer: run hooks safely
      (let ((current-tick (buffer-chars-modified-tick)))
        (unless (eq tedit--saved-tick current-tick)
          (with-demoted-errors "Error in toggle-edit-no-save-buffer-hook: %s"
            (run-hooks 'tedit-no-save-buffer-hook))
          (setq-local tedit--saved-tick current-tick)))))
  (read-only-mode 'toggle))

;;; Company Integration

(defun tedit--company-abort-if-readonly ()
  "Abort company completion if the buffer is read-only."
  (and buffer-read-only
       (bound-and-true-p company-mode)
       (company-abort)))

(defun tedit--setup-company-hook ()
  "Add the abort check to read-only hooks."
  (if company-mode
      (add-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly nil t)
    (remove-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly t)))

;;; Corfu Integration
;; Separate and not combine with Company Integration for divergent cases in the future.

(defun tedit--corfu-quit-if-readonly ()
  (and buffer-read-only
       (bound-and-true-p corfu-mode)
       (corfu-quit)))

(defun tedit--setup-corfu-hook ()
  "Add the abort check to read-only hooks."
  (if corfu-mode
      (add-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly nil t)
    (remove-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly t)))

;;; Mode Definition

;;;###autoload
(define-minor-mode tedit-mode
  "Global minor mode to toggle editing and read-only status easily."
  :global t
  :group 'toggle-edit
  :lighter " TEdit"
  :keymap tedit-mode-map
  (if tedit-mode
      ;; ENABLE
      (progn
        (tedit--update-keymap)
        (tedit--cache-cursor-color)
        ;; Hooks
        (add-hook 'post-command-hook #'tedit--schedule-cursor-update)
        (add-hook 'window-configuration-change-hook #'tedit--check-buffers-in-windows)
        (add-hook 'find-file-hook #'tedit--flag-current-buffer-for-check)
        ;; Advice
        (advice-add 'treemacs--persist :before #'tedit--treemacs-suspend-check)
        (advice-add 'enable-theme :after #'tedit--cache-cursor-color)
        ;; Timer
        (setq tedit--cursor-update-timer
              (run-with-idle-timer tedit-cursor-update-delay t #'tedit--update-cursor-color))
        ;; Company Integration
        (with-eval-after-load 'company
          (add-hook 'company-mode-hook #'tedit--setup-company-hook))
        ;; Corfu Integratoin
        (with-eval-after-load 'corfu
          (add-hook 'corfu-mode-hook #'tedit--setup-corfu-hook)))
    ;; DISABLE
    (progn
      (remove-hook 'post-command-hook #'tedit--schedule-cursor-update)
      (remove-hook 'window-configuration-change-hook #'tedit--check-buffers-in-windows)
      (remove-hook 'find-file-hook #'tedit--flag-current-buffer-for-check)
      (advice-remove 'treemacs--persist #'tedit--treemacs-suspend-check)
      (advice-remove 'enable-theme #'tedit--cache-cursor-color)
      (when tedit--cursor-update-timer
        (cancel-timer tedit--cursor-update-timer)
        (setq tedit--cursor-update-timer nil))
      (with-eval-after-load 'company
        (remove-hook 'company-mode-hook #'tedit--setup-company-hook)
        ;; Also cleanup locally if possible, though strict cleanup for global hooks is tricky
        )
      (with-eval-after-load 'corfu
        (remove-hook 'corfu-mode-hook #'tedit--setup-corfu-hook)))))

(provide 'toggle-edit)

;;; toggle-edit.el ends here

;; Local Variables:
;; read-symbol-shorthands: (("tedit-" . "toggle-edit-"))
;; End:
