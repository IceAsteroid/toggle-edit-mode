;;; toggle-edit-3.el --- Toggle read-only mode in buffers   -*- lexical-binding: t -*-

;; Author: IceAsteroid
;; Keywords: convenience, files
;; Homepage: https://github.com/IceAsteroid/toggle-edit
;; Version: 0.3

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; This global minor mode manages read-only status intelligently across buffers.
;; State changes strictly evaluate "on-focus" to protect background buffers and 
;; async processes from being prematurely locked.

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

;;; Inclusion Rules (Whitelists)

(defcustom tedit-enable-derived-mode-list '(prog-mode text-mode conf-mode)
  "List of derived modes where `toggle-edit-mode' should enforce read-only status."
  :type '(repeat symbol)
  :group 'toggle-edit)

(defcustom tedit-enable-major-mode-list '()
  "List of specific major modes where `toggle-edit-mode' should enforce read-only status."
  :type '(repeat symbol)
  :group 'toggle-edit)

;;; Exclusion Rules (Blacklists)

(defcustom tedit-ignore-modes '(magit-status-mode magit-log-mode dired-mode)
  "Modes that should NEVER be toggled read-only, overriding the enable lists."
  :type '(repeat symbol)
  :group 'toggle-edit)

(defcustom tedit-ignore-buffer-name-regexps '("^\\*" "^ ")
  "Regexps for buffer names that should NEVER be toggled read-only.
By default, this ignores all hidden/internal buffers starting with `*`."
  :type '(repeat regexp)
  :group 'toggle-edit)

;;; Behavior Settings

(defcustom tedit-always-lock-on-switch nil
  "If non-nil, reset buffers to read-only EVERY time you switch to their window.
If nil, read-only is only applied the FIRST time the buffer is viewed."
  :type 'boolean
  :group 'toggle-edit)

(defcustom tedit-no-save-buffer-regexps '()
  "List of regexps for buffers where saving should NOT be triggered."
  :type '(repeat regexp)
  :group 'toggle-edit)

(defcustom tedit-toggle-key "C-`"
  "Key sequence to toggle toggle-edit mode (save and toggle read-only)."
  :type 'string
  :group 'toggle-edit)

(defcustom tedit-read-only-cursor-color "red2"
  "The default cursor color when buffer is read-only."
  :type 'string
  :group 'toggle-edit)

;;; Internal Variables

(defvar tedit--theme-cursor-color nil
  "Cache for the current theme's cursor color.")

(defvar tedit--saved-tick nil
  "Tracks the buffer modification tick to prevent redundant hook execution.")

(defvar tedit-no-save-buffer-hook nil
  "Hook run when `tedit-save-buffer-toggle' is called on an ignored buffer.")

(defvar tedit-mode-map (make-sparse-keymap)
  "Keymap for `toggle-edit-mode'.")

(defvar-local tedit--initialized-p nil
  "Tracks if the buffer has already been evaluated by toggle-edit.")

;;; Core Logic

(defun tedit--update-keymap ()
  "Bind the toggle key in the minor mode map."
  (define-key tedit-mode-map (kbd tedit-toggle-key) #'tedit-save-buffer-toggle))

(defun tedit--should-enable-readonly-p ()
  "Return t if the buffer should be read-only based on ignore and enable lists."
  (let ((ignore-regex (regexp-opt tedit-ignore-buffer-name-regexps)))
    (and (not (string-match-p ignore-regex (buffer-name)))
         (not (seq-some #'derived-mode-p tedit-ignore-modes))
         (or (seq-some #'derived-mode-p tedit-enable-derived-mode-list)
             (memq major-mode tedit-enable-major-mode-list)))))

(defun tedit--focus-handler (&rest _)
  "Evaluate read-only state exactly when a window or buffer receives user focus."
  (when tedit-mode
    (with-current-buffer (window-buffer (selected-window))
      ;; Only execute if it's the first time viewing, OR if the user wants strict resetting
      (when (or (not tedit--initialized-p) tedit-always-lock-on-switch)
        (setq-local tedit--initialized-p t)
        (when (and (not buffer-read-only) (tedit--should-enable-readonly-p))
          (read-only-mode 1)
          (add-hook 'read-only-mode-hook #'tedit--update-cursor-color nil t)
          (add-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly nil t)
          (add-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly nil t)))
      ;; Sync the cursor color purely based on the current focused state
      (tedit--update-cursor-color))))

(defun tedit--cleanup-buffer ()
  "Clean up toggle-edit modifications from the current buffer."
  (remove-hook 'read-only-mode-hook #'tedit--update-cursor-color t)
  (remove-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly t)
  (remove-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly t)
  (setq-local tedit--initialized-p nil))

;;; Cursor Management

(defun tedit--cache-cursor-color (&rest _)
  "Store the default cursor color from the current face."
  (setq tedit--theme-cursor-color (face-attribute 'cursor :background)))

(defun tedit--update-cursor-color ()
  "Update cursor color based on read-only status of the current buffer."
  (when tedit-mode
    (unless tedit--theme-cursor-color
      (tedit--cache-cursor-color))
    (set-cursor-color
     (if buffer-read-only
         tedit-read-only-cursor-color
       (or tedit--theme-cursor-color "black")))))

;;; Interactive Commands

(defun tedit-save-buffer-toggle ()
  "Toggle `read-only-mode' and save the buffer if appropriate."
  (interactive)
  (unless buffer-read-only
    (if (and (buffer-file-name)
             (not (seq-some (lambda (re) (string-match-p re (buffer-name)))
                            tedit-no-save-buffer-regexps)))
        (basic-save-buffer)
      (let ((current-tick (buffer-chars-modified-tick)))
        (unless (eq tedit--saved-tick current-tick)
          (with-demoted-errors "Error in toggle-edit-no-save-buffer-hook: %s"
            (run-hooks 'tedit-no-save-buffer-hook))
          (setq-local tedit--saved-tick current-tick)))))
  ;; Toggle the mode
  (read-only-mode 'toggle)
  ;; FORCE cursor update for manual toggles, bypassing any blacklists
  (tedit--update-cursor-color))

;;; Package Integration

(defun tedit--company-abort-if-readonly ()
  "Abort company completion if the buffer is read-only."
  (and buffer-read-only
       (bound-and-true-p company-mode)
       (fboundp 'company-abort)
       (company-abort)))

(defun tedit--corfu-quit-if-readonly ()
  "Abort corfu completion if the buffer is read-only."
  (and buffer-read-only
       (bound-and-true-p corfu-mode)
       (fboundp 'corfu-quit)
       (corfu-quit)))

;;; Mode Definition

;;;###autoload
(define-minor-mode tedit-mode
  "Global minor mode to toggle editing and read-only status easily."
  :global t
  :group 'toggle-edit
  :lighter " TEdit"
  :keymap tedit-mode-map
  (if tedit-mode
      (progn
        (tedit--update-keymap)
        (tedit--cache-cursor-color)
        ;; Bind strictly to human window/buffer focus changes
        (add-hook 'window-selection-change-functions #'tedit--focus-handler)
        (add-hook 'window-buffer-change-functions #'tedit--focus-handler)
        (advice-add 'enable-theme :after #'tedit--cache-cursor-color)
        ;; Initialize currently focused window immediately
        (tedit--focus-handler))
    ;; DISABLE
    (remove-hook 'window-selection-change-functions #'tedit--focus-handler)
    (remove-hook 'window-buffer-change-functions #'tedit--focus-handler)
    (advice-remove 'enable-theme #'tedit--cache-cursor-color)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (tedit--cleanup-buffer)))))

(provide 'toggle-edit-3)

;;; toggle-edit-3.el ends here
