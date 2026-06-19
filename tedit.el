;;; tedit.el --- Toggle read-only mode in buffers   -*- lexical-binding: t -*-

;; Author: IceAsteroid
;; Keywords: convenience, files
;; Homepage: https://github.com/IceAsteroid/toggle-edit
;; Version: 0.3

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
;; This global minor mode manages read-only status intelligently across buffers.
;; State changes strictly evaluate "on-focus" to protect background buffers and 
;; async processes from being prematurely locked.

(require 'seq)

;;; Code:

(eval-when-compile
  (defvar company-mode nil)
  (defvar corfu-mode nil)
  (declare-function company-abort "company")
  (declare-function corfu-quit "corfu"))

;;; Customization Group

(defgroup tedit nil
  "Toggle read-only mode configurations."
  :group 'convenience)

;;; Inclusion Rules (Whitelists)

(defcustom tedit-enable-derived-mode-list '(prog-mode text-mode conf-mode)
  "List of derived modes where `tedit-mode' should enforce read-only status."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-enable-major-mode-list '()
  "List of specific major modes where `tedit-mode' should enforce read-only status."
  :type '(repeat symbol)
  :group 'tedit)

;;; Exclusion Rules (Blacklists)

(defcustom tedit-ignore-modes '(magit-status-mode magit-log-mode dired-mode)
  "Modes that should NEVER be toggled read-only, overriding the enable lists."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-ignore-buffer-name-regexps '("^\\*" "^ ")
  "Regexps for buffer names that should NEVER be toggled read-only.
By default, this ignores all hidden/internal buffers starting with `*`."
  :type '(repeat regexp)
  :group 'tedit)

;;; Behavior Settings

(defcustom tedit-always-lock-on-switch nil
  "If non-nil, reset buffers to read-only EVERY time you switch to their window.
If nil, read-only is only applied the FIRST time the buffer is viewed."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-no-lock-from-deep-minibuffer t
  "If non-nil, not lock read-only from executing a command to open a temp buffer.
For the selected window is refocused from.  As if
`tedit-always-lock-on-switch' is non-nil.

This is useful for not using a completion system like `vertico-mode',
where you select the \"*completion*\" window and back to the selected
window."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-no-lock-from-dedicated-window nil
  "If non-nil, not lock read-only from dedicated windows.
For the selected window is refocused from.  As if
`tedit-always-lock-on-switch' is non-nil."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-no-lock-from-modes '()
  "List of modes to not lock read-only from.
For the selected window is refocused from.  As if
`tedit-always-lock-on-switch' is non-nil."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-no-lock-from-buffers '()
  "List of buffer name regexps to not lock read-only from.
For the selected window is refocused from.  As if
`tedit-always-lock-on-switch' is non-nil."
  :type '(repeat string)
  :group 'tedit)

(defcustom tedit-no-save-buffer-regexps '()
  "List of regexps for buffers where saving should NOT be triggered."
  :type '(repeat regexp)
  :group 'tedit)

(defcustom tedit-toggle-key "C-`"
  "Key sequence to toggle `tedit-mode' (save and toggle read-only)."
  :type 'string
  :group 'tedit)

(defcustom tedit-read-only-cursor-color "red2"
  "The default cursor color when buffer is read-only."
  :type 'string
  :group 'tedit)

(defcustom tedit-cursor-timer-delay 0.1
  "Seconds of idle time before checks and updates of cursor color for `tedit-mode'."
  :type 'number
  :group 'tedit)

;;; Internal Variables

(defvar tedit--theme-cursor-color nil
  "Cache for the current theme's cursor color.")

(defvar tedit--saved-tick nil
  "Tracks the buffer modification tick to prevent redundant hook execution.")

(defvar tedit-no-save-buffer-hook nil
  "Hook run when `tedit-save-buffer-toggle' is called on an ignored buffer.")

(defvar tedit-mode-map (make-sparse-keymap)
  "Keymap for `tedit-mode'.")

(defvar-local tedit--initialized-p nil
  "Tracks if the buffer has already been evaluated by tedit.")

(defvar tedit--last-focused-buffer nil
  "Tracks the last non-minibuffer buffer to prevent relocking on minibuffer exits.")

(defvar tedit--cursor-timer nil
  "The idle timer object responsible for cursor visual sync.")

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
    (let ((buf (window-buffer (selected-window))))
      (unless (or (minibufferp buf)
                  ;; exclude minibuffers such as `*Completions*' for the built-in completion system, e.g.
                  (and tedit-no-lock-from-deep-minibuffer (> (minibuffer-depth) 0))
                  (and tedit-no-lock-from-dedicated-window (window-dedicated-p (selected-window)))
                  (string-match-p (regexp-opt tedit-no-lock-from-buffers) (buffer-name buf))
                  (with-current-buffer buf
                    (derived-mode-p tedit-no-lock-from-modes)))
        (with-current-buffer buf
          ;; Check if we genuinely switched to a different buffer
          (let ((switched-buffer-p (not (eq buf tedit--last-focused-buffer))))
            ;; Execute if first time viewing OR (strict reset AND we actually switched buffers)
            (when (or (not tedit--initialized-p)
                      (and tedit-always-lock-on-switch switched-buffer-p))
              (setq-local tedit--initialized-p t)
              (when (and (not buffer-read-only) (tedit--should-enable-readonly-p))
                (read-only-mode 1)
                (add-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly nil t)
                (add-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly nil t))))
          (setq tedit--last-focused-buffer buf))))))

(defun tedit--cleanup-buffer ()
  "Clean up `tedit-mode' modifications from the current buffer."
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

(defun tedit--manage-timer ()
  "Start or stop the cursor sync idle timer based on mode state."
  (if tedit-mode
      (unless tedit--cursor-timer
        (setq tedit--cursor-timer
              (run-with-idle-timer tedit-cursor-timer-delay t #'tedit--update-cursor-color)))
    (when tedit--cursor-timer
      (cancel-timer tedit--cursor-timer)
      (setq tedit--cursor-timer nil))))

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
          (with-demoted-errors "Error in tedit-no-save-buffer-hook: %s"
            (run-hooks 'tedit-no-save-buffer-hook))
          (setq-local tedit--saved-tick current-tick)))))
  ;; Toggle the mode
  (read-only-mode 'toggle)
  ;; FORCE cursor update for manual toggles immediately (don't wait for timer)
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
  :group 'tedit
  :lighter " TEdit"
  :keymap tedit-mode-map
  (if tedit-mode
      (progn
        (tedit--update-keymap)
        (tedit--cache-cursor-color)
        (tedit--manage-timer)
        ;; Bind strictly to human window/buffer focus changes
        (add-hook 'window-selection-change-functions #'tedit--focus-handler)
        (add-hook 'window-buffer-change-functions #'tedit--focus-handler)
        (advice-add 'enable-theme :after #'tedit--cache-cursor-color)
        ;; Initialize currently focused window immediately
        (tedit--focus-handler))
    ;; DISABLE
    (tedit--manage-timer)
    ;; set back to theme's cursor color when the mode is disabled.
    (set-cursor-color (or tedit--theme-cursor-color "black"))
    (remove-hook 'window-selection-change-functions #'tedit--focus-handler)
    (remove-hook 'window-buffer-change-functions #'tedit--focus-handler)
    (advice-remove 'enable-theme #'tedit--cache-cursor-color)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (tedit--cleanup-buffer)))))

(provide 'tedit)

;;; tedit.el ends here
