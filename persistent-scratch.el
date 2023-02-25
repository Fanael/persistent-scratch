;;; persistent-scratch.el --- Preserve the scratch buffer across Emacs sessions -*- lexical-binding: t -*-

;; Author: Fanael Linithien <fanael4@gmail.com>
;; URL: https://github.com/Fanael/persistent-scratch
;; Package-Version: 0.3.9
;; Package-Requires: ((emacs "24"))

;; This file is NOT part of GNU Emacs.

;; Copyright (c) 2015-2023, Fanael Linithien
;; All rights reserved.
;;
;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions are
;; met:
;;
;;   * Redistributions of source code must retain the above copyright
;;     notice, this list of conditions and the following disclaimer.
;;   * Redistributions in binary form must reproduce the above copyright
;;     notice, this list of conditions and the following disclaimer in the
;;     documentation and/or other materials provided with the distribution.
;;
;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
;; IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
;; TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
;; PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
;; OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
;; EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
;; PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;; PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;; LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;;; Commentary:

;; Preserve the state of scratch buffers across Emacs sessions by saving the
;; state to and restoring it from a file, with autosaving and backups.
;;
;; Save scratch buffers: `persistent-scratch-save' and
;; `persistent-scratch-save-to-file'.
;; Restore saved state: `persistent-scratch-restore' and
;; `persistent-scratch-restore-from-file'.
;;
;; To control where the state is saved, set `persistent-scratch-save-file'.
;; What exactly is saved is determined by `persistent-scratch-what-to-save'.
;; What buffers are considered scratch buffers is determined by
;; `persistent-scratch-scratch-buffer-p-function'. By default, only the
;; `*scratch*' buffer is a scratch buffer.
;;
;; Autosave can be enabled by turning `persistent-scratch-autosave-mode' on.
;;
;; Backups of old saved states are off by default, set
;; `persistent-scratch-backup-directory' to a directory to enable them.
;;
;; To both enable autosave and restore the last saved state on Emacs start, add
;;   (persistent-scratch-setup-default)
;; to the init file. This will NOT error when the save file doesn't exist.
;;
;; To just restore on Emacs start, it's a good idea to call
;; `persistent-scratch-restore' inside an `ignore-errors' or
;; `with-demoted-errors' block.

;;; Code:
(eval-when-compile (require 'pcase))

(defgroup persistent-scratch nil
  "Preserve the state of scratch buffers across Emacs sessions."
  :group 'files
  :prefix "persistent-scratch-")

(defcustom persistent-scratch-scratch-buffer-p-function
  #'persistent-scratch-default-scratch-buffer-p
  "Function determining whether the current buffer is a scratch buffer.
When this function, called with no arguments, returns non-nil, the current
buffer is assumed to be a scratch buffer, thus becoming eligible for
\(auto-)saving."
  :type 'function
  :group 'persistent-scratch)

(defcustom persistent-scratch-save-file
  (expand-file-name ".persistent-scratch" user-emacs-directory)
  "File to save to the scratch buffers to."
  :type 'file
  :group 'persistent-scratch)

(defcustom persistent-scratch-before-save-commit-functions '()
  "Abnormal hook for performing operations before committing a save file.

Functions are called with one argument TEMP-FILE: the path of the
temporary file containing uncommitted save data, which will be moved to
`persistent-scratch-save-file' after the hook runs.

The intended use of this hook is to allow changing the file system
permissions of the file before committing."
  :type 'hook
  :group 'persistent-scratch)

(defcustom persistent-scratch-what-to-save
  '(major-mode point narrowing)
  "Specify what scratch buffer properties to save.

The buffer name and the buffer contents are always saved.

It's a list containing some or all of the following values:
 - `major-mode': save the major mode.
 - `point': save the positions of `point' and `mark'.
 - `narrowing': save the region the buffer is narrowed to.
 - `text-properties': save the text properties of the buffer contents."
  :type '(repeat :tag "What to save"
                 (choice :tag "State to save"
                         (const :tag "Major mode"
                                major-mode)
                         (const :tag "Point and mark"
                                point)
                         (const :tag "Narrowing"
                                narrowing)
                         (const :tag "Text properties of contents"
                                text-properties)))
  :group 'persistent-scratch)

(defcustom persistent-scratch-autosave-interval 300
  "The interval, in seconds, between autosaves of scratch buffers.

Can be either a number N, in which case scratch buffers are saved every N
seconds, or a cons cell (`idle' . N), in which case scratch buffers are saved
every time Emacs becomes idle for at least N seconds.

Setting this variable when `persistent-scratch-autosave-mode' is already on does
nothing, call `persistent-scratch-autosave-mode' for it to take effect."
  :type '(radio number
                (cons :tag "When idle for" (const idle) number))
  :group 'persistent-scratch)

(defcustom persistent-scratch-backup-directory nil
  "Directory to save old versions of scratch buffer saves to.
When nil, backups are disabled."
  :type '(choice directory
                 (const :tag "Disabled" nil))
  :group 'persistent-scratch)

(defcustom persistent-scratch-backup-filter #'ignore
  "Function returning the list of file names of old backups to delete.
By default, no backups are deleted.
This function is called with one argument, a list of file names in
`persistent-scratch-backup-directory'; this list is *not* sorted in any way."
  :type 'function
  :group 'persistent-scratch)

(defcustom persistent-scratch-backup-file-name-format "%Y-%m-%d--%H-%M-%S-%N"
  "Format of backup file names, for `format-time-string'."
  :type 'string
  :group 'persistent-scratch)

;;;###autoload
(defun persistent-scratch-save (&optional file)
  "Save the current state of scratch buffers.
When FILE is non-nil, the state is saved to FILE; when nil or when called
interactively, the state is saved to `persistent-scratch-save-file'.
What state exactly is saved is determined by `persistent-scratch-what-to-save'.

When FILE is nil and `persistent-scratch-backup-directory' is non-nil, a copy of
`persistent-scratch-save-file' is stored in that directory, with a name
representing the time of the last `persistent-scratch-new-backup' call."
  (interactive)
  (let* ((actual-file (or file persistent-scratch-save-file))
         (tmp-file (concat actual-file ".new"))
         (saved-state (persistent-scratch--save-buffers-state)))
    (let ((old-umask (default-file-modes)))
      (set-default-file-modes #o600)
      (unwind-protect
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (cdr saved-state) nil tmp-file nil 0))
        (set-default-file-modes old-umask)))
    (run-hook-with-args 'persistent-scratch-before-save-commit-functions tmp-file)
    (rename-file tmp-file actual-file t)
    (dolist (buffer (car saved-state))
      (with-current-buffer buffer
        (set-buffer-modified-p nil)))
    (when (called-interactively-p 'interactive)
      (message "Wrote persistent-scratch file %s" actual-file)))
  (unless file
    (persistent-scratch--update-backup)
    (persistent-scratch--cleanup-backups)))

;;;###autoload
(defun persistent-scratch-save-to-file (file)
  "Save the current state of scratch buffers.
The state is saved to FILE.

When called interactively, prompt for the file name, which is the only
difference between this function and `persistent-scratch-save'.

See `persistent-scratch-save'."
  (interactive "F")
  (persistent-scratch-save file))

;;;###autoload
(defun persistent-scratch-restore (&optional file)
  "Restore the scratch buffers.
Load FILE and restore all saved buffers to their saved state.

FILE is a file to restore scratch buffers from; when nil or when called
interactively, `persistent-scratch-save-file' is used.

This is a potentially destructive operation: if there's an open buffer with the
same name as a saved buffer, the contents of that buffer will be overwritten."
  (interactive)
  (let ((save-data
         (read
          (with-temp-buffer
            (let ((coding-system-for-read 'utf-8-unix))
              (insert-file-contents (or file persistent-scratch-save-file)))
            (buffer-string)))))
    (dolist (saved-buffer save-data)
      (with-current-buffer (get-buffer-create (aref saved-buffer 0))
        (erase-buffer)
        (insert (aref saved-buffer 1))
        (funcall (or (aref saved-buffer 3) #'ignore))
        (let ((point-and-mark (aref saved-buffer 2)))
          (when point-and-mark
            (goto-char (car point-and-mark))
            (set-mark (cdr point-and-mark))))
        (let ((narrowing (aref saved-buffer 4)))
          (when narrowing
            (narrow-to-region (car narrowing) (cdr narrowing))))
        ;; Handle version 2 fields if present.
        (when (>= (length saved-buffer) 6)
          (unless (aref saved-buffer 5)
            (deactivate-mark)))))))

;;;###autoload
(defun persistent-scratch-restore-from-file (file)
  "Restore the scratch buffers from a file.
FILE is a file storing saved scratch buffer state.

When called interactively, prompt for the file name, which is the only
difference between this function and `persistent-scratch-restore'.

See `persistent-scratch-restore'."
  (interactive "f")
  (persistent-scratch-restore file))

(defvar persistent-scratch--auto-restored nil)

(defun persistent-scratch--auto-restore ()
  "Automatically restore the scratch buffer once per session."
  (unless persistent-scratch--auto-restored
    (condition-case err
        (persistent-scratch-restore)
      (error
       (message "Failed to restore scratch buffers: %S" err)
       nil))
    (setq persistent-scratch--auto-restored t)))

(defvar persistent-scratch-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap save-buffer] 'persistent-scratch-save)
    (define-key m [remap write-file] 'persistent-scratch-save-to-file)
    m)
  "The keymap for `persistent-scratch-mode'.")

;;;###autoload
(define-minor-mode persistent-scratch-mode
  "Utility mode that remaps `save-buffer' and `write-file' to their
`persistent-scratch' equivalents.

This mode cannot be enabled in buffers for which
`persistent-scratch-scratch-buffer-p-function' is nil.

\\{persistent-scratch-mode-map}"
  :lighter " PS"
  (when (and persistent-scratch-mode
             (not (funcall persistent-scratch-scratch-buffer-p-function)))
    (setq persistent-scratch-mode nil)
    (error
     "This buffer isn't managed by `persistent-scratch', not enabling mode.")))

;;;###autoload
(define-minor-mode persistent-scratch-autosave-mode
  "Autosave scratch buffer state.
Every `persistent-scratch-autosave-interval' seconds and when Emacs quits, the
state of all active scratch buffers is saved.
This uses `persistent-scratch-save', which see.

Toggle Persistent-Scratch-Autosave mode on or off.
With a prefix argument ARG, enable Persistent-Scratch-Autosave mode if ARG is
positive, and disable it otherwise. If called from Lisp, enable the mode if ARG
is omitted or nil, and toggle it if ARG is `toggle'.
\\{persistent-scratch-autosave-mode-map}"
  :init-value nil
  :lighter ""
  :keymap nil
  :global t
  (persistent-scratch--auto-restore)
  (persistent-scratch--turn-autosave-off)
  (when persistent-scratch-autosave-mode
    (persistent-scratch--turn-autosave-on)))

(defvar persistent-scratch--current-backup-time (current-time))

;;;###autoload
(defun persistent-scratch-new-backup ()
  "Create a new scratch buffer save backup file.
The next time `persistent-scratch-save' is called, it will create a new backup
file and use that file from now on."
  (interactive)
  (setq persistent-scratch--current-backup-time (current-time)))

;;;###autoload
(defun persistent-scratch-setup-default ()
  "Enable `persistent-scratch-autosave-mode' and restore the scratch buffers.
When an error occurs while restoring the scratch buffers, it's demoted to a
message."
  (persistent-scratch--auto-restore)
  (persistent-scratch-autosave-mode))

(defun persistent-scratch-default-scratch-buffer-p ()
  "Return non-nil iff the current buffer's name is *scratch*."
  (string= (buffer-name) "*scratch*"))

;;;###autoload
(defun persistent-scratch-keep-n-newest-backups (n)
  "Return a backup filter that keeps N newest backups.
The returned function is suitable for `persistent-scratch-backup-filter'.

Note: this function assumes that increasing time values result in
lexicographically increasing file names when formatted using
`persistent-scratch-backup-file-name-format'."
  (lambda (files)
    (nthcdr n (sort files (lambda (a b) (string-lessp b a))))))

;;;###autoload
(defun persistent-scratch-keep-backups-not-older-than (diff)
  "Return a backup filter that keeps backups newer than DIFF.
DIFF may be either a number representing the number of second, or a time value
in the format returned by `current-time' or `seconds-to-time'.
The returned function is suitable for `persistent-scratch-backup-filter'.

Note: this function assumes that increasing time values result in
lexicographically increasing file names when formatted using
`persistent-scratch-backup-file-name-format'."
  (when (numberp diff)
    (setq diff (seconds-to-time diff)))
  (lambda (files)
    (let ((limit (format-time-string persistent-scratch-backup-file-name-format
                                     (time-subtract (current-time) diff))))
      (delq nil (mapcar (lambda (file)
                          (when (string-lessp file limit)
                            file))
                        files)))))

(defun persistent-scratch--save-buffers-state ()
  "Save the current state of scratch buffers.

The returned value is a cons cell (BUFFER-LIST . STATE-STRING)."
  (let ((buffers '())
        (save-data '()))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (funcall persistent-scratch-scratch-buffer-p-function)
          (push buffer buffers)
          (push (persistent-scratch--get-buffer-state) save-data))))
    (let ((print-quoted t)
          (print-circle t)
          (print-gensym t)
          (print-escape-newlines nil)
          (print-length nil)
          (print-level nil))
      (cons buffers (prin1-to-string save-data)))))

;; Compatibility shim for Emacs 24.{1, 2}
(defalias 'persistent-scratch-buffer-narrowed-p
  (if (fboundp 'buffer-narrowed-p)
      #'buffer-narrowed-p
    (lambda ()
      "Return non-nil if the current buffer is narrowed."
      (< (- (point-min) (point-max)) (buffer-size)))))

(defun persistent-scratch--get-buffer-state ()
  "Get an object representing the current buffer save state.
The returned object is printable and readable.
The exact format is undocumented, but must be kept in sync with what
`persistent-scratch-restore' expects."
  (vector
   ;; Version 1 fields.
   (buffer-name)
   (save-restriction
     (widen)
     (if (memq 'text-properties persistent-scratch-what-to-save)
         (buffer-string)
       (buffer-substring-no-properties 1 (1+ (buffer-size)))))
   (when (memq 'point persistent-scratch-what-to-save)
     (cons (point) (ignore-errors (mark))))
   (when (memq 'major-mode persistent-scratch-what-to-save)
     major-mode)
   (when (and (persistent-scratch-buffer-narrowed-p)
              (memq 'narrowing persistent-scratch-what-to-save))
     (cons (point-min) (point-max)))
   ;; Version 2 fields.
   (when (memq 'point persistent-scratch-what-to-save)
     (or (not transient-mark-mode) (region-active-p)))))

(defun persistent-scratch--update-backup ()
  "Copy the save file to the backup directory."
  (when persistent-scratch-backup-directory
    (let ((original-name persistent-scratch-save-file)
          (new-name
           (let ((file-name
                  (format-time-string
                   persistent-scratch-backup-file-name-format
                   persistent-scratch--current-backup-time)))
             (expand-file-name file-name persistent-scratch-backup-directory))))
      (make-directory persistent-scratch-backup-directory t)
      (copy-file original-name new-name t nil t t))))

(defun persistent-scratch--cleanup-backups ()
  "Clean up old backups.
It's done by calling `persistent-scratch-backup-filter' on a list of all files
in the backup directory and deleting all returned file names."
  (when persistent-scratch-backup-directory
    (let* ((directory
            (file-name-as-directory persistent-scratch-backup-directory))
           (file-names (directory-files directory nil nil t)))
      (setq file-names (delq nil (mapcar (lambda (name)
                                           (unless (member name '("." ".."))
                                             name))
                                         file-names)))
      (dolist (file-to-delete
               (funcall persistent-scratch-backup-filter file-names))
        (delete-file (concat directory file-to-delete))))))

(defvar persistent-scratch--autosave-timer nil)

(defun persistent-scratch--turn-autosave-off ()
  "Turn `persistent-scratch-autosave-mode' off."
  (remove-hook 'kill-emacs-hook #'persistent-scratch-save)
  (when persistent-scratch--autosave-timer
    (cancel-timer persistent-scratch--autosave-timer)
    (setq persistent-scratch--autosave-timer nil)))

(defun persistent-scratch--turn-autosave-on ()
  "Turn `persistent-scratch-autosave-mode' on."
  (add-hook 'kill-emacs-hook #'persistent-scratch-save)
  (setq persistent-scratch--autosave-timer
        (pcase persistent-scratch-autosave-interval
          (`(idle . ,x) (run-with-idle-timer x x #'persistent-scratch-save))
          (x (run-with-timer x x #'persistent-scratch-save)))))

(provide 'persistent-scratch)
;;; persistent-scratch.el ends here
