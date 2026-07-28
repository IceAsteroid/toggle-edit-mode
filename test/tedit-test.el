;;; test/tedit-test.el --- Buttercup tests for tedit.el -*- lexical-binding: t -*-

(require 'buttercup)
(require 'tedit)

;; Enable tedit globally for the duration of the test suite
(tedit-mode 1)

(describe "Tedit Core Engine"

  (describe "tedit--compute-effective-state (The Brain)"

    (it "lazily captures native OS lock on first focus"
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

    (it "blur-unlocks managed hard-locked buffers in the background"
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

    (it "NEVER blur-unlocks an OS natively write-protected file"
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

          ;; The brain sees a soft-lock rule, but the OS says read-only, so it safely merges them.
          (expect (tedit--compute-effective-state (current-buffer)) :to-be 'dual))))

    ;; FIX: We test Rule Conflicts here, not OS Conflicts!
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
          (expect (tedit--compute-effective-state (current-buffer)) :to-be 'soft)))))


  (describe "tedit--reconcile (The Physical Enforcer)"

    (it "physically applies both read-only and soft-lock modes for a DUAL state"
      (with-temp-buffer
        ;; Spy on the brain to force a 'dual state return, isolating the Enforcer's logic
        (spy-on 'tedit--compute-effective-state :and-return-value 'dual)
        (setq buffer-read-only nil)

        (tedit--reconcile (current-buffer))

        ;; Proof: Both physical DOM manipulations occurred
        (expect buffer-read-only :to-be t)
        (expect (bound-and-true-p tedit-soft-lock-special--mode) :to-be t))))


  (describe "Mode Change Interactions (The Hooks)"

    (describe "When tedit-clear-hard-lock-before-mode-change is TRUE"

      (it "physically drops the lock and clears cache if apply-locks is TRUE"
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

      (it "physically drops the lock but DEFERS evaluation if apply-locks is FALSE"
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
            (expect tedit--needs-re-evaluation :to-be t))))))


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

    ;; NEW: Proving the Dead Buffer Guard
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
          (expect (tedit--focus-handler) :not :to-throw)))))


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

          ;; Proof: OS guard overrides the user's manual toggle attempt
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "syncs physical C-x C-q reality before cycling an unmanaged buffer"
      (let ((tedit-hard-lock-major-mode-list nil)
            (tedit-toggle-save-on-toggle nil)
            ;; TRAP: This MUST be nil, otherwise the test aborts before syncing logic occurs.
            (tedit-toggle-inhibit-unmanaged-buffers nil))
        (with-temp-buffer
          (fundamental-mode) ;; Unmanaged
          (setq tedit--intended-state 'unmanaged)
          (setq buffer-read-only t) ;; User physically locked it via C-x C-q

          ;; The toggle syncs 'unmanaged -> 'hard -> 'none
          (tedit-save-buffer-toggle)

          (expect tedit--intended-state :to-be 'none)
          (expect buffer-read-only :to-be nil))))

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
          ;; TRAP: To test the cycle target, the buffer must start fully unlocked.
          ;; If it starts at 'soft, the toggle logic unconditionally unlocks it to 'none!
          (setq tedit--intended-state 'none)

          (tedit-save-buffer-toggle)
          (expect tedit--intended-state :to-be 'dual))))

    (it "cycles to 'hard when method is set to 'hard-lock"
      (let ((tedit-soft-lock-major-mode-list '(text-mode))
            (tedit-soft-lock-toggle-method 'hard-lock)
            (tedit-toggle-save-on-toggle nil))
        (with-temp-buffer
          (text-mode)
          (setq tedit--intended-state 'none)

          (tedit-save-buffer-toggle)
          (expect tedit--intended-state :to-be 'hard)))))

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

          (expect hook-ran :to-be t)))))

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

          ;; Proof: Tedit owned this lock, so it cleans up the physical DOM state
          (expect buffer-read-only :to-be nil)))))
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

          ;; The Action: User saves to an OS-protected location
          (setq buffer-file-name "/etc/protected.txt")
          (spy-on 'file-writable-p :and-return-value nil)

          (tedit--after-save-hook)

          ;; Proof: The engine detected the OS restriction and locked it
          (expect tedit--native-read-only-p :to-be t)
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "drops OS protection when a root file is saved to a writable home directory"
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

          ;; Proof: The engine dropped the OS guard, but kept the base rule ('hard)
          (expect tedit--native-read-only-p :to-be nil)
          (expect tedit--intended-state :to-be 'hard)
          (expect buffer-read-only :to-be t))))

    (it "blur-unlocks dynamically if a root file is saved to home while in the BACKGROUND"
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
          ;; and now writable, the engine safely BLUR-UNLOCKS the physical DOM!
          (expect tedit--native-read-only-p :to-be nil)
          (expect tedit--intended-state :to-be 'hard) ;; The brain still wants it locked...
          (expect buffer-read-only :to-be nil))))     ;; ...but reality is unlocked for async writes!
    )
