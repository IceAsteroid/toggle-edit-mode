;;; edition-mode.el --- Implement to toggle edition in buffers -*- lexical-binding: t -*-

(eval-when-compile
  (declare-function company-abort "company"))

(defvar edition-enable-derived-mode-list
  '(prog-mode
    text-mode
    conf-mode)
  "A list of deriving modes to turn on `read-only-mode' when in `edition-mode'")

(defvar edition-enable-major-mode-list '()
  "Besides `edition-enable-derived-mode-list', enable for `read-only-mode' in
the list when in `edition-mode'.")

(defvar edition-toggle-key "C-`"
  "Key to execute `edition-save-buffer-toggle'.")

(defvar edition-no-save-buffer-list
  '(;; "\\*.*\\*" ;exclude special buffers that are surrounded by stars. Included already.
    )
  "A list of regexps matching buffers to not trigger save when toggle
edition. Buffers like `*scratch*’ that have files are already automatically
skipped in `edition-save-buffer-toggle’.")

(defvar edition-find-file-enable t
  "Turn off `read-only-mode' when visiting a file for `edition-mode'.")

;; Replaced by gemini pro's answer to solve file opening races that would not
;; enable read-only as intended for new visited files.
;; (defvar edition--find-file-buffer-name nil
;;   "Set to t when `find-file' is executed. Otherwise nil. Internal use. ")

(defvar edition--enable-when-treemacs-persist-p t)

(defvar edition--theme-cursor-color (face-attribute 'cursor :background)
  "Current theme's original cursor color.")

(defvar edition--cursor-color-refresh-timer nil
  "Refresh cursor color when edition state changes.")

(defvar edition--cursor-color-refresh-timer-delay 0.1)

(defvar edition--cursor-change-changed-p nil)

(defvar edition--toggle-key-original-command nil
  "Command if bound in the `edition-toggle-key' before `edition-mode' is activated.")

(defvar edition-mode-no-save-buffers-regexp nil
  "Regexp in OR logic for each excluded buffer to not save when
`edition-save-buffer-toggle' runs, generateed from
`edition-no-save-buffer-list'.")

;; Unused variable, leave it here for future changes.
(defvar my/window-buffer-cache (make-hash-table :test 'eq))

(defun edition-mode--set-no-save-buffers-regexp ()
  "Convert `edition-no-save-buffer-list' into a regexp."
  (setq edition-mode-no-save-buffers-regexp
        (when edition-no-save-buffer-list
          (mapconcat 'identity edition-no-save-buffer-list "\\|"))))

;; Unused function, leave it here for future changes.
(defun my/handle-displayed-buffer-change ()
  "Check each window and run code if its displayed buffer changed."
  (dolist (win (window-list))
    (let* ((current (window-buffer win))
           (cached  (gethash win my/window-buffer-cache)))
      (unless (eq current cached)
        (message "Window %s changed buffer from %S to %S" win cached current)
        (puthash win current my/window-buffer-cache)))))

;; (defun edition--disable-when-window-changed ()
;;   (catch 'return
;;     (unless edition--enable-when-treemacs-persist-p
;;       (setq edition--enable-when-treemacs-persist-p t)
;;       (setq edition--find-file-buffer-name nil)
;;       (throw 'return t))
;;     (when-let* ((buffer-live-p edition--find-file-buffer-name)
;;                 (win (get-buffer-window
;;                       edition--find-file-buffer-name
;;                       'visible)))
;;       (with-selected-window win
;;         (when (or (seq-some 'derived-mode-p
;;                             edition-enable-derived-mode-list)
;;                   (seq-some
;;                    (lambda (x)
;;                      (eq major-mode x))
;;                    edition-enable-major-mode-list))
;;           (read-only-mode 1)))
;;       (setq edition--find-file-buffer-name nil)
;;       (throw 'return t))))

;; (defun edition--treemacs-persist-set-disable ()
;;   (setq edition--enable-when-treemacs-persist-p nil))

;; (defun edition--find-file-set-disable ()
;;   (setq edition--find-file-buffer-name (get-file-buffer buffer-file-name)))

;; 2. Add a new buffer-local variable
(defvar-local edition--pending-readonly-check nil
  "Flag to indicate this buffer needs its read-only status checked when it becomes
visible.")

(defun edition--disable-when-window-changed ()
  (catch 'return
    (unless edition--enable-when-treemacs-persist-p
      (setq edition--enable-when-treemacs-persist-p t)
      ;; (setq edition--find-file-buffer-name nil) ;; No longer needed
      (throw 'return t))

    ;; 3. Scan ALL visible windows instead of checking one global variable
    (dolist (win (window-list))
      (with-selected-window win
        (when edition--pending-readonly-check
          (when (or (seq-some 'derived-mode-p edition-enable-derived-mode-list)
                    (seq-some (lambda (x) (eq major-mode x)) edition-enable-major-mode-list))
            (read-only-mode 1))
          ;; Clear the flag so we don't check this buffer again
          (setq edition--pending-readonly-check nil))))))

(defun edition--treemacs-persist-set-disable ()
  (setq edition--enable-when-treemacs-persist-p nil))

(defun edition--find-file-set-disable ()
  ;; 4. Mark the CURRENT buffer instead of setting a global variable
  (setq edition--pending-readonly-check t))

;;; END REPLACEMENT ;;;


(defun edition-store-theme-cursor-color-advice (&rest _)
  (setq edition--theme-cursor-color (face-attribute 'cursor :background)))

(defun my/cursor-change-color-read-only-mode()
  "Run the body only when `edition--cursor-change-changed-p’ is set to t by the
`edition--cursor-change-when-edition-changed-in-post-command-hook’ function run
by the hook `post-command-hook’."
  (when edition--cursor-change-changed-p
    (while-no-input
      (if buffer-read-only
          (set-cursor-color "red2")
        (set-cursor-color edition--theme-cursor-color))
      (setq edition--cursor-change-changed-p nil))))

(defun edition--cursor-change-when-edition-changed ()
  (setq edition--cursor-change-changed-p t))

(defvar edition-no-save-buffer-hook nil
  "Run the hook when a buffer is excluded as a no-save buffer for `edition-mode',
`before-save-hook' & `after-save-hook' won't run, you can add functions here for
such a buffer.")

(defvar-local ia/edition-run-hook-last-modified-tick nil
  "The `buffer-chars-modified-tick' in the last invocation of
`edition-save-buffer-toggle', that use to compare if buffer is changed since the
last invocation of the function.")

;; The function is modified to not run `before-save-hook' & `after-save-hook'
;; when buffer is not modified, as othwerise it can cause potential issues for
;; funcions in hooks that depend on buffer modification.
(defun edition-save-buffer-toggle ()
  "Toggle `read-only-mode’ in a buffer and save buffer when `read-only-mode’ is
on. Do not add save buffer feature to ‘read-only-mode-hook’ directly, that may
cause potential issues."
  (interactive)
  (unless buffer-read-only
    ;; Run when buffer has file, otherwise run the else clause.
    (if (and (buffer-file-name)
             (not (buffer-match-p edition-mode-no-save-buffers-regexp
                                  (current-buffer))))
        (basic-save-buffer)
      ;; A func in hook that fails terminates this func, so below
      ;; `read-only-mode' doesn't activate, the second invocation does if no
      ;; buffer change. This simulates `basic-save-buffer' in the above if
      ;; clause for buffer that has no file, which should not rely on
      ;; `buffer-modified-p'.
      (if (eq ia/edition-run-hook-last-modified-tick (buffer-chars-modified-tick))
          (with-demoted-errors "error: edition-no-save-buffer-hook: %s"
            (run-hooks 'edition-no-save-buffer-hook))
        (unwind-protect
            (condition-case err
                (run-hooks 'edition-no-save-buffer-hook)
              (error (error "error: edition-no-save-buffer-hook: %s" (error-message-string err))))
        (setq-local ia/edition-run-hook-last-modified-tick (buffer-chars-modified-tick))))))
  (read-only-mode 'toggle))

;;;###autoload
(define-minor-mode edition-mode
  "Toggle `edition-mode' on or off."
  :group 'edition
  :global t
  :lighter nil
  (if edition-mode
      (progn
        (edition-mode--set-no-save-buffers-regexp)
        (add-hook 'post-command-hook 'edition--cursor-change-when-edition-changed)
        (setq edition--toggle-key-original-command
              (keymap-lookup global-map edition-toggle-key))
        (keymap-set global-map edition-toggle-key 'edition-save-buffer-toggle)

        (setq edition--cursor-color-refresh-timer
              (run-with-idle-timer
               edition--cursor-color-refresh-timer-delay
               t
               'my/cursor-change-color-read-only-mode))

        (with-eval-after-load 'company
          (defun my/abort-company-if-edition-off ()
            (when buffer-read-only
              (company-abort)))
          (defun my/setup-edition-in-company ()
            (add-hook 'read-only-mode-hook 'my/abort-company-if-edition-off nil t))
          (add-hook 'company-mode-hook 'my/setup-edition-in-company))

        (when edition-find-file-enable
          (add-hook 'window-configuration-change-hook 'edition--disable-when-window-changed)
          (add-hook 'find-file-hook 'edition--find-file-set-disable)
          (advice-add 'treemacs--persist :before 'edition--treemacs-persist-set-disable)
          (advice-add 'enable-theme :after 'edition-store-theme-cursor-color-advice))
        )
    (remove-hook 'window-configuration-change-hook 'edition--disable-when-window-changed)
    (remove-hook 'find-file-hook 'edition--find-file-set-disable)
    (advice-remove 'treemacs--persist 'edition--treemacs-persist-set-disable)
    (advice-remove 'enable-theme 'edition-store-theme-cursor-color-advice)
    (remove-hook 'post-command-hook 'edition--cursor-change-when-edition-changed)

    (if edition--toggle-key-original-command
        (keymap-set global-map edition-toggle-key edition--toggle-key-original-command)
      (keymap-unset global-map "C-`" 'edition-save-buffer-toggle))

    (remove-hook 'company-mode-hook 'my/setup-edition-in-company)

    (cancel-timer edition--cursor-color-refresh-timer)
    (setq edition--cursor-color-refresh-timer nil)
    ))

(provide 'edition-mode)
;;; edition-mode.el ends here
