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

;; Temporary Overrides vs Permanent Intent
;;
;; When `tedit-always-lock-on-switch' is enabled, the native Emacs
;; command `read-only-mode' (C-x C-q) acts as a *temporary
;; override*. It will instantly lock/unlock the buffer, allowing you
;; to bypass `tedit's strict rules or inhibition lists. However, on
;; the next focus out/in, `tedit' will strictly re-evaluate the buffer
;; and snap it back to its configured rule.
;; To permanently cycle a buffer's lock state and update the engine's
;; memory, you MUST use `tedit-save-buffer-toggle' instead.
;; When a file visisted in a buffer has changed its write permission,
;; you have to manually run `revert-buffer' or turn on
;; `auto-revert-mode' to have it triggered its hook to update tedit to
;; not allow or block `tedit-save-buffer-toggle' to toggle hard lock.

;; when `tedit-clear-hard-lock-before-mode-change' is nil, and if a
;; new mode to switch for a buffer is poorly written that does not
;; allow hard-lock state and has to modify the buffer during its mode
;; initialization.  The user needs to put this in their own config
;; file to fix.
;;
;; (advice-add 'fragile-data-mode :around
;;             (lambda (orig-fun &rest args)
;;               (let ((inhibit-read-only t)) ;; Force Emacs to ignore the lock temporarily
;;                 (apply orig-fun args))))

;; File System Write Protection (Eager Native Capture)
;;
;; `tedit' is designed to never strip native file system write protection.
;; It captures the file's initial read-only state upon the buffer's very
;; first evaluation (typically `after-change-major-mode-hook').
;;
;; Why read `buffer-read-only' instead of `file-writable-p'?  We do
;; this to inherit the exact outcome of Emacs's native `find-file'
;; routine. A file might be strictly read-only on the local file
;; system, but writable virtually via Emacs (e.g., opened via TRAMP
;; `/sudo::', or checked out dynamically via VC hooks). By reading
;; Emacs's native buffer state rather than hitting the file system
;; directly, we inherit all of Emacs's complex file handlers for free.
;;
;; Why Eager Capture instead of Lazy Focus
;; Capture?  Even for background buffers (e.g., `find-file-noselect'),
;; the major mode hook runs synchronously before the command loop
;; yields. This guarantees we capture Emacs's true native state
;; *before* any rogue background Elisp scripts have a chance to tamper
;; with `buffer-read-only', preventing race conditions.
;;
;; It also guarantees the captured state for native read-only is free
;; from manual human overrides.

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

dual        (Default) Apply the soft-lock on top of the existing hard-lock.
            Users can change the `tedit-save-buffer-toggle's behavior via
            `tedit-soft-lock-toggle-method' and the native \\[read-only-mode]
            (`read-only-mode') command.

override    Automatically strip the persisting manual hard-lock and apply the
            soft-lock.  (File system write protection logged by
            `tedit--native-read-only-p' is never stripped)."
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
If nil, read-only is only AUTO applied the FIRST time the buffer is viewed.

When set to t, you can use 'C-x C-q' or `read-only-mode' to temporarily
toggle hard-lock if the file is prohibited to toggle with
`tedit-save-buffer-toggle' by tedit. However, the next focus out/in will
strictly apply to the rules."
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
  :options '(soft-lock hard-lock both-lock))

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

(defvar tedit--last-focused-buffer nil
  "Tracks the last non-minibuffer buffer to prevent relocking on minibuffer exits.")

(defvar tedit--cursor-timer nil
  "The idle timer object responsible for cursor visual sync.")

(defvar-local tedit--native-read-only-p nil
  "The native `buffer-read-only' state when the file was first opened.

This prevents `tedit' from accidentally unlocking a buffer that visits
a natively write-protected file in the file system.  It is strictly
populated upon the buffer's first evaluation (typically during major
mode initialization).

See \"File System Write Protection\" in commentary for architecture notes.")
(put 'tedit--native-read-only-p 'permanent-local t)

(defvar-local tedit--intended-state nil
"The saved rule or explicit user intent for this buffer's lock state.

This variable stores the expected state that `tedit--reconcile' applies.

Possible values:
  'hard      - Enforce `buffer-read-only'.
  'soft      - Enforce `tedit-soft-lock-special--mode'.
  'dual      - Enforce both locks simultaneously.
  'none      - The buffer was explicitly toggled unlocked via
               `tedit-save-buffer-toggle'.  This prevents `tedit' from
               re-locking the buffer when switching windows, unless
               `tedit-always-lock-on-switch' is non-nil.
  'unmanaged - The buffer matches no base rules.  `tedit' ignores it.
  nil        - Unevaluated.  The base rules will be calculated
               during the next evaluation.")
(put 'tedit--intended-state 'permanent-local t)

(defvar-local tedit--needs-re-evaluation nil
  "Flag indicating the buffer needs its rules re-evaluated on next focus in.")
(put 'tedit--needs-re-evaluation 'permanent-local t)

;;; Core Logic

(defun tedit--update-keymap ()
  "Bind the toggle key in the minor mode map."
  (define-key tedit-mode-map (kbd tedit-toggle-key) #'tedit-save-buffer-toggle))

(defun tedit--match-rules-p (regexps exact-modes derived-modes)
  "Return t if the current buffer matches the given REGEXPS or MODES.
Evaluated in order of fastest (symbol lookup) to slowest (regex) to short-circuit."
  (or ;; 1. Fastest: Direct symbol comparison
      (and exact-modes (memq major-mode exact-modes))
      ;; 2. Fast: Walking the mode inheritance tree
      (and derived-modes (seq-some #'derived-mode-p derived-modes))
      ;; 3. Slowest: String allocation and Regex engine
      (and regexps
           (let ((bname (buffer-name))) ;; Call C-function only once
             (seq-some (lambda (re) (string-match-p re bname)) regexps)))))

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

(defun tedit--compute-effective-state (buf)
  "Calculate the lock state that BUF should have based on rules and history.

This function reads the buffer's `tedit--intended-state' to see if a
manual toggle (like 'none) is active.  If `tedit--intended-state' is
nil, this function calculates the base rule for the buffer and saves
it to `tedit--intended-state'.

It also handles edge cases, such as upgrading a 'soft rule to 'dual if
the file in file system is write-protected, or returning an unlocked
state when a managed buffer loses focus (without overwriting
`tedit--intended-state').

This function does not modify the buffer's actual read-only status.
It only returns the target state symbol for `tedit--reconcile' to apply."
  (with-current-buffer buf
    (let* ((is-focused (eq buf (window-buffer (selected-window))))
           (base-soft (tedit--should-enable-soft-lock-p))
           (base-hard (tedit--should-enable-hard-lock-p))
           (base-rule (cond (base-soft 'soft) (base-hard 'hard) (t 'unmanaged))))

      ;; 1. Initialization (Run only once per mode lifecycle)
      (when (null tedit--intended-state)
        ;; Capture the initial read-only state on first evaluation to
        ;; cache the native read-only protection state to properly
        ;; instruct tedit to respect file system write permissions.
        ;;
        ;; Architectural Note (Eager Native Capture):
        ;; We read `buffer-read-only' instead of `file-writable-p' to natively
        ;; respect TRAMP and VC hooks. Because this runs synchronously via hooks
        ;; (either during major-mode initialization or the very first window
        ;; focus), it executes before the user can manually run "C-x C-q" or
        ;; `read-only-mode' in this buffer yet.
        ;;
        ;; The `buffer-read-only' value here strictly represents Emacs's native
        ;; file system protection, captured before any rogue background Elisp
        ;; scripts have a chance to tamper with it.
        (unless (local-variable-p 'tedit--native-read-only-p)
          (setq tedit--native-read-only-p buffer-read-only))

        (setq tedit--intended-state
              (if (and buffer-read-only
                       (not tedit--native-read-only-p)
                       ;; QUIRK: Do not auto-claim an unmanaged buffer just because
                       ;; it happened to be manually locked when tedit evaluated it.
                       (not (eq base-rule 'unmanaged))
                       (not tedit-clear-hard-lock-before-mode-change))
                  ;; QUIRK (Dual vs Override): If a manual lock survives a mode transition
                  ;; into a soft-locked mode, consult user settings on whether to merge
                  ;; them ('dual) or violently overwrite the manual lock ('override).
                  (if base-soft (if (eq tedit-soft-lock-existing-hard-lock-method 'override) 'soft 'dual) 'hard)
                base-rule)))

      ;; 2. File System Write Permission Guard
      ;; Enforce hard lock for write-protected files in the file system.
      (when (and tedit--native-read-only-p
                 ;; QUIRK: NEVER hijack unmanaged buffers, even if they are OS-locked.
                 ;; Leave them entirely alone so Emacs handles them natively.
                 (not (eq tedit--intended-state 'unmanaged))
                 (not (memq tedit--intended-state '(hard dual))))
        ;; If the rules wanted a soft lock, upgrade it to dual to respect the OS.
        (setq tedit--intended-state (if (eq tedit--intended-state 'soft) 'dual 'hard)))

      ;; 3. Dynamic Focus Evaluation (The "Blur-Unlock" Feature)
      ;; If a buffer is running in the background, we drop the hard lock so async
      ;; processes can write to it, but we remember what it *should* be when focused.
      (cond
       ((not is-focused)
        (cond
         (tedit--native-read-only-p tedit--intended-state) ;; Never unlock OS files
         ((eq tedit--intended-state 'hard)
          ;; Only blur-unlock if it's a managed buffer
          (if (eq base-rule 'unmanaged) 'hard 'none))
         ((eq tedit--intended-state 'dual) 'soft) ;; Drop the hard part of a dual lock
         (t tedit--intended-state)))
       (t tedit--intended-state)))))

(defun tedit--reconcile (buf)
  "Apply the calculated lock state to BUF.

This function uses `unless' and `when' guards to avoid modifying the
buffer if it is already in the correct state, minimizing overhead during
window changes."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((target (tedit--compute-effective-state buf)))
        (pcase target
          ('hard
           (unless buffer-read-only (read-only-mode 1))
           (when tedit-soft-lock-special--mode (tedit-soft-lock-special--mode -1)))
          ('soft
           (when buffer-read-only (read-only-mode -1))
           (unless tedit-soft-lock-special--mode (tedit-soft-lock-special--mode 1)))
          ('dual
           (unless buffer-read-only (read-only-mode 1))
           (unless tedit-soft-lock-special--mode (tedit-soft-lock-special--mode 1)))
          ('none
           (when buffer-read-only (read-only-mode -1))
           (when tedit-soft-lock-special--mode (tedit-soft-lock-special--mode -1)))
          ('unmanaged
           nil))

        (when (eq buf (window-buffer (selected-window)))
          (tedit--update-cursor-color))))))

(defun tedit--focus-handler (&optional frame-or-window)
  "Apply the correct lock state when switching windows or buffers.

For buffers that are focused in and focused out when switching.

FRAME-OR-WINDOW is an argument received from a hook such as
`window-selection-change-functions' where this function is hooked."
  (let* ((win (if (windowp frame-or-window) frame-or-window (selected-window)))
         (buf (window-buffer win))
         (switched-p (not (eq tedit--last-focused-buffer buf)))
         (last-buf tedit--last-focused-buffer)
         ;; FIX: get-buffer-window is safer if we ensure the buffer is alive first
         (last-win (and last-buf (buffer-live-p last-buf) (get-buffer-window last-buf))))

    ;; GUARD CLAUSES: Do nothing if refactoring, in a recursive minibuffer,
    ;; returning from a side-panel tree view, or mid-mode transition.
    ;;
    ;; Check the previous buffer for relock-inhibit rules so returning
    ;; from a side-panel doesn't falsely bypass logic.
    ;;
    ;; If the incoming buffer matches an inhibit rule, this block aborts BEFORE
    ;; `tedit--last-focused-buffer` updates. This creates "Transient Invisibility",
    ;; perfectly preserving your manual lock states when you close the side-panel.
    (unless (or (bound-and-true-p delay-mode-hooks)
                (memq this-command tedit-inhibit-commands)
                (minibufferp buf)
                (and tedit-relock-inhibit-from-deep-minibuffer (> (minibuffer-depth) 0))
                (and last-win tedit-relock-inhibit-from-dedicated-window (window-dedicated-p last-win))

                ;; FIX: Ensure the outgoing buffer hasn't been killed by the user
                ;; before attempting to check its regex rules.
                (and last-buf
                     (buffer-live-p last-buf)
                     (with-current-buffer last-buf
                       (tedit--match-rules-p tedit-relock-inhibit-from-buffer-regexps
                                             nil
                                             tedit-relock-inhibit-from-mode-list))))

      ;; If `tedit-always-lock-on-switch' is true, clear the saved
      ;; state whenever the user switches to refocus a buffer. This
      ;; forces `tedit--reconcile' to strictly re-apply the base
      ;; rules, removing temporary unlocks for the buffer.
      ;;
      ;; QUIRK: We gate this behind `switched-p` so we ignore minor background redisplays.
      ;; Parity with Old Design: If `always-lock-on-switch` is true, we act as a
      ;; ruthless enforcer. If you switch windows, we wipe your manual toggles and
      ;; revert to the strict managed rules.
      (when switched-p
        (with-current-buffer buf
          (when (or tedit--needs-re-evaluation
                    (and tedit-always-lock-on-switch
                         (or (tedit--should-enable-hard-lock-p)
                             (tedit--should-enable-soft-lock-p))))
            (setq tedit--intended-state nil))
          (setq tedit--needs-re-evaluation nil)))

      ;; Reconcile focused-out buffer (triggers blur-unlocks for the buffer that's left)
      ;; FIX: Do not attempt to blur-unlock a buffer that was just killed.
      (when (and last-buf switched-p (buffer-live-p last-buf))
        (tedit--reconcile last-buf))

      ;; Reconcile Incoming Buffer (Restores locks for the buffer we just entered)
      (tedit--reconcile buf)

      (setq tedit--last-focused-buffer buf))))

(defun tedit--before-major-mode-change ()
  "Tear down auto-computed intent before a major mode change.
This cleans up transient locks (e.g. fundamental-mode during startup)
before the new mode takes over."
  (when tedit-mode
    (let* ((base-soft (tedit--should-enable-soft-lock-p))
           (base-hard (tedit--should-enable-hard-lock-p))
           (base-rule (cond (base-soft 'soft) (base-hard 'hard) (t 'unmanaged)))
           ;; CRITICAL FIX: Capture whether we need to physically drop the lock
           ;; BEFORE mutating `tedit--intended-state`. If we wipe intent first,
           ;; the physical unlock execution logic will fail.
           (should-clear-physical (and tedit-clear-hard-lock-before-mode-change
                                       buffer-read-only
                                       (not tedit--native-read-only-p)
                                       (memq tedit--intended-state '(hard dual)))))

      ;; QUIRK: If the user manually toggled the lock (intent != base-rule),
      ;; we usually PRESERVE their intent across the mode change.
      ;; We only clear the cache if the state was auto-computed by tedit,
      ;; OR if the user explicitly demanded locks be stripped via configuration.
      (when (or (eq tedit--intended-state base-rule)
                should-clear-physical)
        (if tedit-apply-locks-on-mode-change
            (setq tedit--intended-state nil)
          ;; Defer evaluation: flag it for the next physical focus switch!
          (setq-local tedit--needs-re-evaluation t)))

      ;; CRITICAL FIX (Parity with old design):
      ;; If the user configured hard locks to be cleared, we MUST physically
      ;; drop the lock right now. While well-written core modes use
      ;; `inhibit-read-only` to format text safely, some third-party packages
      ;; might blindly attempt to modify the buffer and throw an error.
      (when should-clear-physical
        (read-only-mode -1)))))

(defun tedit--after-major-mode-change ()
  "Re-evaluate the buffer AFTER the new major mode has initialized."
  (when (and tedit-mode tedit-apply-locks-on-mode-change)
    (tedit--reconcile (current-buffer))))

(defun tedit--setup-company-integration ()
  "Inject or remove the company abort hook locally based on mode states."
  (if (and tedit-mode (bound-and-true-p company-mode))
      (add-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly nil t)
    (remove-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly t)))

(defun tedit--setup-corfu-integration ()
  "Inject or remove the corfu abort hook locally based on mode states."
  (if (and tedit-mode (bound-and-true-p corfu-mode))
      (add-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly nil t)
    (remove-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly t)))

(defun tedit--cleanup-buffer ()
  "Clean up tedit modifications and restore initial lock states when the mode exits."
  (let* ((base-soft (tedit--should-enable-soft-lock-p))
         (base-hard (tedit--should-enable-hard-lock-p))
         (base-rule (cond (base-soft 'soft) (base-hard 'hard) (t 'unmanaged))))

    ;; Hard Lock Teardown
    (when (memq 'hard-lock tedit-restore-initial-unmanaged-lock-states)
      (if tedit--native-read-only-p
          (unless buffer-read-only (read-only-mode 1))
        (when (and buffer-read-only (eq base-rule 'hard))
          (read-only-mode -1))))

    ;; Soft Lock Teardown
    (when (memq 'soft-lock tedit-restore-initial-unmanaged-lock-states)
      (when tedit-soft-lock-special--mode (tedit-soft-lock-special--mode -1)))

    ;; FIX: Plug the hook leak by explicitly scrubbing the local hooks
    (remove-hook 'read-only-mode-hook #'tedit--company-abort-if-readonly t)
    (remove-hook 'read-only-mode-hook #'tedit--corfu-quit-if-readonly t)

    ;; Clear the intent tracking
    (setq-local tedit--intended-state nil)))

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
    (unless tedit--theme-cursor-color (tedit--cache-cursor-color))
    (set-cursor-color
     (if (or buffer-read-only tedit-soft-lock-special--mode)
         tedit-cursor-color-when-lock
       (or tedit--theme-cursor-color "black")))))

(defun tedit--manage-timer ()
  "Start or stop the cursor sync idle timer based on mode state."
  (if tedit-mode
      (unless tedit--cursor-timer
        (setq tedit--cursor-timer (run-with-idle-timer tedit-cursor-timer-delay t #'tedit--update-cursor-color)))
    (when tedit--cursor-timer
      (cancel-timer tedit--cursor-timer)
      (setq tedit--cursor-timer nil))))

;;; Interactive Commands

(defun tedit-save-buffer-toggle ()
  "Toggle `read-only-mode' and save the buffer if appropriate."
  (interactive)

  ;; 1. Handle Saving
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

  ;; 2. File System Write Permission Native Guard
  (if (and tedit-toggle-inhibit-if-file-initially-hard-locked tedit--native-read-only-p)
      (message "Toggling inhibited: File visited as natively read-only.")

    (let* ((base-soft (tedit--should-enable-soft-lock-p))
           (base-hard (tedit--should-enable-hard-lock-p))
           (base-rule (cond (base-soft 'soft) (base-hard 'hard) (t 'unmanaged))))

      ;; 3. Check Unmanaged Buffers Inhibition
      (if (and (eq base-rule 'unmanaged)
               tedit-toggle-inhibit-unmanaged-buffers
               (not (tedit--match-rules-p tedit-toggle-always-allow-buffer-regexps nil tedit-toggle-always-allow-mode-list)))
          (message "Toggle inhibited: Buffer is not managed by tedit.")

        ;; QUIRK: Sync intent with physical reality before cycling an unmanaged buffer.
        ;; If the buffer is unmanaged, but the user temporarily pressed native C-x C-q,
        ;; we adopt the current physical state BEFORE cycling it, so the toggle
        ;; transitions correctly instead of blindly applying the base rule.
        (when (eq tedit--intended-state 'unmanaged)
          (setq tedit--intended-state (if buffer-read-only 'hard 'none)))

        ;; 4. Cycle User Intent
        (setq tedit--intended-state
              ;; If currently locked by ANY method, the user's intent is to unlock it.
              (if (memq tedit--intended-state '(hard soft dual))
                  'none
                (cond
                 (base-soft
                  (pcase tedit-soft-lock-toggle-method
                    ('soft-lock 'soft)
                    ('hard-lock 'hard)
                    ('both-lock 'dual)))
                 (base-hard 'hard)
                 ;; Fallback: If unlocked and unmanaged (but allowed by whitelist), lock it.
                 (t 'hard)))))

      ;; 5. Apply the new intent immediately
      (tedit--reconcile (current-buffer))))))


;;; Package Integration

(defun tedit--company-abort-if-readonly ()
  "Abort company completion if the buffer is read-only."
  (and buffer-read-only (bound-and-true-p company-mode) (fboundp 'company-abort) (company-abort)))

(defun tedit--corfu-quit-if-readonly ()
  "Abort corfu completion if the buffer is read-only."
  (and buffer-read-only (bound-and-true-p corfu-mode) (fboundp 'corfu-quit) (corfu-quit)))

;;; Mode Definition

(defvar tedit-soft-lock-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
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
  "Local minor mode that blocks user input for particular buffers.
For particular buffers in `tedit-soft-lock-buffer-regexps' and special buffers.

Block user input via a keymap instead of locking them in read-only.  For
cases that some elisp code needs to write to these buffers."
  :group 'tedit
  :lighter " TEditS"
  :keymap tedit-soft-lock-map)

(defun tedit--after-fundamental-mode-advice (&rest _)
  "Ensure tedit evaluates fundamental-mode, unless it's a parent mode transition."
  (unless (bound-and-true-p delay-mode-hooks)
    (when (and tedit-mode
               tedit-apply-locks-on-mode-change
               (eq (current-buffer) (window-buffer (selected-window))))
      (tedit--reconcile (current-buffer)))))

(defun tedit--after-revert-hook ()
  "Recalculate native read-only lock and intent after a buffer revert.

According to the initial read-only state managed by Emacs revert
handling, re-cache the state to `tedit--native-read-only-p'.  Instead of
re-caching directly according to the write permission in the file
system.

Because `revert-buffer' is a destructive action that wipes buffer state
and reloads from the file system, this forces the engine to forget past
user overrides and capture the fresh file state."
  (when tedit-mode
    (setq tedit--native-read-only-p buffer-read-only)
    (setq tedit--intended-state nil)
    (tedit--reconcile (current-buffer))))

(defun tedit--after-save-hook ()
  "Conditionally recalculate native read-only lock if write permission changes when saved or renamed.

According to the actual file write permission in the file system.

This catches the file write permission changes when a file is saved or renamed
by a command such as \\[write-file](`write-file'), for example, a root file is
renamed to save in a home directory, and now is writable.

If the file system write permission contradicts the engine's permanent anchor
(`tedit--native-read-only-p'), tedit wipes the current intent and forces
a strict re-evaluation of the new real state.

This is deliberately decoupled from `tedit--after-revert-hook' because
saving preserves buffer state, whereas reverting destroys it."
  (when (and tedit-mode buffer-file-name (local-variable-p 'tedit--native-read-only-p))
    ;; 1. Check if the file in the file system is currently write-protected
    (let ((is-natively-readonly (not (file-writable-p buffer-file-name))))
      ;; 2. Only act if the file write permission contradicts our
      ;; permanent anchor
      (unless (eq tedit--native-read-only-p is-natively-readonly)
        ;; 3. Update the anchor to match the file's write permission
        ;; on the file system
        (setq tedit--native-read-only-p is-natively-readonly)
        ;; 4. A change in file's write permission in the file system
        ;; invalidates the saved state.  Set it to nil to force a
        ;; re-evaluation.
        (setq tedit--intended-state nil)
        (tedit--reconcile (current-buffer))))))

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
        (add-hook 'window-selection-change-functions #'tedit--focus-handler)
        (add-hook 'window-buffer-change-functions #'tedit--focus-handler)
        (add-hook 'change-major-mode-hook #'tedit--before-major-mode-change)
        (add-hook 'after-change-major-mode-hook #'tedit--after-major-mode-change)
        (add-hook 'after-revert-hook #'tedit--after-revert-hook)
        (add-hook 'after-save-hook #'tedit--after-save-hook)
        (advice-add 'fundamental-mode :after #'tedit--after-fundamental-mode-advice)
        (advice-add 'enable-theme :after #'tedit--cache-cursor-color)
        (advice-add 'disable-theme :after #'tedit--cache-cursor-color)

        ;; Register Completion Integrations
        (add-hook 'company-mode-hook #'tedit--setup-company-integration)
        (add-hook 'corfu-mode-hook #'tedit--setup-corfu-integration)

        ;; Retroactive Boot: Evaluate all existing buffers immediately
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (tedit--setup-company-integration)
            (tedit--setup-corfu-integration)))

        (tedit--focus-handler))

    ;; DISABLE
    (tedit--manage-timer)
    (set-cursor-color (or tedit--theme-cursor-color "black"))
    (remove-hook 'window-selection-change-functions #'tedit--focus-handler)
    (remove-hook 'window-buffer-change-functions #'tedit--focus-handler)
    (remove-hook 'change-major-mode-hook #'tedit--before-major-mode-change)
    (remove-hook 'after-change-major-mode-hook #'tedit--after-major-mode-change)
    (remove-hook 'after-revert-hook #'tedit--after-revert-hook)
    (remove-hook 'after-save-hook #'tedit--after-save-hook)
    (advice-remove 'fundamental-mode #'tedit--after-fundamental-mode-advice)
    (advice-remove 'enable-theme #'tedit--cache-cursor-color)
    (advice-remove 'disable-theme #'tedit--cache-cursor-color)

    ;; Unregister Completion Integrations
    (remove-hook 'company-mode-hook #'tedit--setup-company-integration)
    (remove-hook 'corfu-mode-hook #'tedit--setup-corfu-integration)

    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (tedit--cleanup-buffer)))))

(provide 'tedit)
;;; tedit.el ends here
