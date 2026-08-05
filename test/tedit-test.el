;;; test/tedit-test.el --- Buttercup tests for tedit.el -*- lexical-binding: t -*-

(require 'buttercup)
(require 'tedit)

;; Enable tedit globally for the duration of the test suite
(tedit-mode 1)

(describe "Tedit Core Engine"

  (describe "tedit--compute-effective-state (The Evaluator)"

    (it "lazily captures file system write-protected state on first focus"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only t)
          ;; TRAP: `defvar-local` variables must be explicitly killed in tests.
          ;; Using `setq` registers it as a locally modified variable, which
          ;; bypasses the engine's `local-variable-p` check!
          (kill-local-variable 'tedit--native-read-only-p)
          (setq tedit--intended-state nil)

          ;; QUIRK: We mock Emacs C primitives instead of spawning real windows
          ;; to prevent headless CI pipelines from crashing.
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          (let ((result (tedit--compute-effective-state (current-buffer))))
            (expect tedit--native-read-only-p :to-be t)
            (expect result :to-be 'hard)))))

    (it "unlocks managed hard-locked buffers when relegated to the background"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'hard)

          (spy-on 'selected-window :and-return-value 'other-window)
          (spy-on 'window-buffer :and-return-value 'other-buffer)

          (let ((result (tedit--compute-effective-state (current-buffer))))
            (expect result :to-be 'none)))))

    (it "NEVER unlocks a file system write-protected file in the background"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p t)
          (setq tedit--intended-state 'hard)

          (spy-on 'selected-window :and-return-value 'other-window)
          (spy-on 'window-buffer :and-return-value 'other-buffer)

          ;; Proof: The impenetrable OS guard refuses to yield to the blur-unlock feature.
          (expect (tedit--compute-effective-state (current-buffer)) :to-be 'hard))))

    (it "upgrades soft-lock to dual-lock if the file is natively write-protected"
      (let ((tedit-soft-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only t)
          (kill-local-variable 'tedit--native-read-only-p)
          (setq tedit--intended-state nil)

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; The engine sees a soft-lock rule, but Emacs file handling
          ;; determines initial read-only for the visited file, so it
          ;; safely merges them.
          (expect (tedit--compute-effective-state (current-buffer)) :to-be 'dual))))

    (it "resolves a regex rule conflict (Hard AND Soft match) to 'soft if method is 'override"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)) ;; Wants Hard
            (tedit-soft-lock-major-mode-list '(text-mode)) ;; Wants Soft
            (tedit-soft-lock-existing-hard-lock-method 'override))
        (with-temp-buffer
          (text-mode)
          ;; TRAP: Must be nil. If this is `t`, the OS guard triggers and forces a 'dual lock!
          (setq buffer-read-only nil)
          (kill-local-variable 'tedit--native-read-only-p)
          (setq tedit--intended-state nil)

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; Proof: The engine respected the user's override setting for rule conflicts.
          (expect (tedit--compute-effective-state (current-buffer)) :to-be 'soft))))

    (it "drops the hard lock of a dual lock when the buffer is focused out"
      (let ((tedit-soft-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          ;; The file is writable (native is nil), but tedit applied a
          ;; dual lock: buffer-read-only reflects the hard lock, while
          ;; intended-state records both locks.
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'dual)

          ;; Mock the buffer as running in the background.
          (spy-on 'selected-window :and-return-value 'other-window)
          (spy-on 'window-buffer :and-return-value 'other-buffer)

          ;; The Action: the evaluator decides the background state.
          (let ((result (tedit--compute-effective-state (current-buffer))))

            ;; Proof: Only the hard part (read-only) blocks elisp
            ;; writes, so the blur drops it and keeps the soft lock.
            ;; Soft lock never blocks elisp, so the background process
            ;; can write, while the user still cannot type.
            (expect result :to-be 'soft)))))

    (it "preserves the user's explicit unlock when the buffer is focused out"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          ;; The user toggled the buffer unlocked via
          ;; `tedit-save-buffer-toggle', so intended-state is 'none.
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'none)

          ;; Mock the buffer as running in the background.
          (spy-on 'selected-window :and-return-value 'other-window)
          (spy-on 'window-buffer :and-return-value 'other-buffer)

          ;; The Action: the evaluator decides the background state.
          (let ((result (tedit--compute-effective-state (current-buffer))))

            ;; Proof: The blur logic must not re-apply a lock to a
            ;; buffer the user explicitly unlocked.  The 'none state
            ;; survives the window switch unchanged.
            (expect result :to-be 'none)))))
    )


  (describe "tedit--reconcile (The State Enforcer)"

    (it "applies both read-only and soft-lock modes to the buffer for a DUAL state"
      (with-temp-buffer
        ;; Spy on the evaluator to force a 'dual state return, isolating the Enforcer's logic
        (spy-on 'tedit--compute-effective-state :and-return-value 'dual)
        (setq buffer-read-only nil)

        (tedit--reconcile (current-buffer))

        ;; Proof: Both buffer state manipulations occurred
        (expect buffer-read-only :to-be t)
        (expect (bound-and-true-p tedit-soft-lock-special--mode) :to-be t))))


  (describe "Mode Change Interactions (The Hooks)"

    (describe "When tedit-clear-hard-lock-before-mode-change is TRUE"

      (it "drops the lock and clears cache if apply-locks is TRUE"
        (let ((tedit-clear-hard-lock-before-mode-change t)
              (tedit-apply-locks-on-mode-change t)
              (tedit-hard-lock-major-mode-list '(text-mode)))
          (with-temp-buffer
            (text-mode)
            (setq buffer-read-only t)
            (setq tedit--native-read-only-p nil)
            (setq tedit--intended-state 'hard)

            (tedit--before-major-mode-change)

            (expect buffer-read-only :to-be nil)
            (expect tedit--intended-state :to-be nil))))

      (it "drops the lock but DEFERS evaluation if apply-locks is FALSE"
        (let ((tedit-clear-hard-lock-before-mode-change t)
              (tedit-apply-locks-on-mode-change nil)
              (tedit-hard-lock-major-mode-list '(text-mode)))
          (with-temp-buffer
            (text-mode)
            (setq buffer-read-only t)
            (setq tedit--native-read-only-p nil)
            (setq tedit--intended-state 'hard)

            (tedit--before-major-mode-change)

            (expect buffer-read-only :to-be nil)
            (expect tedit--intended-state :to-be 'hard)
            (expect tedit--needs-re-evaluation :to-be t))))

      (it "never physically unlocks a file system write-protected buffer before a mode change"
        (let ((tedit-clear-hard-lock-before-mode-change t)
              (tedit-apply-locks-on-mode-change t)
              (tedit-hard-lock-major-mode-list '(text-mode)))
          (with-temp-buffer
            (text-mode)
            (setq buffer-read-only t)             ;; Currently locked
            (setq tedit--native-read-only-p t)    ;; File system write-protected
            (setq tedit--intended-state 'hard)

            ;; The Action: major mode is about to change.
            (tedit--before-major-mode-change)

            ;; Proof: The physical lock is preserved.  Even though
            ;; `clear-hard-lock-before-mode-change' is t, a file that
            ;; is natively write-protected on the file system must
            ;; NEVER have its physical lock stripped — the condition
            ;; `(not tedit--native-read-only-p)' in should-clear-physical
            ;; guards against this.
            (expect buffer-read-only :to-be t))))
      )

    (describe "When tedit-clear-hard-lock-before-mode-change is FALSE"

      (it "preserves the native hard-lock and clears auto-computed intent across a mode change"
        (let ((tedit-clear-hard-lock-before-mode-change nil)
              (tedit-apply-locks-on-mode-change t)
              (tedit-hard-lock-major-mode-list '(text-mode)))
          (with-temp-buffer
            (text-mode)
            (setq buffer-read-only t)
            (setq tedit--native-read-only-p nil)
            (setq tedit--intended-state 'hard)  ;; auto-computed, equals base-rule

            ;; The Action: major mode is about to change.
            (tedit--before-major-mode-change)

            ;; Proof: Physical lock is untouched because
            ;; `should-clear-physical' is nil when
            ;; `clear-hard-lock-before-mode-change' is nil.
            (expect buffer-read-only :to-be t)
            ;; Intent cache is cleared because the state was
            ;; auto-computed (eq intended-state base-rule),
            ;; so the new mode triggers fresh evaluation.
            (expect tedit--intended-state :to-be nil))))

      (it "preserves a manual override across a mode change"
        (let ((tedit-clear-hard-lock-before-mode-change nil)
              (tedit-apply-locks-on-mode-change t)
              (tedit-hard-lock-major-mode-list '(text-mode)))
          (with-temp-buffer
            (text-mode)
            (setq buffer-read-only nil)
            (setq tedit--native-read-only-p nil)
            (setq tedit--intended-state 'none)  ;; manual override, ≠ base-rule 'hard

            ;; The Action: major mode is about to change.
            (tedit--before-major-mode-change)

            ;; Proof: Manual override is preserved.  The condition
            ;; (eq intended-state base-rule) is nil, so the cache
            ;; is left intact — the user's explicit unlock survives
            ;; the mode transition.
            (expect tedit--intended-state :to-be 'none))))
      )

    (it "re-evaluates the buffer based on new major mode rules after a mode change"
      (let ((tedit-apply-locks-on-mode-change t)
            (tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          ;; Buffer is currently unmanaged (fundamental-mode)
          (fundamental-mode)
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'unmanaged)

          ;; Simulate switching to a managed major mode
          (text-mode)

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; The Action: after-change-major-mode-hook fires.
          (tedit--after-major-mode-change)

          ;; Proof: The buffer is re-evaluated under the new mode's
          ;; rules.  `text-mode' matches hard-lock-derived-mode-list,
          ;; so the engine applies a hard lock.
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))
    )


  (describe "tedit--focus-handler (The Event Loop)"

    (it "wipes manual overrides on MANAGED buffers when always-lock is TRUE"
      (let ((tedit-always-lock-on-switch t)
            (tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only nil)
          (setq tedit--intended-state 'none) ;; User's manual override
          (setq tedit--last-focused-buffer (generate-new-buffer "outgoing-buffer"))

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          (tedit--focus-handler)

          ;; Proof: The engine ruthlessly wiped 'none and re-locked it based on base rules
          (expect tedit--intended-state :to-be 'hard)
          (kill-buffer "outgoing-buffer"))))

    (it "leaves UNMANAGED buffers completely alone when always-lock is TRUE"
      (let ((tedit-always-lock-on-switch t)
            (tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (fundamental-mode)
          (setq buffer-read-only t)
          (setq tedit--intended-state 'hard) ;; User's manual lock on an unmanaged buffer
          (setq tedit--last-focused-buffer (generate-new-buffer "outgoing-buffer"))

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          (tedit--focus-handler)

          ;; Proof: The engine ignored the unmanaged buffer and left the lock intact
          (expect tedit--intended-state :to-be 'hard)
          (kill-buffer "outgoing-buffer"))))

    (it "aborts entirely if `this-command` is in `tedit-inhibit-commands`"
      (let ((this-command 'wgrep-finish-edit)
            (tedit-inhibit-commands '(wgrep-finish-edit)))
        (with-temp-buffer
          (setq tedit--intended-state 'none)
          (setq tedit--needs-re-evaluation t) ;; This flag should normally be wiped by focus

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          (tedit--focus-handler)

          ;; Proof: The handler paralyzed itself during a refactoring command
          (expect tedit--needs-re-evaluation :to-be t))))

    (it "aborts relocking if returning FROM a dedicated window"
      (let ((tedit-relock-inhibit-from-dedicated-window t))
        (with-temp-buffer
          (setq tedit--last-focused-buffer (generate-new-buffer "treemacs-buffer"))

          ;; QUIRK: We mock the outgoing buffer's window to simulate returning from a side-panel
          (spy-on 'get-buffer-window :and-return-value 'fake-dedicated-window)
          (spy-on 'window-dedicated-p :and-return-value t)

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; Spy on the reconciler to prove the execution halted
          (spy-on 'tedit--reconcile)

          (tedit--focus-handler)

          (expect 'tedit--reconcile :not :to-have-been-called)
          (kill-buffer "treemacs-buffer"))))

    (it "aborts completely if the user is in a deep minibuffer"
      (let ((tedit-relock-inhibit-from-deep-minibuffer t))
        (with-temp-buffer
          (spy-on 'minibuffer-depth :and-return-value 1)
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          (spy-on 'tedit--reconcile)

          (tedit--focus-handler)

          ;; Proof: Prevents the engine from stealing focus during M-: evaluations
          (expect 'tedit--reconcile :not :to-have-been-called))))

    (it "handles deleted outgoing buffers safely without throwing an error"
      (with-temp-buffer
        ;; 1. Setup a dummy buffer, assign it to last-buf, and immediately kill it
        (let ((killed-buf (generate-new-buffer "to-be-killed")))
          (setq tedit--last-focused-buffer killed-buf)
          (kill-buffer killed-buf)

          ;; 2. Mock the focus shift to our temp buffer
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; 3. Proof: If the dead buffer guard fails, this throws "Selecting deleted buffer".
          ;; If it succeeds, the focus handler executes cleanly without throwing.
          (expect (tedit--focus-handler) :not :to-throw))))

    (it "does not update last-focused-buffer when the incoming buffer is a minibuffer"
      (let ((tedit-always-lock-on-switch t)
            (tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq tedit--intended-state 'none)

          ;; The buffer was focused before the minibuffer appeared
          (setq tedit--last-focused-buffer (current-buffer))

          (spy-on 'tedit--reconcile)

          ;; The Action: A minibuffer (TRAMP password prompt, M-x, etc.)
          ;; steals focus.  The guard `(minibufferp buf)' triggers.
          (spy-on 'selected-window :and-return-value 'minibuffer-window)
          (spy-on 'window-buffer :and-return-value 'minibuffer-buffer)
          (spy-on 'minibufferp :and-return-value t)

          (tedit--focus-handler)

          ;; Proof: The guard blocked the entire body.  The reconciler
          ;; was never called, and `last-focused-buffer' was never
          ;; overwritten with the minibuffer — it still points to the
          ;; real buffer, which is the mechanism that preserves
          ;; `switched-p' = nil when focus returns.
          (expect tedit--last-focused-buffer :to-be (current-buffer))
          (expect 'tedit--reconcile :not :to-have-been-called))))

    (it "preserves manual overrides when switched-p is nil despite always-lock being t"
      (let ((tedit-always-lock-on-switch t)
            (tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'none) ;; User toggled unlocked

          ;; Same buffer = switched-p is nil.  This is exactly what
          ;; happens after a minibuffer round-trip: the minibuffer
          ;; guard prevented `last-focused-buffer' from being updated,
          ;; so when focus returns, the incoming buffer matches
          ;; the stored buffer.
          (setq tedit--last-focused-buffer (current-buffer))

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; The Action: Focus handler fires for the same buffer
          ;; (e.g., returning from a TRAMP password prompt).
          (tedit--focus-handler)

          ;; Proof: `'none' survived.  `always-lock-on-switch' is gated
          ;; behind `switched-p', which is nil here, so the reset logic
          ;; never fired.
          (expect tedit--intended-state :to-be 'none)
          (expect buffer-read-only :to-be nil))))

    (it "does not relock a managed buffer when returning from a killed relock-inhibited buffer"
      (let ((tedit-always-lock-on-switch t)
            (tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-relock-inhibit-from-buffer-regexps '("\\*Org Select\\*")))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'none) ;; User toggled unlocked

          ;; Step 1: focus moves to *Org Select*, which matches the
          ;; relock-inhibit regexps.  It must NOT be recorded as
          ;; last-focused, so returning from it is not a real switch.
          (setq tedit--last-focused-buffer (current-buffer))
          (let ((org-select (generate-new-buffer "*Org Select*")))
            (spy-on 'selected-window :and-return-value 'select-window)
            (spy-on 'window-buffer :and-return-value org-select)
            (tedit--focus-handler)

            ;; Kill the buffer, simulating `org-mks' cleanup which
            ;; kills *Org Select* before focus returns.
            (kill-buffer org-select))

          ;; Step 2: focus returns to the original buffer.
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))
          (tedit--focus-handler)

          ;; Proof: The 'none override survives.  The buffer is NOT
          ;; relocked, even though the outgoing buffer was killed
          ;; before focus returned.
          (expect tedit--intended-state :to-be 'none)
          (expect buffer-read-only :to-be nil))))

    (it "does not relock a managed buffer when returning from a killed relock-inhibited mode"
      (let ((tedit-always-lock-on-switch t)
            (tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-relock-inhibit-from-mode-list '(special-mode)))
        (with-temp-buffer
          (text-mode) ;; Managed, but does NOT match the inhibit list
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'none) ;; User toggled unlocked

          ;; Step 1: focus moves to a special-mode buffer that matches
          ;; the relock-inhibit mode list.  It must NOT be recorded as
          ;; last-focused, so returning from it is not a real switch.
          (setq tedit--last-focused-buffer (current-buffer))
          (let ((inhibit-buffer (generate-new-buffer "*inhibit-mode*")))
            (with-current-buffer inhibit-buffer
              (special-mode))
            (spy-on 'selected-window :and-return-value 'select-window)
            (spy-on 'window-buffer :and-return-value inhibit-buffer)
            (tedit--focus-handler)

            ;; Kill the buffer before focus returns.
            (kill-buffer inhibit-buffer))

          ;; Step 2: focus returns to the original buffer.
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))
          (tedit--focus-handler)

          ;; Proof: The 'none override survives.  The buffer is NOT
          ;; relocked, even though the outgoing buffer's mode matched
          ;; the inhibit list and the buffer was killed before return.
          (expect tedit--intended-state :to-be 'none)
          (expect buffer-read-only :to-be nil))))

    (it "still applies locks to a relock-inhibited buffer on entry"
      (let ((tedit-always-lock-on-switch t)
            (tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-relock-inhibit-from-buffer-regexps '("\\*Inhibit Managed\\*")))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'none)
          (setq tedit--last-focused-buffer (current-buffer))

          ;; The inhibited buffer is ALSO hard-lock managed.
          (let ((inhibit-buffer (generate-new-buffer "*Inhibit Managed*")))
            (with-current-buffer inhibit-buffer
              (text-mode)
              (setq tedit--native-read-only-p nil))
            (spy-on 'selected-window :and-return-value 'select-window)
            (spy-on 'window-buffer :and-return-value inhibit-buffer)

            ;; The Action: focus moves to the inhibited, managed buffer.
            (tedit--focus-handler)

            ;; Proof: always-lock-on-switch still applies.  The buffer
            ;; was reconciled and hard-locked, even though it will not
            ;; be recorded as last-focused.
            (expect (buffer-local-value 'buffer-read-only inhibit-buffer)
                    :to-be t)
            (kill-buffer inhibit-buffer)))))
    )


  (describe "tedit-save-buffer-toggle (The Master Command)"

    (it "cycles a managed hard lock into an unlocked state"
      (let ((tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'hard)

          (tedit-save-buffer-toggle)

          (expect tedit--intended-state :to-be 'none)
          (expect buffer-read-only :to-be nil))))

    (it "refuses to unlock if file is natively write-protected and inhibition is ON"
      (let ((tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-toggle-inhibit-if-file-initially-hard-locked t)
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p t)
          (setq tedit--intended-state 'hard)

          (spy-on 'message)

          (tedit-save-buffer-toggle)

          ;; Proof: File write permission guard overrides the user's
          ;; manual toggle attempt
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "allows unlocking file system write-protected files if toggle inhibition is OFF"
      (let ((tedit-hard-lock-major-mode-list '(text-mode))
            ;; THE CRITICAL VARIABLE: User explicitly allows unlocking OS files
            (tedit-toggle-inhibit-if-file-initially-hard-locked nil)
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (text-mode)
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p t)
          (setq tedit--intended-state 'hard)

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; The Action: User presses the toggle button
          (tedit-save-buffer-toggle)

          ;; Proof: The toggle successfully sets intent to 'none, and the
          ;; File write permission-Guard respects the user's manual
          ;; override instead of blocking it!
          (expect tedit--intended-state :to-be 'none)
          (expect buffer-read-only :to-be nil))))

    (it "uses actual buffer state to successfully unlock an unmanaged buffer in 1 tap"
      (let ((tedit-hard-lock-major-mode-list nil)
            (tedit-toggle-save-on-toggle nil)
            (tedit-toggle-inhibit-unmanaged-buffers nil))
        (with-temp-buffer
          (fundamental-mode) ;; Unmanaged
          (setq tedit--intended-state 'unmanaged)
          (setq buffer-read-only t) ;; User physically locked it via C-x C-q

          ;; The toggle queries the buffer state (t), and immediately targets 'none
          (tedit-save-buffer-toggle)

          (expect tedit--intended-state :to-be 'none)
          (expect buffer-read-only :to-be nil))))

    (it "uses the fallback rule to lock an unlocked unmanaged buffer"
      (let ((tedit-hard-lock-major-mode-list nil)
            (tedit-toggle-save-on-toggle nil)
            (tedit-toggle-inhibit-unmanaged-buffers nil))
        (with-temp-buffer
          (fundamental-mode) ;; Unmanaged
          (setq tedit--intended-state 'unmanaged)
          (setq buffer-read-only nil) ;; Buffer is completely free

          ;; The toggle queries the buffer state (nil), falls through to (t 'hard)
          (tedit-save-buffer-toggle)

          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "heals a desynchronized managed buffer in 1 tap by querying the actual buffer state"
      (let ((tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (text-mode)

          ;; FIX: Mock focus! Otherwise the engine realizes this temp buffer is
          ;; in the background and ruthlessly blur-unlocks it right before the expect!
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; SETUP THE DESYNC: Engine thinks it's locked, but it is actually unlocked natively
          (setq tedit--intended-state 'hard)
          (setq buffer-read-only nil)

          ;; The toggle queries the actual buffer state (nil). It wants to lock.
          (tedit-save-buffer-toggle)

          ;; Proof: It locked the buffer immediately. No double-tap required!
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "refuses to cycle an unmanaged buffer when inhibition is ON"
      (let ((tedit-hard-lock-major-mode-list nil)
            (tedit-soft-lock-major-mode-list nil)
            (tedit-toggle-inhibit-unmanaged-buffers t))
        (with-temp-buffer
          (fundamental-mode)
          (setq tedit--intended-state 'unmanaged)
          (setq buffer-read-only t)

          (spy-on 'message) ;; Suppress terminal output during test

          (tedit-save-buffer-toggle)

          ;; Proof: The toggle aborted cleanly without altering state
          (expect tedit--intended-state :to-be 'unmanaged)
          (expect buffer-read-only :to-be t)))))


  (describe "tedit--match-rules-p (The Utility Matcher)"
    (it "matches correctly against major-mode lists"
      (with-temp-buffer
        (let ((major-mode 'python-mode))
          ;; TRAP: Elisp truthiness requires `:to-be-truthy`. If we used `:to-be t`,
          ;; it would fail because `memq` returns the remainder of the list, not literal `t`.
          (expect (tedit--match-rules-p nil nil '(python-mode text-mode)) :to-be-truthy)
          (expect (tedit--match-rules-p nil nil '(ruby-mode)) :to-be nil))))

    (it "matches correctly against buffer name regexes"
      (with-temp-buffer
        (rename-buffer "*secret-data*")
        (expect (tedit--match-rules-p '("^\\*secret") nil nil) :to-be-truthy)
        (expect (tedit--match-rules-p '("^\\*public") nil nil) :to-be nil))))

  (describe "Option: tedit-soft-lock-toggle-method"
    (it "cycles to 'dual when method is set to 'both-lock"
      (let ((tedit-soft-lock-major-mode-list '(text-mode))
            (tedit-soft-lock-toggle-method 'both-lock)
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (text-mode)
          (setq tedit--intended-state 'none)
          ;; FIX: `(text-mode)` triggered global hooks that physically soft-locked
          ;; this buffer. We MUST drop the physical lock here, otherwise the
          ;; DOM-first toggle command will correctly see the lock and unlock it!
          (tedit-soft-lock-special--mode -1)

          (tedit-save-buffer-toggle)
          (expect tedit--intended-state :to-be 'dual))))

    (it "cycles to 'hard when method is set to 'hard-lock"
      (let ((tedit-soft-lock-major-mode-list '(text-mode))
            (tedit-soft-lock-toggle-method 'hard-lock)
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (text-mode)
          (setq tedit--intended-state 'none)
          ;; FIX: Drop the physical soft-lock applied by the global mode hooks
          (tedit-soft-lock-special--mode -1)

          (tedit-save-buffer-toggle)
          (expect tedit--intended-state :to-be 'hard))))

    (it "cycles to 'soft when method is set to 'soft-lock (the default)"
      (let ((tedit-soft-lock-major-mode-list '(text-mode))
            (tedit-soft-lock-toggle-method 'soft-lock)
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (text-mode)
          (setq tedit--intended-state 'none)
          ;; Drop the physical soft-lock applied by global mode hooks
          (tedit-soft-lock-special--mode -1)

          (tedit-save-buffer-toggle)

          (expect tedit--intended-state :to-be 'soft)
          (expect (bound-and-true-p tedit-soft-lock-special--mode) :to-be t))))
    )

  (describe "Saving Logic during Toggle"
    (it "runs the custom inhibit-save hook when basic saving is bypassed"
      (let ((tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-toggle-save-on-toggle t)
            (tedit-toggle-inhibit-save-buffer-regexps '(".*"))
            (hook-ran nil))

        ;; Prove the hook API correctly fires
        (add-hook 'tedit-toggle-inhibit-save-buffer-hook
                  (lambda () (setq hook-ran t)))

        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/fake/path/file.txt")
          (setq buffer-read-only nil)

          (tedit-save-buffer-toggle)

          (expect hook-ran :to-be t))))

    (it "calls basic-save-buffer when toggling to lock an unlocked file-visiting buffer"
      (let ((tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-toggle-save-on-toggle t))
        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/tmp/test-file.txt")
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'none)

          ;; FIX: Mock focus to prevent the temp buffer from being
          ;; blur-unlocked by the background handler in reconcile.
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; Spy on `basic-save-buffer' to verify it is invoked
          ;; without actually writing to the file system.
          (spy-on 'basic-save-buffer)

          ;; The Action: User presses the toggle to lock and save.
          (tedit-save-buffer-toggle)

          ;; Proof: `basic-save-buffer' was called because the buffer
          ;; was unlocked, visits a file, and save-on-toggle is t.
          (expect 'basic-save-buffer :to-have-been-called-times 1)
          ;; The buffer was locked after saving.
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))
    )

  (describe "tedit--cleanup-buffer (Buffer Teardown)"
    (it "leaves manual locks intact on unmanaged buffers"
      (let ((tedit-hard-lock-major-mode-list nil)
            (tedit-soft-lock-major-mode-list nil))
        (with-temp-buffer
          (fundamental-mode) ;; Strictly unmanaged

          ;; Simulate user locking it manually while tedit was active
          (setq buffer-read-only t)
          (setq tedit--intended-state 'hard)

          ;; The Action: The buffer is killed or the mode is disabled locally
          (tedit--cleanup-buffer)

          ;; Proof: Tedit did not own this lock, so it must survive teardown
          (expect buffer-read-only :to-be-truthy))))

    (it "strips locks from managed buffers"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode) ;; Managed

          ;; Simulate engine locking it automatically
          (setq buffer-read-only t)
          (setq tedit--intended-state 'hard)

          (tedit--cleanup-buffer)

          ;; Proof: Tedit owned this lock, so it cleans up the buffer state
          (expect buffer-read-only :to-be nil))))

    (it "re-locks file system write-protected buffers during teardown regardless of managed rules"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode) ;; Managed by hard-lock rules

          ;; Simulate: the buffer was unlocked (e.g., via
          ;; `inhibit-read-only') while tedit was active, but the
          ;; underlying file is write-protected on the file system.
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p t)
          (setq tedit--intended-state 'hard)

          ;; The Action: tedit-mode exits, cleanup runs.
          (tedit--cleanup-buffer)

          ;; Proof: Buffer is re-locked.  File system write protection
          ;; takes priority over the managed rule (which would normally
          ;; strip the lock).  The `if tedit--native-read-only-p' branch
          ;; in cleanup ensures this.
          (expect buffer-read-only :to-be t))))
    )

  (describe "Revert Buffer (after-revert-hook) Integration"

    (it "wipes manual user overrides and reinstates base rules"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          ;; Setup: User had temporarily unlocked the buffer manually
          (setq buffer-file-name "/tmp/test.txt")
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'none)
          (setq buffer-read-only nil)

          ;; Mock focus (User is currently looking at this buffer)
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; The Action: Revert finishes and triggers the hook
          (tedit--after-revert-hook)

          ;; Proof: The 'none override is destroyed, strict 'hard lock is restored
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "upgrades locks if the reverted file became write-protected on file system"
      (let ((tedit-soft-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          ;; Setup: Initially just soft-locked and fully writable on disk
          (setq buffer-file-name "/tmp/test.txt")
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'soft)
          (setq buffer-read-only nil)

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; The Action: Emacs natives set `buffer-read-only` to t during revert
          ;; because the file on disk became read-only. Then the hook fires.
          (setq buffer-read-only t)
          (tedit--after-revert-hook)

          ;; Proof: Tedit captures the new write permission and upgrades to a 'dual lock
          (expect tedit--native-read-only-p :to-be t)
          (expect tedit--intended-state :to-be 'dual))))

    (it "evaluates correctly for background buffers without stealing focus"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          ;; Setup: Buffer has a manual override, but is fully writable
          (setq buffer-file-name "/tmp/test.txt")
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'none)
          (setq buffer-read-only nil)

          ;; Mock it as a BACKGROUND buffer (auto-revert-mode doing a silent refresh)
          (spy-on 'selected-window :and-return-value 'other-window)
          (spy-on 'window-buffer :and-return-value 'other-buffer)

          ;; The Action: Hook fires silently in the background
          (tedit--after-revert-hook)

          ;; Proof: Engine resets intent to 'hard, but correctly realizes it is in the
          ;; background and perfectly executes the background unlock logic
          (expect tedit--native-read-only-p :to-be nil)
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be nil))))
  )

  (describe "Save As (C-x C-w) / after-save-hook Integration"

    (it "upgrades to read-only when a writable file is saved to a protected location"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/home/user/writable.txt")
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil) ;; Initially captured as writable
          (setq tedit--intended-state 'hard)

          ;; Mock it as currently focused by the user
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; The Action: User saves to a write-protected location
          (setq buffer-file-name "/etc/protected.txt")
          (spy-on 'file-writable-p :and-return-value nil)

          (tedit--after-save-hook)

          ;; Proof: The engine detected the file write-protection and locked it
          (expect tedit--native-read-only-p :to-be t)
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "drops native hard-lock when a root file is saved to a writable home directory"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/etc/hosts")
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p t) ;; Initially captured as read-only
          (setq tedit--intended-state 'hard)

          ;; Mock it as currently focused by the user
          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))

          ;; The Action: User saves a copy to their home directory
          (setq buffer-file-name "/home/user/hosts.txt")
          (spy-on 'file-writable-p :and-return-value t)

          (tedit--after-save-hook)

          ;; Proof: The engine dropped the write permission guard, but
          ;; kept the base rule ('hard)
          (expect tedit--native-read-only-p :to-be nil)
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "unlocks dynamically if a root file is saved to home while in the BACKGROUND"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/etc/hosts")
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p t)
          (setq tedit--intended-state 'hard)

          ;; Mock it as a BACKGROUND buffer (user is focused elsewhere)
          (spy-on 'selected-window :and-return-value 'other-window)
          (spy-on 'window-buffer :and-return-value 'other-buffer)

          ;; The Action: Background Elisp saves it to a writable location
          (setq buffer-file-name "/home/user/hosts.txt")
          (spy-on 'file-writable-p :and-return-value t)

          (tedit--after-save-hook)

          ;; Proof: The OS guard was dropped. Because it is in the background
          ;; and now writable, the engine safely unlocks the buffer variable!
          (expect tedit--native-read-only-p :to-be nil)
          (expect tedit--intended-state :to-be 'hard) ;; The engine still wants it locked...
          (expect buffer-read-only :to-be nil))))     ;; ...but buffer state is unlocked for async writes!

    (it "does not corrupt the anchor when saving a remote file whose anchor is nil"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/sudo::/etc/hosts")
          (setq buffer-read-only nil)
          (setq tedit--native-read-only-p nil) ;; File was writable via TRAMP
          (setq tedit--intended-state 'hard)

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))
          (spy-on 'file-remote-p :and-return-value t)
          ;; `file-writable-p' must never be called for a remote file,
          ;; because it requires a separate TRAMP authentication cycle
          ;; that can spuriously fail and corrupt the anchor.
          (spy-on 'file-writable-p)

          ;; The Action: TRAMP successfully saves the remote file.
          (tedit--after-save-hook)

          ;; Proof: A successful remote save proves the file is writable
          ;; on the remote host.  The anchor stays nil — it is not
          ;; corrupted by a separate `file-writable-p' round-trip.
          (expect tedit--native-read-only-p :to-be nil)
          (expect 'file-writable-p :not :to-have-been-called))))

    (it "drops the anchor when a file system write-protected file is saved to a remote writable path"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/sudo::/home/user/writable.txt")
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p t) ;; Previously write-protected
          (setq tedit--intended-state 'hard)

          (spy-on 'selected-window :and-return-value 'mock-window)
          (spy-on 'window-buffer :and-return-value (current-buffer))
          (spy-on 'file-remote-p :and-return-value t)

          ;; The Action: User saves the buffer to a TRAMP sudo path.
          (tedit--after-save-hook)

          ;; Proof: A successful remote save proves the file is writable
          ;; on the remote host.  The anchor drops from t to nil.
          (expect tedit--native-read-only-p :to-be nil)
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))
    )

  (describe "Indirect Buffer (clone-indirect-buffer) Handling"

    (it "inherits intended-state so toggle works on a cloned hard-locked buffer"
      (let ((tedit-hard-lock-major-mode-list '(text-mode))
            (tedit-toggle-save-on-toggle nil)
            (tedit-toggle-inhibit-if-file-initially-hard-locked t))
        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/tmp/base.txt")
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'hard)

          (let ((clone (clone-indirect-buffer "*clone-test*" nil)))
            (unwind-protect
                (with-current-buffer clone
                  (spy-on 'selected-window :and-return-value 'mock-window)
                  (spy-on 'window-buffer :and-return-value (current-buffer))

                  ;; The Action: User toggles in the cloned buffer
                  (tedit-save-buffer-toggle)

                  ;; Proof: The clone inherits intended-state='hard
                  ;; (non-nil), so Phase 1 init is skipped and
                  ;; native-read-only-p is never re-captured from the
                  ;; inherited buffer-read-only=t.  Toggle is not
                  ;; inhibited.
                  (expect tedit--native-read-only-p :to-be nil)
                  (expect tedit--intended-state :to-be 'none)
                  (expect buffer-read-only :to-be nil))
              (kill-buffer clone))))))

    (it "does not re-capture native read-only even after always-lock-on-switch reset"
      (let ((tedit-hard-lock-major-mode-list '(text-mode)))
        (with-temp-buffer
          (text-mode)
          (setq buffer-file-name "/tmp/base.txt")
          (setq buffer-read-only t)
          (setq tedit--native-read-only-p nil)
          (setq tedit--intended-state 'hard)

          (let ((clone (clone-indirect-buffer "*clone-test*" nil)))
            (unwind-protect
                (with-current-buffer clone
                  ;; Simulate always-lock-on-switch wiping the intent
                  (setq tedit--intended-state nil)

                  ;; Phase 1 init runs, but local-variable-p is t in
                  ;; the clone, so native-read-only-p is NOT re-captured
                  ;; from the inherited buffer-read-only=t.
                  (expect (local-variable-p 'tedit--native-read-only-p) :to-be t)
                  (expect tedit--native-read-only-p :to-be nil))
              (kill-buffer clone)))))))

  (describe "Engine Safety and Edge Cases"
    (it "safely handles buffer-name execution in match-rules-p without nil-checks"
      (with-temp-buffer
        (rename-buffer "live-buffer")
        ;; Proof: (buffer-name) of the current buffer is guaranteed to be a string.
        (expect (buffer-name) :to-equal "live-buffer")
        (expect (tedit--match-rules-p '("^live") nil nil) :to-be-truthy)))

    (it "idempotently ignores double-execution from overlapping window hooks"
      (with-temp-buffer
        (setq tedit--intended-state 'hard)
        (setq buffer-read-only nil)

        ;; Spy on the native Emacs function to count physical mutations
        (spy-on 'read-only-mode :and-call-through)

        ;; Simulate C-x 4 b (switch-to-buffer-other-window) which triggers BOTH
        ;; window-selection-change AND window-buffer-change hooks back-to-back.
        (tedit--reconcile (current-buffer))
        (tedit--reconcile (current-buffer))

        ;; Proof: The engine evaluated twice, but physically mutated the buffer exactly ONCE
        (expect 'read-only-mode :to-have-been-called-times 1)
        (expect buffer-read-only :to-be t)))

    (it "allows toggling unmanaged buffers if they match the always-allow whitelist"
      (let ((tedit-hard-lock-major-mode-list nil)
            (tedit-toggle-inhibit-unmanaged-buffers t)
            (tedit-toggle-always-allow-mode-list '(fundamental-mode))
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (fundamental-mode)
          (setq tedit--intended-state 'unmanaged)
          (setq buffer-read-only t)

          ;; The Action: Toggle an unmanaged buffer that is explicitly whitelisted
          (tedit-save-buffer-toggle)

          ;; Proof: The whitelist bypassed the inhibition block, allowing the toggle to unlock it
          (expect tedit--intended-state :to-be 'none)
          (expect buffer-read-only :to-be nil))))
    )
  )

;;; tedit-test.el ends here
