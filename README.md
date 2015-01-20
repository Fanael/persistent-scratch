[![Melpa Status](http://melpa.org/packages/persistent-scratch-badge.svg)](http://melpa.org/#/persistent-scratch)
[![Melpa Stable Status](http://stable.melpa.org/packages/persistent-scratch-badge.svg)](http://stable.melpa.org/#/persistent-scratch)

# Persistent scratch

`persistent-scratch` is an Emacs package that preserves the state of scratch
buffers accross Emacs sessions by saving the state to and restoring it from a
file.

## Installation

The package is available in [MELPA](http://melpa.org/) and
[MELPA Stable](http://stable.melpa.org/).

If you have MELPA or MELPA Stable in `package-archives`, use

    M-x package-install RET persistent-scratch RET

If you don't, open `persistent-scratch.el` in Emacs and call
`package-install-from-buffer`.

Other installation methods are unsupported.

## Usage

To save the current state of scratch buffers to file indicated by
`persistent-scratch-save-file`:

    M-x persistent-scratch-save

To restore scratch buffers from `persistent-scratch-save-file`:

    M-x persistent-scratch-restore

To save the state to an arbitrary file:

    M-x persistent-scratch-save-to-file

To restore the state from an arbitrary file:

    M-x persistent-scratch-restore-from-file

To toggle periodic autosave:

    M-x persistent-scratch-autosave-mode

To create a new backup file (only when backup is enabled, see
`persistent-scratch-backup-directory`), so that the next
`persistent-scratch-save` won't overwrite the existing backup:

    M-x persistent-scratch-new-backup

To customize the save file path, what state to save, the autosave period, what
buffers are considered scratch buffers and whether to backup old saved states:

    M-x customize-group RET persistent-scratch RET

## Init file considerations

Variables can be customized either via `customize` or by setting them via `setq`
directly.

Autosave can be enabled automatically like any other minor mode:
```emacs-lisp
(persistent-scratch-autosave-mode 1)
```

If you want the scratch buffers to be restored on Emacs start, the
`persistent-scratch-restore` call in the init file should be wrapped in
`ignore-errors` or `with-demoted-errors`, as `persistent-scratch-restore`
signals when `persistent-scratch-save-file` is not found. For example:
```emacs-lisp
(with-demoted-errors "Failed to restore scratch buffers: %S"
  (persistent-scratch-restore))
```
