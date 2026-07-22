;;; tedit.el --- Toggle read-only mode in buffers   -*- lexical-binding: t -*-

;; Author: IceAsteroid
;; Keywords: convenience, files
;; Homepage: https://github.com/IceAsteroid/toggle-edit
;; Version: 0.5

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
;; This global minor mode manages read-only status and a "soft-lock"
;; mode described below intelligently across buffers.

;; State changes strictly evaluate selected window buffer, so called
;; "on-focus", to protect background buffers and async processes from
;; being prematurely locked to write to the buffer they need to.

;; This mode's primary goal is to prevent human mistyping, rather than
;; adding obstacles for elisp code to write to buffers.

;; "hard-lock" means locking via read-only; "soft-lock" means locking
;; via keymap of `tedit-soft-lock-special--mode' to block all user
;; input.  The former is good for user editing buffers; the latter is
;; good for special buffers that elisp code writes to, as this method
;; doesn't block elisp to modify content.

;; It's recommended to bind the manual toggle command
;; `tedit-save-buffer-toggle' on a key combo like "C-`", instead of
;; overriding read-only-mode's "C-x C-q", to still be able to
;; conveniently toggle hard-lock when some settings are set and you
;; cannot unlock hard-lock by `tedit-save-buffer-toggle'.

;;; Bugs
;; 1. Fixed.  When a file is write-protected, and the mode of
;; the buffer visiting it is managed by `soft-lock' in tedit, the
;; read-only mode will be turned off unexpectedly, and no soft-lock
;; enabled either.

;;; TODO
;; 1. Restore to hook the functions for corfu and company in
;; `read-only-mode-hook' only when one of these mode is turned on
;; respectively, instead of hooking the functions in
;; `read-only-mode-hook' for every buffer.

;; 2. Done.  Implement the feature for
;; `tedit--mode-initially-hard-locked-p', to properly cancel
;; `tedit-mode's lock when the mode is turning off.

;; 3. Done.  Implement the feature for
;; `tedit-apply-locks-on-mode-change', to whether enable hard-lock
;; or soft-lock depending on user settings when a selected buffer is
;; changed its major mode.

;; 4. Done.  Implement its feature of
;; `tedit-toggle-inhibit-unmanaged-buffers', to not toggle read-only mode when
;; a buffer is not managed by tedit.

;; 5. Done.  Add a variable `tedit-soft-lock-toggle-method',
;; to let user choose whether to be able to toggle hard-lock on
;; soft-locked buffers, or to toggle soft-lock instead, or do nothing.

;; 6. Done.  If a buffer is initially read-only, but specified
;; to managed by soft-lock in tedit, what should we handle it?

;; 6.1. Done.  If a buffer is not managed by tedit, either by hard or
;; soft lock (either excluded or not specified), when it is read only
;; and changes to another major mode that is managed by soft lock, the
;; buffer now is enabled hard and soft lock.  Because of our new
;; toggle functionality, only soft lock can be toggled, the buffer
;; stays hard lock.

;; 7. Done.  Add a variable
;; `tedit-toggle-inhibit-if-file-initially-hard-locked' and its feature to
;; inhibit `tedit-save-buffer-toggle' to toggle hard-lock, if the file
;; is initially visited with read-only enabled.

;; 8. Done.  Fix ia-popper-modified conflict with this mode, when this
;; source file is compiling at Emacs startup.  Popper freezes the
;; scratch buffer and makes it unable to load the elisp mode.

;; 9. Done.  Caused by a newly implemented feature:
;; `tedit-clear-hard-lock-before-mode-change'.  If a file visited is
;; not write-protected, which means it is not opened with read-only
;; enabled, but manually toggled on with read-only, now when I change
;; the buffer to a new major mode that is gonna be managed by tedit's
;; soft lock, the buffer now is both soft and hard locked, which
;; doesn't seem favorable to me.  There must be an option to tweak
;; this behavior when `tedit-clear-hard-lock-before-mode-change' is
;; nil.

;; 9.1 Done.  Added `tedit-soft-lock-existing-hard-lock-method' and
;; its feature to achieve this.

;; 10. Bug: Cursor color update and blinking aborted when C-g cancels the
;; minibuffer and returns to the selected window.

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

;;; New variables waiting to implement their features.
(defcustom tedit-clear-hard-lock-before-mode-change nil
  "Determine whether to strip hard locks before a major mode change.

If t, strip the read-only lock before the major mode changes, PROVIDED
the file is natively writable AND tedit was the one that applied the lock.
This allows the buffer to enter the new mode unlocked so `tedit' can
re-evaluate it cleanly based on the new mode's rules.

If nil, do not strip the lock. If the buffer is locked (manually or by
tedit), it will remain locked in the new mode. If it is unlocked, it
will remain unlocked, and `tedit' will evaluate the new mode based on
its rules."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-soft-lock-existing-hard-lock-method 'dual
  "How to initialize soft-lock if the buffer is already hard-locked.

This occurs when a manual lock persists before a major mode change into
a soft-locked major mode, or when visiting native read-only files.

'dual       (Default) Apply the soft-lock on top of the existing hard-lock.
            Users can change the `tedit-save-buffer-toggle's behavior via
            `tedit-soft-lock-toggle-method' and the native `C-x C-q' command.
'override   Automatically strip the persisting manual hard-lock and apply the
            soft-lock. (OS-level write-protection logged by
            `tedit--file-initially-hard-locked-p' is never stripped)."
  :type '(choice (const :tag "Allow Dual Locking (Apply soft-lock on top)" dual)
                 (const :tag "Override manual hard-lock with soft-lock" override))
  :group 'tedit)


;;; Inclusion Rules (Whitelists)

(defcustom tedit-hard-lock-buffer-regexps '()
  "Regexps for buffer names where `tedit-mode' should enforce read-only status."
  :type '(repeat regexp)
  :group 'tedit)

(defcustom tedit-hard-lock-derived-mode-list '()
  "List of derived modes where `tedit-mode' should enforce read-only status."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-hard-lock-major-mode-list '()
  "List of specific major modes where `tedit-mode' should enforce read-only status."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-inhibit-commands '()
  "List of commands during which `tedit-mode' will not automatically enforce locks.

This prevents multi-file refactoring or mass search-and-replace operations
from being interrupted by automatic read-only locks."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-soft-lock-buffer-regexps '()
  "List of regexps for background data buffers that should prevent human typing.
but MUST NOT use strict `read-only-mode` so background Elisp can still write."
  :type '(repeat regexp)
  :group 'tedit)

(defcustom tedit-soft-lock-derived-mode-list '()
  "List of modes for background data buffers that should prevent human typing.
but MUST NOT use strict `read-only-mode` so background Elisp can still write.

Should not set such as `'special-mode', as many modes derived from this have
custom keybindings.

Since, modes listed here are tested by `derived-mode-p', use
`tedit-soft-lock-major-mode-list' instead for modes regardless of their
derived modes."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-soft-lock-major-mode-list '()
  "List of modes for background data buffers that should prevent human typing.
but MUST NOT use strict `read-only-mode` so background Elisp can still write.

Modes listed here are compared with `major-mode', instead of tested by
`derived-mode-p', which is nice if you only want a mode but not its
derived mode. For modes and their derived modes, use
`tedit-soft-lock-derived-mode-list'."
  :type '(repeat symbol)
  :group 'tedit)

;;; Exclusion Rules (Blacklists)

(defcustom tedit-hard-lock-ignore-mode-list '()
  "Modes that should NEVER be toggled hard-lock, overriding the enable lists."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-hard-lock-ignore-buffer-regexps '()
  "Regexps for buffer names that should NEVER be toggled hard-lock.
By default, this ignores all hidden/internal buffers starting with `*`."
  :type '(repeat regexp)
  :group 'tedit)

(defcustom tedit-soft-lock-ignore-mode-list '()
  "Modes that should NEVER be toggled soft-lock, overriding the enable lists."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-soft-lock-ignore-buffer-regexps '()
  "Regexps for buffer names that should NEVER be toggled soft-lock."
  :type '(repeat regexp)
  :group 'tedit)

(defcustom tedit-toggle-inhibit-if-file-initially-hard-locked nil
  "Inhibit manual unlocking of files that were natively write-protected.
When non-nil, `tedit-save-buffer-toggle' will refuse to disable the
hard-lock if the file was read-only at the time it was opened."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-toggle-inhibit-unmanaged-buffers t
  "Do not toggle hard-lock for buffers that are not managed by `tedit-mode'."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-toggle-always-allow-mode-list '()
  "Modes that should ignore `tedit-toggle-inhibit-unmanaged-buffers'."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-toggle-always-allow-buffer-regexps '()
  "Regexps for buffer names that should ignore `tedit-toggle-inhibit-unmanaged-buffers'."
  :type '(repeat regexp)
  :group 'tedit)

;;; Behavior Settings

(defcustom tedit-always-lock-on-switch nil
  "If non-nil, reset buffers to read-only EVERY time you switch to their window.
If nil, read-only is only AUTO applied the FIRST time the buffer is viewed."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-relock-inhibit-from-deep-minibuffer t
  "If non-nil, inhibit lock evaluation if returning from a recursive minibuffer.

When non-nil, executing commands that open temporary buffers from within
the minibuffer (and then returning to the selected window) will not
trigger `tedit's evaluation engine, Useful when
`tedit-always-lock-on-switch' is set to non-nil.

This is useful when not using a completion system like `vertico-mode',
where you select the \"*completion*\" window and back to the selected
window."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-relock-inhibit-from-dedicated-window nil
  "If non-nil, inhibit lock evaluation if returning from a dedicated window.

When non-nil, switching focus to a dedicated window (like a file tree or
side-panel) and returning to your main buffer will NOT trigger the
evaluation engine.  Both soft and hard locks will remain exactly as you
left them.

Useful when `tedit-always-lock-on-switch's is set to non-nil."
  :type 'boolean
  :group 'tedit)

;; Problem: What if return from a buffer in the same window instead of
;; another window.
(defcustom tedit-relock-inhibit-from-mode-list '()
  "List of major modes to inhibit lock evaluation if returning from such mode.

If you switch focus to a window buffer running one of these modes (e.g.,
`treemacs-mode` or `magit-status-mode`), returning to your previous
buffer will not trigger `tedit' to re-evaluate its soft or hard locks.

Useful when `tedit-always-lock-on-switch' is set to non-nil."
  :type '(repeat symbol)
  :group 'tedit)

(defcustom tedit-relock-inhibit-from-buffer-regexps '()
  "Regexps for buffer names to inhibit lock evaluation returning from such buffer.

If you switch focus to a buffer matching these patterns (e.g.,
\"^\\\\*Calc\"), returning to your previous buffer will not trigger
`tedit' to re-evaluate its soft or hard locks.

Useful when `tedit-always-lock-on-switch' is set to non-nil."
  :type '(repeat string)
  :group 'tedit)

(defcustom tedit-toggle-save-on-toggle t
  "If non-nil, save the buffer when `tedit-save-buffer-toggle' runs."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-toggle-inhibit-save-buffer-regexps '()
  "List of regexps for buffers where saving should NOT be triggered."
  :type '(repeat regexp)
  :group 'tedit)

(defcustom tedit-toggle-key "C-`"
  "Key sequence to toggle `tedit-mode' (save and toggle read-only)."
  :type 'string
  :group 'tedit)

(defcustom tedit-cursor-color-when-lock "red2"
  "The default cursor color when buffer is on hard/soft lock."
  :type 'string
  :group 'tedit)

(defcustom tedit-cursor-timer-delay 0.1
  "Seconds of idle time before checks and updates of cursor color for `tedit-mode'."
  :type 'number
  :group 'tedit)

(defcustom tedit-apply-locks-on-mode-change t
  "Enable soft/hard look when the selected buffer is changed of its major mode.

If it's a mode specified in `tedit-hard-lock-buffer-regexps',
`tedit-hard-lock-derived-mode-list', `tedit-hard-lock-major-mode-list',
enable hard lock.

If it's a mode specified in `tedit-soft-lock-buffer-regexps',
`tedit-soft-lock-derived-mode-list', `tedit-hard-lock-major-mode-list', enable
soft lock."
  :type 'boolean
  :group 'tedit)

(defcustom tedit-restore-initial-unmanaged-lock-states '(hard-lock soft-lock)
  "Restore lock state before tedit manages buffers when `tedit-mode' exits.

'hard-lock means to restore read-only state.

'soft-lock means to disable `tedit-soft-lock-special--mode' that hijacks
user input in buffers that have the mode enabled.

If 'soft-lock is not specified, DO NO DO THIS unless you know what you
are doing, the buffers that enable this mode will not disable it when
`tedit-mode' is turning off.

If the list is nil, it means to not restore both locks for buffers."
  :type '(set (const :tag "Soft Lock" soft-lock)
              (const :tag "Hard Lock" hard-lock))
  :options '(hard-lock soft-lock))

(defcustom tedit-soft-lock-toggle-method 'soft-lock
  "Choose to enable toggle on `tedit-soft-lock-special--mode' buffers.

'soft-lock to let `tedit-save-buffer-toggle' toggle soft lock only.

'hard-lock to let `tedit-save-buffer-toggle' toggle hard lock only(often
useless if user has no additional tweaking).

'both-lock to let `tedit-save-buffer-toggle' toggle unlock on both soft
and hard lock(dangerous as it unlocks both hard and soft lock if hard
lock is enforced when file is visited)."
  :type '(choice (const :tag "Soft Lock" soft-lock)
                 (const :tag "Hard Lock" hard-lock)
                 (const :tag "Both Lock" both-lock))
  :options '(soft-lock soft-lock))

;;; Internal Variables

(defvar tedit--theme-cursor-color nil
  "Cache for the current theme's cursor color.")

(defvar tedit--saved-tick nil
  "Tracks the buffer modification tick to prevent redundant hook execution.")

(defvar tedit-toggle-inhibit-save-buffer-hook nil
  "Hook run when `tedit-save-buffer-toggle' is called on an ignored buffer.

An ignored buffer is inhibited to trigger `basic-save-buffer' in
`tedit-save-buffer-toggle' or is a buffer not visiting a file.

Such buffers can be configured in
`tedit-toggle-inhibit-save-buffer-regexps'.")

(defvar tedit-mode-map (make-sparse-keymap)
  "Keymap for `tedit-mode'.")

(defvar-local tedit--new-buffer-evaluated-p nil
  "Tracks if the buffer has already been evaluated by tedit.
Used to check if a buffer is evaluated by tedit.

Some features check this state to confirm if a buffer is newly opened or
changed major mode and do stuff before instant evaluation to whether
auto-enable hard/soft lock.")

(defvar-local tedit--hard-locked-by-tedit-p nil
  "Non-nil if `tedit-mode' has automatically applied hard-lock to this buffer.

Ensures we do not accidentally unlock native read-only files on blur.

This state is updated by tedit's auto hard lock, not by user manually
executes `tedit-save-buffer-toggle' nor `read-only-mode' to toggle
hard-lock.")

(defvar-local tedit--file-initially-hard-locked-p nil
  "The native `buffer-read-only` state when the file was first opened.

This protects OS-level permissions from being stripped during mode
changes.

Regardless of tedit respecting major modes' default read only
state when switching modes.")
(put 'tedit--file-initially-hard-locked-p 'permanent-local t)

(defvar-local tedit--mode-initially-hard-locked-p nil
  "Record the new buffer state that has turned on read-only or not.
Before `tedit-mode' starts handling read-only.")

(defvar tedit--last-focused-buffer nil
  "Tracks the last non-minibuffer buffer to prevent relocking on minibuffer exits.")

(defvar-local tedit--temporarily-unlocked-by-blur-p nil
  "Non-nil if `tedit--focus-out' temporarily removed read-only in the background.
This ensures the lock is safely restored when the buffer regains focus.")
;; Prevent the variable killed by other elisp to change mode when a
;; buffer is unfocused.
(put 'tedit--temporarily-unlocked-by-blur-p 'permanent-local t)

(defvar tedit--cursor-timer nil
  "The idle timer object responsible for cursor visual sync.")

;; it is set in `tedit--focus-in' runs. not sure if this variable
;; should be used in other parts. Looks semantically contradictory to
;; `tedit--hard-locked-by-tedit-p'.
(defvar-local tedit--should-enable-hard-lock-p-cached nil
  "Store the result of `tedit--should-enable-hard-lock-p'.
Cache for performance without invoked multiple times.")

;; it now is set everytime when `tedit--focus-in' runs. not sure if
;; this variable should be used in other parts.
(defvar-local tedit--should-enable-soft-lock-p-cached nil
  "Store the result of `tedit--should-enable-soft-lock-p'.
Cache for performance without invoked multiple times.")

;;; Core Logic

(defun tedit--update-keymap ()
  "Bind the toggle key in the minor mode map."
  (define-key tedit-mode-map (kbd tedit-toggle-key) #'tedit-save-buffer-toggle))

(defun tedit--match-rules-p (regexps exact-modes derived-modes)
  "Return t if the current buffer matches the given REGEXPS or MODES.
This centralizes the checking logic to keep focus handlers clean."
  (or (and regexps
           (seq-some (lambda (re) (string-match-p re (buffer-name))) regexps))
      (and exact-modes
           (memq major-mode exact-modes))
      (and derived-modes
           ;; (derived-mode-p derived-modes)
           ;; compatible for old Emacs versions of `derived-mode-p'.
           (seq-some (lambda (m) (derived-mode-p m)) derived-modes))))

(defun tedit--should-enable-hard-lock-p ()
  "Return t if the buffer should be hard-locked based on ignore and enable lists."
  (and (not (tedit--match-rules-p tedit-hard-lock-ignore-buffer-regexps
                                  nil
                                  tedit-hard-lock-ignore-mode-list))
       (tedit--match-rules-p tedit-hard-lock-buffer-regexps
                             tedit-hard-lock-major-mode-list
                             tedit-hard-lock-derived-mode-list)))

(defun tedit--should-enable-soft-lock-p ()
  "Return t if the buffer should be soft-locked based on ignore and enable lists."
  (and (not (tedit--match-rules-p tedit-soft-lock-ignore-buffer-regexps
                                  nil
                                  tedit-soft-lock-ignore-mode-list))
       (tedit--match-rules-p tedit-soft-lock-buffer-regexps
                             tedit-soft-lock-major-mode-list
                             tedit-soft-lock-derived-mode-list)))

(defun tedit--focus-out (old-buf new-buf)
  "Unlock OLD-BUF when switching to NEW-BUF, if safe to do so."
  (when (and old-buf
             (buffer-live-p old-buf)
             (not (eq old-buf new-buf))
             (not (minibufferp new-buf)))
    (with-current-buffer old-buf
      ;; Drop the hard-lock temporarily if:
      ;; 1. tedit explicitly owns it (hard-lock managed).
      ;; 2. OR it is a manual lock on a soft-lock managed buffer (and NOT an OS lock).
      (when (and buffer-read-only
                 (or tedit--hard-locked-by-tedit-p
                     (and tedit--should-enable-soft-lock-p-cached
                          (not tedit--file-initially-hard-locked-p))))
        (setq-local tedit--temporarily-unlocked-by-blur-p t)
        (read-only-mode -1)))))

(defun tedit--focus-in (buf)
  "Apply appropriate locks (soft or hard lock) to BUF."
  (with-current-buffer buf
    (let ((switched-p (not (eq buf tedit--last-focused-buffer)))
          ;; Guard clause: Is this the first time tedit is evaluating this mode/buffer?
          (first-eval-p (not tedit--new-buffer-evaluated-p)))
      ;; Record initial states
      (unless (local-variable-p 'tedit--file-initially-hard-locked-p)
        (setq-local tedit--file-initially-hard-locked-p buffer-read-only))
      (unless tedit--new-buffer-evaluated-p
        (setq-local tedit--mode-initially-hard-locked-p buffer-read-only))
      ;; STEP 1: Restore the background state
      (when tedit--temporarily-unlocked-by-blur-p
        (setq-local tedit--temporarily-unlocked-by-blur-p nil)
        (unless buffer-read-only
          (read-only-mode +1)))
      ;; STEP 2: The Core Rule Engine
      (when (or first-eval-p
                (and tedit-always-lock-on-switch switched-p))
        (setq-local tedit--new-buffer-evaluated-p t)
        (cond
         ;; PRIORITY 0: Conflict Resolution (ONLY EXECUTED ON FIRST EVALUATION)
         ;; Handles hard-locks inherited from file visits or previous major modes.
         ((and first-eval-p (tedit--should-enable-soft-lock-p) buffer-read-only)
          (setq tedit--should-enable-soft-lock-p-cached t)
          ;; Reason to put soft-lock
          (if (eq tedit-soft-lock-existing-hard-lock-method 'override)
              (if tedit--file-initially-hard-locked-p
                  ;; EDGE CASE: Never strip an OS-level lock. Fallback safely to 'dual.
                  (unless tedit-soft-lock-special--mode
                    (tedit-soft-lock-special--mode +1))
                ;; Safely strip the manual lock and apply soft-lock
                (read-only-mode -1)
                (unless tedit-soft-lock-special--mode
                  (tedit-soft-lock-special--mode +1)))
            ;; Fallback / Default ('dual): Apply soft-lock on top of hard-lock
            (unless tedit-soft-lock-special--mode
              (tedit-soft-lock-special--mode +1))))
         ;; Priority 1: Normal Soft Lock
         ((tedit--should-enable-soft-lock-p)
          (setq tedit--should-enable-soft-lock-p-cached t)
          (unless tedit-soft-lock-special--mode
            (tedit-soft-lock-special--mode +1)))
         ;; Priority 2: Normal Hard Lock
         ((tedit--should-enable-hard-lock-p)
          (setq tedit--should-enable-hard-lock-p-cached t)
          (unless buffer-read-only
            (read-only-mode +1)
            (setq tedit--hard-locked-by-tedit-p t)
            (add-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly nil t)
            (add-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly nil t))))))))

(defun tedit--focus-handler (&rest _)
  "Evaluate read-only state exactly when a window or buffer receives user focus."
  (let ((buf (window-buffer (selected-window))))
    ;; 1. FOCUS OUT: Clean up the previous buffer.
    (tedit--focus-out tedit--last-focused-buffer buf)
    ;; 2. GUARD CLAUSES: Do nothing if refactoring, in minibuffer, or mid-mode transition.
    ;; check `delay-mode-hooks' to skip mode transition for derived
    ;; modes that a derived mode calls its parent mode before itself.
    (unless (or (bound-and-true-p delay-mode-hooks)
                (memq this-command tedit-inhibit-commands)
                (minibufferp buf)
                (and tedit-relock-inhibit-from-deep-minibuffer (> (minibuffer-depth) 0)))
      ;; 3. FOCUS IN: Evaluate and lock the new buffer
      (tedit--focus-in buf)
      ;; 4. UPDATE STATE: Track this buffer for the next focus shift
      (unless (or (and tedit-relock-inhibit-from-dedicated-window (window-dedicated-p (selected-window)))
                  (tedit--match-rules-p tedit-relock-inhibit-from-buffer-regexps
                                        nil
                                        tedit-relock-inhibit-from-mode-list))
        (setq tedit--last-focused-buffer buf)))))

(defun tedit--before-major-mode-change ()
  "Tear down tedit locks BEFORE the major mode wipes local variables."
  (when (and tedit-mode tedit-apply-locks-on-mode-change)
    ;; ALWAYS tear down soft-lock.
    ;; A new mode should never inherit a hijacked keyboard map.
    (when tedit-soft-lock-special--mode
      (tedit-soft-lock-special--mode -1))
    ;; Hard-lock handling based on the new user option
    (when tedit-clear-hard-lock-before-mode-change
      (when (and buffer-read-only
                 tedit--new-buffer-evaluated-p
                 ;; Bug fix: Ensure tedit actually owns this lock
                 tedit--hard-locked-by-tedit-p
                 ;; Bug fix: Don't strip OS-level write protection
                 (not tedit--file-initially-hard-locked-p))
        (read-only-mode -1)))
    ;; Clean up transient variable before the mode wipe
    (when tedit--hard-locked-by-tedit-p
      (setq-local tedit--hard-locked-by-tedit-p nil))))

(defun tedit--after-major-mode-change ()
  "Re-evaluate the buffer AFTER the new major mode has initialized.

Only evaluate by `tedit--focus-in' on a mode switch if the buffer is
DISPLAYED in the selected buffer, to prevent a background buffer gets
hard lock that causes write failures for elisp to the buffer.

This may not run when a mode switch as the switch could be run by elisp
when the buffer is at the background.  But `tedit--focus-in' will run
anyway when it is brought back displayed in the selected window."
  (when (and tedit-mode
             tedit-apply-locks-on-mode-change
             (eq (current-buffer) (window-buffer (selected-window))))
    ;; Emacs already wiped `tedit--new-buffer-evaluated-p` to nil during initialization.
    ;; The buffer is a clean slate. Evaluate it and record the new native state.
    (tedit--focus-in (current-buffer))))

(defun tedit--cleanup-buffer ()
  "Clean up `tedit-mode' modifications from the current buffer."
  (remove-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly t)
  (remove-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly t)

  (let* ((clean-soft-p (memq 'soft-lock tedit-restore-initial-unmanaged-lock-states))
         (clean-hard-p (memq 'hard-lock tedit-restore-initial-unmanaged-lock-states)))
    ;; TODO: Thinking if checking `tedit--new-buffer-evaluated-p' is
    ;; completely unnecessary, since all buffers will be evaluated
    ;; while `tedit-mode' is on.
    (when tedit--new-buffer-evaluated-p
      (when (and clean-soft-p tedit-soft-lock-special--mode)
        (tedit-soft-lock-special--mode -1))
      ;; Evaluate state restoration only if tedit previously processed this buffer
      (when clean-hard-p
        ;; Case 1: Buffer was naturally read-only, but is currently writable. Restore lock.
        (when (and tedit--mode-initially-hard-locked-p
                   (not buffer-read-only))
          (read-only-mode +1))
        ;; Case 2: Buffer was naturally writable, but tedit hard-locked it. Remove lock.
        (when (and (not tedit--mode-initially-hard-locked-p)
                   tedit--hard-locked-by-tedit-p)
          (read-only-mode -1)))))

  ;; Clear all local tracking variables cleanly
  (setq-local tedit--new-buffer-evaluated-p nil)
  (setq-local tedit--should-enable-hard-lock-p-cached nil)
  (setq-local tedit--should-enable-soft-lock-p-cached nil)
  (setq-local tedit--hard-locked-by-tedit-p nil)
  (setq-local tedit--temporarily-unlocked-by-blur-p nil))

;;; Cursor Management

(defun tedit--cache-cursor-color (&rest _)
  "Store the default cursor color from the current face."
  (when (display-graphic-p)
    (let ((color (face-attribute 'cursor :background)))
      (when (stringp color)
        (setq tedit--theme-cursor-color color)))))

(defun tedit--update-cursor-color ()
  "Update cursor color based on read-only status of the current buffer."
  (when tedit-mode
    (unless tedit--theme-cursor-color
      (tedit--cache-cursor-color))
    (set-cursor-color
     ;; FIX: Check for the soft-lock mode as well!
     (if (or buffer-read-only tedit-soft-lock-special--mode)
         tedit-cursor-color-when-lock
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
  ;; 1. Handle saving if the buffer is currently writable
  (unless buffer-read-only
    (if (and (buffer-file-name)
             tedit-toggle-save-on-toggle
             (not (tedit--match-rules-p tedit-toggle-inhibit-save-buffer-regexps nil nil)))
        (basic-save-buffer)
      (let ((current-tick (buffer-chars-modified-tick)))
        (unless (eq tedit--saved-tick current-tick)
          (with-demoted-errors "Error in tedit-toggle-inhibit-save-buffer-hook: %s"
            (run-hooks 'tedit-toggle-inhibit-save-buffer-hook))
          (setq-local tedit--saved-tick current-tick)))))
  ;; 2. Determine lock toggle behavior based on buffer management state
  (cond
   ;; --- A. Buffers managed by tedit soft-lock ---
   (tedit--should-enable-soft-lock-p-cached
    (cond
     ((eq tedit-soft-lock-toggle-method 'soft-lock)
      (tedit-soft-lock-special--mode 'toggle))
     ((eq tedit-soft-lock-toggle-method 'hard-lock)
      (read-only-mode 'toggle))
     ((eq tedit-soft-lock-toggle-method 'both-lock)
      (if (and tedit-toggle-inhibit-if-file-initially-hard-locked
               tedit--file-initially-hard-locked-p)
          (progn
            (tedit-soft-lock-special--mode 'toggle)
            (message "Toggling hard-lock is inhibited (file visited as read-only)."))
        (if (or tedit-soft-lock-special--mode buffer-read-only)
            (progn
              (tedit-soft-lock-special--mode -1)
              (read-only-mode -1))
          (tedit-soft-lock-special--mode +1)
          (read-only-mode +1)))) ;; FIX: Removed invalid 'toggle argument
     (t
      (user-error "Invalid value for `tedit-soft-lock-toggle-method`."))))
   ;; --- B. Buffers managed by tedit hard-lock ---
   (tedit--should-enable-hard-lock-p-cached
    (if (and tedit-toggle-inhibit-if-file-initially-hard-locked
             tedit--file-initially-hard-locked-p)
        (message "Toggling hard-lock is inhibited (file visited as read-only).")
      (read-only-mode 'toggle)))
   ;; --- C. Buffers NOT managed by tedit ---
   (t
    ;; FIX: Corrected boolean logic. If non-tedit buffers are inhibited, we only
    ;; block the toggle if the buffer does NOT match the ignore/whitelist rules.
    (if (and tedit-toggle-inhibit-unmanaged-buffers
             (not (tedit--match-rules-p tedit-toggle-always-allow-buffer-regexps
                                        nil
                                        tedit-toggle-always-allow-mode-list)))
        (message "Toggle inhibited: Buffer is not managed by tedit.")
      (if (and tedit-toggle-inhibit-if-file-initially-hard-locked
               tedit--file-initially-hard-locked-p)
          (message "Toggling hard-lock is inhibited (file visited as read-only).")
        (read-only-mode 'toggle)))))
  ;; 3. FORCE cursor update for manual toggles immediately (don't wait for timer)
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

(defvar tedit-soft-lock-map
  (let ((map (make-sparse-keymap)))
    ;; 1. Block all standard typing (letters, numbers, punctuation)
    (suppress-keymap map t)
    ;; 2. Intercept and neutralize destructive commands
    (define-key map [remap delete-char] #'ignore)
    (define-key map [remap delete-backward-char] #'ignore)
    (define-key map [remap kill-region] #'ignore)
    (define-key map [remap kill-line] #'ignore)
    (define-key map [remap kill-whole-line] #'ignore)
    (define-key map [remap yank] #'ignore)
    (define-key map [remap undo] #'ignore)
    (define-key map [remap newline] #'ignore)
    (define-key map (kbd "RET") #'ignore)
    (define-key map (kbd "<return>") #'ignore)
    map)
  "Keymap that steals input to prevent typing, leaving the buffer writable for Elisp.")

(define-minor-mode tedit-soft-lock-special--mode
  "Local minir mode that blocks user input for particular buffers.
For particular buffers in `tedit-soft-lock-buffer-regexps' and special buffers.

Block user input via a keymap instead of locking them in read-only.  For
cases that some elisp code needs to write to these buffers."
  :group 'tedit
  :lighter " TEditS"
  :keymap tedit-soft-lock-map)

;; If a background script uses (find-file-noselect "file.nonono"),
;; it will open the file in fundamental-mode without drawing a
;; window. But it's safe, because `tedit--after-major-mode-change' has
;; the strict guard clause:
;; `(eq (current-buffer) (window-buffer (selected-window)))'
(defun tedit--after-fundamental-mode-advice (&rest _)
  "Ensure tedit evaluates fundamental-mode, unless it's a parent mode transition."
  ;; If delay-mode-hooks is non-nil, a child mode is currently initializing.
  ;; We MUST abort and let the child mode's after-hook handle the evaluation.
  (unless (bound-and-true-p delay-mode-hooks)
    (tedit--after-major-mode-change)))

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
        ;; Bind strictly to human window/buffer focus changes.
        (add-hook 'window-selection-change-functions #'tedit--focus-handler)
        (add-hook 'window-buffer-change-functions #'tedit--focus-handler)
        (add-hook 'change-major-mode-hook #'tedit--before-major-mode-change)
        (add-hook 'after-change-major-mode-hook #'tedit--after-major-mode-change)
        ;; catch a buffer switches to fundamental mode that doesn't run any hooks.
        (advice-add 'fundamental-mode :after #'tedit--after-fundamental-mode-advice)
        (advice-add 'enable-theme :after #'tedit--cache-cursor-color)
        ;; catch when user disables theme back to default.
        (advice-add 'disable-theme :after #'tedit--cache-cursor-color)
        ;; Initialize currently focused window immediately.
        (tedit--focus-handler))
    ;; DISABLE
    (tedit--manage-timer)
    (set-cursor-color (or tedit--theme-cursor-color "black"))
    (remove-hook 'window-selection-change-functions #'tedit--focus-handler)
    (remove-hook 'window-buffer-change-functions #'tedit--focus-handler)
    (remove-hook 'change-major-mode-hook #'tedit--before-major-mode-change)
    (remove-hook 'after-change-major-mode-hook #'tedit--after-major-mode-change)
    (advice-remove 'fundamental-mode #'tedit--after-fundamental-mode-advice)
    (advice-remove 'enable-theme #'tedit--cache-cursor-color)
    (advice-remove 'disable-theme #'tedit--cache-cursor-color)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        ;; clear only managed by tedit to prevent overhead when
        ;; buffers are excessive.
        (when tedit--new-buffer-evaluated-p
          (tedit--cleanup-buffer))))))


(provide 'tedit)

;;; tedit.el ends here
