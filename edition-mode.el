;;; toggle-edit-mode.el --- Toggle read-only in buffers -*- lexical-binding: t -*-

;; Author: IceAsteroid
;; Keywords: convenience, files
;; Version: 0.2

;;; Commentary:
;; This minor mode manages read-only status intelligently across buffers,
;; integrating with Treemacs, Company, and theme changes.

;;; Code:

(require 'cl-lib)

(eval-when-compile
  (declare-function company-abort "company"))

;;; Customization Group
(defgroup edition nil
  "Toggle edition/read-only mode configurations."
  :group 'convenience)

;;; User Options (defcustom)

(defcustom edition-enable-derived-mode-list '(prog-mode text-mode conf-mode)
  "List of derived modes where `edition-mode' should enforce read-only status."
  :type '(repeat symbol)
  :group 'edition)

(defcustom edition-enable-major-mode-list '()
  "List of specific major modes where `edition-mode' should enforce read-only
status."
  :type '(repeat symbol)
  :group 'edition)

(defcustom edition-ignored-buffer-regexps '()
  "List of regexps for buffers where saving should NOT be triggered.
Buffers like `*scratch*' are handled automatically."
  :type '(repeat regexp)
  :group 'edition)

(defcustom edition-find-file-enable t
  "If non-nil, automatically check read-only status when visiting new files."
  :type 'boolean
  :group 'edition)

(defcustom edition-toggle-key "C-`"
  "Key sequence to toggle edition mode (save and toggle read-only).
Note: This requires restarting the mode to take effect if changed."
  :type 'string
  :group 'edition)

;;; Internal Variables

(defvar edition--pending-readonly-check nil
  "Buffer-local flag indicating this buffer needs a read-only check when visible.")
(make-variable-buffer-local 'edition--pending-readonly-check)

(defvar edition--theme-cursor-color nil
  "Cache for the current theme's cursor color.")

(defvar edition--cursor-update-timer nil
  "Timer to handle cursor color updates.")

(defvar edition--cursor-needs-update-p nil
  "Flag to debounce cursor color updates.")

(defvar edition--saved-tick nil
  "Tracks the buffer modification tick to prevent redundant hook execution.")

(defvar edition--treemacs-persist-active-p t
  "Internal flag to manage interaction with Treemacs persistence.")

(defvar edition-no-save-buffer-hook nil
  "Hook run when `edition-save-buffer-toggle' is called on an ignored buffer.
This replaces `before-save-hook' and `after-save-hook' for these special
buffers.")

(defvar edition-mode-map (make-sparse-keymap)
  "Keymap for `edition-mode'.")

;;; Core Logic

(defun edition--update-keymap ()
  "Bind the toggle key in the minor mode map."
  (define-key edition-mode-map (kbd edition-toggle-key) #'edition-save-buffer-toggle))

(defun edition--should-enable-readonly-p ()
  "Return t if the current buffer should be made read-only."
  (or (seq-some #'derived-mode-p edition-enable-derived-mode-list)
      (memq major-mode edition-enable-major-mode-list)))

(defun edition--check-buffers-in-windows ()
  "Scan visible windows and enable read-only mode if the buffer is flagged."
  (catch 'return
    ;; Handle Treemacs edge case
    (unless edition--treemacs-persist-active-p
      (setq edition--treemacs-persist-active-p t)
      (throw 'return t))

    (dolist (win (window-list))
      (with-selected-window win
        (when edition--pending-readonly-check
          (when (edition--should-enable-readonly-p)
            (read-only-mode 1))
          (setq edition--pending-readonly-check nil))))))

(defun edition--flag-current-buffer-for-check ()
  "Mark the current buffer to be checked for read-only status."
  (setq edition--pending-readonly-check t))

(defun edition--treemacs-suspend-check (&rest _)
  "Temporarily disable checks during treemacs persistence operations."
  (setq edition--treemacs-persist-active-p nil))

;;; Cursor Management

(defun edition--cache-cursor-color (&rest _)
  "Store the default cursor color from the current face."
  (setq edition--theme-cursor-color (face-attribute 'cursor :background)))

(defun edition--schedule-cursor-update ()
  "Schedule a cursor color update on the next command loop."
  (setq edition--cursor-needs-update-p t))

(defun edition--update-cursor-color ()
  "Update cursor color based on read-only status.
Runs via idle timer to avoid performance hits during rapid input."
  (when edition--cursor-needs-update-p
    (while-no-input
      (if (not edition--theme-cursor-color)
          (edition--cache-cursor-color)
        (set-cursor-color
         (if buffer-read-only "red2" edition--theme-cursor-color)))
      (setq edition--cursor-needs-update-p nil))))

;;; Interactive Commands

(defun edition-save-buffer-toggle ()
  "Toggle `read-only-mode' and save the buffer if appropriate.
If the buffer is ignored (see `edition-ignored-buffer-regexps'),
it runs `edition-no-save-buffer-hook' instead of saving."
  (interactive)
  (unless buffer-read-only
    (if (and (buffer-file-name)
             (not (and edition-ignored-buffer-regexps
                       (string-match-p (mapconcat #'identity edition-ignored-buffer-regexps "\\|")
                                       (buffer-name)))))
        ;; Normal file: save it
        (basic-save-buffer)

      ;; Special buffer: run hooks safely
      (let ((current-tick (buffer-chars-modified-tick)))
        (unless (eq edition--saved-tick current-tick)
          (with-demoted-errors "Error in edition-no-save-buffer-hook: %s"
            (run-hooks 'edition-no-save-buffer-hook))
          (setq-local edition--saved-tick current-tick)))))

  (read-only-mode 'toggle))

;;; Company Integration

(defun edition--company-abort-if-readonly ()
  "Abort company completion if the buffer is read-only."
  (when (and buffer-read-only (bound-and-true-p company-mode))
    (company-abort)))

(defun edition--setup-company-hook ()
  "Add the abort check to read-only hooks."
  (add-hook 'read-only-mode-hook #'edition--company-abort-if-readonly nil t))

;;; Mode Definition

;;;###autoload
(define-minor-mode edition-mode
  "Global minor mode to toggle editing and read-only status easily."
  :global t
  :group 'edition
  :lighter " Edit"
  :keymap edition-mode-map

  (if edition-mode
      ;; ENABLE
      (progn
        (edition--update-keymap)
        (edition--cache-cursor-color)

        ;; Hooks
        (add-hook 'post-command-hook #'edition--schedule-cursor-update)
        (add-hook 'window-configuration-change-hook #'edition--check-buffers-in-windows)
        (add-hook 'find-file-hook #'edition--flag-current-buffer-for-check)

        ;; Advice
        (advice-add 'treemacs--persist :before #'edition--treemacs-suspend-check)
        (advice-add 'enable-theme :after #'edition--cache-cursor-color)

        ;; Timer
        (setq edition--cursor-update-timer
              (run-with-idle-timer 0.1 t #'edition--update-cursor-color))

        ;; Company Integration
        (with-eval-after-load 'company
          (add-hook 'company-mode-hook #'edition--setup-company-hook)))

    ;; DISABLE
    (progn
      (remove-hook 'post-command-hook #'edition--schedule-cursor-update)
      (remove-hook 'window-configuration-change-hook #'edition--check-buffers-in-windows)
      (remove-hook 'find-file-hook #'edition--flag-current-buffer-for-check)

      (advice-remove 'treemacs--persist #'edition--treemacs-suspend-check)
      (advice-remove 'enable-theme #'edition--cache-cursor-color)

      (when edition--cursor-update-timer
        (cancel-timer edition--cursor-update-timer)
        (setq edition--cursor-update-timer nil))

      (with-eval-after-load 'company
        (remove-hook 'company-mode-hook #'edition--setup-company-hook)
        ;; Also cleanup locally if possible, though strict cleanup for global hooks is tricky
        ))))

(provide 'toggle-edit-mode)
;;; toggle-edit-mode.el ends here
