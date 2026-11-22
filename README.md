# Subvim
### The fugitive SVN clone

Subvim brings [vim-fugitive](https://github.com/tpope/vim-fugitive)'s workflow
to Subversion. Same keys, same commands: `:Git` is `:Svn`, and `:Gedit`,
`:Gdiffsplit`, `:Gwrite`... are `:Sedit`, `:Sdiffsplit`, `:Swrite`...

```vim
Plug 'jacksym/subvim'
```

Open a file in a working copy and run `:Svn`:

```
Head: trunk
URL: ^/trunk
Revision: 41:42M
Help: g?

Unversioned (1)
? notes.txt

Unstaged (1)
M src/util.c

Staged (2)
M src/main.c
A src/new.c
```

`s` stages, `u` unstages, `=` shows an inline diff, `X` discards, `cc`
commits only what is staged. svn has no staging area, so subvim uses an svn
changelist (`subvim-staged`) for it, which TortoiseSVN shows too.

Also: blame (`:Svn blame`), history in quickfix (`:Sclog`), files at any
revision (`:Sedit foo.c@123`), diffs against BASE or any revision
(`:Sdiffsplit`), three-way conflict diffs, branches (`:Svn branch`,
`:Svn switch`), stash (`czz`/`czp`), svn:ignore (`gI`), reverting revisions
(`crc`).

See `:help subvim` for everything, including what isn't supported (amend,
rebase, hunk staging).

## Tests

`test/run.sh` runs the suite headlessly against throwaway local svn
repositories (needs `vim` 9.1+, `svn` and `svnadmin`). Pass test names to run
only those, e.g. `test/run.sh blame stash_roundtrip`.
