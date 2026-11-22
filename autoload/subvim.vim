" Location:     autoload/subvim.vim
" Subversion counterpart to fugitive.vim.  Keybindings follow fugitive so the
" workflow is the same.  Git's index is emulated with an svn changelist
" (g:subvim_changelist); directories, which svn cannot put in a changelist,
" are tracked in .svn/subvim/staged-dirs.

if exists('g:autoloaded_subvim')
  finish
endif
let g:autoloaded_subvim = 1

let s:ignore_line = '--This line, and those below, will be ignored--'
let s:sep_line = '^-\{72}$'

" Section: Utility {{{1

function! s:Throw(msg) abort
  throw 'subvim: ' . a:msg
endfunction

function! s:Error(msg) abort
  echohl ErrorMsg
  for line in split(a:msg, "\n")
    echomsg line =~# '^subvim: ' ? line : 'subvim: ' . line
  endfor
  echohl NONE
  return ''
endfunction

function! s:Warn(msg) abort
  echohl WarningMsg
  echomsg 'subvim: ' . a:msg
  echohl NONE
  return ''
endfunction

function! s:Catch() abort
  return s:Error(substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', ''))
endfunction

function! s:Map(mode, lhs, rhs, ...) abort
  let flags = a:0 ? a:1 : '<silent>'
  exe a:mode . 'noremap <buffer> <nowait> ' . flags . ' ' . a:lhs . ' ' . a:rhs
endfunction

function! s:Changelist() abort
  return get(g:, 'subvim_changelist', 'subvim-staged')
endfunction

function! s:Event(name) abort
  if exists('#User#' . a:name)
    exe 'doautocmd <nomodeline> User ' . a:name
  endif
endfunction

function! s:ShellCmd(dir, args) abort
  return 'cd ' . shellescape(a:dir) . ' && svn --non-interactive '
        \ . join(map(copy(a:args), 'shellescape(v:val)'), ' ')
endfunction

" Run svn with a list of arguments in directory dir.  Returns [output, status]
" with stderr merged into the output.
function! s:Run(dir, args) abort
  let out = system(s:ShellCmd(a:dir, a:args) . ' 2>&1')
  return [substitute(out, '\n\+$', '', ''), v:shell_error]
endfunction

" Like s:Run, but throws on failure and returns only the output.
function! s:Svn(dir, args) abort
  let [out, status] = s:Run(a:dir, a:args)
  if status
    call s:Throw(empty(out) ? 'svn ' . a:args[0] . ' failed' : out)
  endif
  return out
endfunction

" Run svn writing stdout to file; returns [stderr, status].
function! s:RunToFile(dir, args, file) abort
  let err = tempname()
  call system(s:ShellCmd(a:dir, a:args) . ' > ' . shellescape(a:file) . ' 2> ' . shellescape(err))
  let status = v:shell_error
  let msg = filereadable(err) ? join(readfile(err), "\n") : ''
  call delete(err)
  return [msg, status]
endfunction

" Arguments for svn reading paths from a --targets file, avoiding argv limits
" and paths that look like options.
function! s:Targets(paths) abort
  let file = tempname()
  call writefile(a:paths, file)
  return ['--targets', file]
endfunction

function! s:Uniq(list) abort
  let [seen, result] = [{}, []]
  for value in a:list
    if !has_key(seen, value)
      let seen[value] = 1
      call add(result, value)
    endif
  endfor
  return result
endfunction

" Path p relative to root, or '' if outside.
function! s:Rel(root, path) abort
  let full = substitute(fnamemodify(a:path, ':p'), '/$', '', '')
  if full ==# a:root
    return '.'
  elseif stridx(full, a:root . '/') == 0
    return strpart(full, len(a:root) + 1)
  endif
  return ''
endfunction

function! s:Full(root, path) abort
  return a:path ==# '.' ? a:root : a:root . '/' . a:path
endfunction

function! s:Data(root, ...) abort
  return a:root . '/.svn/subvim' . (a:0 ? '/' . a:1 : '')
endfunction

" Section: Working copy detection and URLs {{{1

function! subvim#Root(...) abort
  if a:0 && type(a:1) == type('') && !empty(a:1)
    let url = s:ParseUrl(a:1)
    if !empty(url)
      return url.root
    endif
    let path = fnamemodify(a:1, ':p')
  elseif exists('b:subvim_root')
    return b:subvim_root
  elseif bufname('') =~# '^subvim://'
    return s:ParseUrl(bufname('')).root
  elseif empty(&buftype) && !empty(expand('%'))
    let path = expand('%:p')
  else
    let path = getcwd()
  endif
  let dir = isdirectory(path) ? path : fnamemodify(path, ':h')
  while !isdirectory(dir) && dir !=# fnamemodify(dir, ':h')
    let dir = fnamemodify(dir, ':h')
  endwhile
  " SVN >= 1.7 keeps a single .svn directory at the working copy root.
  let found = finddir('.svn', fnameescape(dir) . ';')
  if empty(found)
    return ''
  endif
  return substitute(fnamemodify(found, ':p:h:h'), '/$', '', '')
endfunction

function! s:RootOrThrow() abort
  let root = subvim#Root()
  if empty(root)
    call s:Throw('not a Subversion working copy')
  endif
  return root
endfunction

" subvim://ROOT//            status buffer
" subvim://ROOT//REV         revision (log message and diff)
" subvim://ROOT//REV/PATH    file at revision (PATH may start with ^/)
function! s:ParseUrl(name) abort
  let m = matchlist(a:name, '^subvim://\(.\{-}\)//\(.*\)$')
  if empty(m)
    return {}
  endif
  let [root, rest] = [m[1], m[2]]
  if empty(rest)
    return {'root': root, 'kind': 'status', 'rev': '', 'path': ''}
  elseif rest !~# '/'
    return {'root': root, 'kind': 'revision', 'rev': rest, 'path': ''}
  endif
  let rev = matchstr(rest, '^[^/]*')
  return {'root': root, 'kind': 'blob', 'rev': rev, 'path': strpart(rest, len(rev) + 1)}
endfunction

function! s:Url(obj) abort
  if a:obj.kind ==# 'work'
    return fnamemodify(s:Full(a:obj.root, a:obj.path), ':~:.')
  elseif a:obj.kind ==# 'status'
    return 'subvim://' . a:obj.root . '//'
  elseif a:obj.kind ==# 'revision'
    return 'subvim://' . a:obj.root . '//' . a:obj.rev
  endif
  return 'subvim://' . a:obj.root . '//' . a:obj.rev . '/' . a:obj.path
endfunction

function! subvim#Real(...) abort
  let name = a:0 ? a:1 : @%
  let url = s:ParseUrl(name)
  if empty(url)
    return name
  elseif url.kind ==# 'blob' && url.path !~# '^\^/'
    return s:Full(url.root, url.path)
  endif
  return url.root
endfunction

" Describe the current buffer: {root, kind, rev, path}.  kind is one of work,
" blob, revision, status, other.
function! s:Current() abort
  let url = s:ParseUrl(bufname(''))
  if !empty(url)
    return url
  endif
  let root = subvim#Root()
  if empty(root)
    return {}
  endif
  let path = empty(&buftype) && !empty(bufname('')) ? s:Rel(root, expand('%:p')) : ''
  return {'root': root, 'kind': empty(path) ? 'other' : 'work', 'rev': '', 'path': path}
endfunction

function! s:CurrentFile() abort
  let cur = s:Current()
  if empty(cur)
    call s:Throw('not a Subversion working copy')
  elseif empty(cur.path) || cur.path ==# '.'
    call s:Throw('not a file in the working copy')
  endif
  return cur
endfunction

function! s:NormalizeRev(rev) abort
  let rev = a:rev =~# '^r\d\+$' ? a:rev[1:] : a:rev
  return rev =~# '^\a\+$' ? toupper(rev) : rev
endfunction

" Expand an object spec into {root, kind, rev, path}:
"   ''            the working copy file (from a blob: its working file)
"   path          working copy file
"   path@REV      file at revision (path may be %, :/root-relative or ^/url)
"   @REV  r123    revision
function! s:Expand(spec) abort
  let cur = s:Current()
  let root = empty(cur) ? s:RootOrThrow() : cur.root
  let spec = a:spec
  if empty(spec)
    if empty(cur) || empty(cur.path) || cur.path =~# '^\^/'
      call s:Throw('no file to edit')
    endif
    return {'root': root, 'kind': 'work', 'rev': '', 'path': cur.path}
  elseif spec =~# '^@[^/]\+$' || spec =~# '^r\d\+$'
    return {'root': root, 'kind': 'revision', 'rev': s:NormalizeRev(substitute(spec, '^@', '', '')), 'path': ''}
  elseif spec =~# '^subvim://'
    return s:ParseUrl(spec)
  endif
  let m = matchlist(spec, '^\(.*\)@\([^@/]*\)$')
  let [path, rev] = empty(m) ? [spec, ''] : [m[1], s:NormalizeRev(m[2])]
  if path ==# '%' || path ==# ''
    if empty(cur) || empty(cur.path)
      call s:Throw('no current file')
    endif
    let path = cur.path
  elseif path =~# '^\^/'
    " repository-relative URL, kept as is
  elseif path =~# '^:/'
    let path = path[2:]
  else
    let rel = s:Rel(root, expand(path))
    if empty(rel)
      call s:Throw(path . ' is outside the working copy')
    endif
    let path = rel
  endif
  if empty(rev)
    return {'root': root, 'kind': 'work', 'rev': '', 'path': path}
  endif
  return {'root': root, 'kind': 'blob', 'rev': rev, 'path': path}
endfunction

" The svn target for a blob: path@REV.
function! s:BlobTarget(obj) abort
  return a:obj.path . '@' . a:obj.rev
endfunction

" Section: Info, branches and statusline {{{1

let s:info = {}

function! s:Info(root, ...) abort
  if !a:0 && has_key(s:info, a:root)
    return s:info[a:root]
  endif
  let [out, status] = s:Run(a:root, ['info', '--', '.'])
  let info = {'url': '', 'relative': '', 'repos': '', 'revision': ''}
  if !status
    for [key, field] in [['url', 'URL'], ['relative', 'Relative URL'], ['repos', 'Repository Root'], ['revision', 'Revision']]
      let info[key] = matchstr(out, '\%(^\|\n\)' . field . ': \zs[^\n]*')
    endfor
  endif
  let s:info[a:root] = info
  return info
endfunction

function! s:Layout(root) abort
  let rel = s:Info(a:root).relative
  let t = get(g:, 'subvim_trunk', 'trunk')
  let b = get(g:, 'subvim_branches', 'branches')
  let g = get(g:, 'subvim_tags', 'tags')
  let m = matchlist(rel, '^\(.\{-}\)/' . t . '\(/.*\)\=$')
  if !empty(m)
    return {'base': m[1], 'kind': 'trunk', 'name': t, 'sub': m[2], 'branch': m[1] . '/' . t}
  endif
  for [kind, dir] in [['branch', b], ['tag', g]]
    let m = matchlist(rel, '^\(.\{-}\)/' . dir . '/\([^/]\+\)\(/.*\)\=$')
    if !empty(m)
      return {'base': m[1], 'kind': kind, 'name': m[2], 'sub': m[3], 'branch': m[1] . '/' . dir . '/' . m[2]}
    endif
  endfor
  return {'base': '', 'kind': '', 'name': rel, 'sub': '', 'branch': rel}
endfunction

function! s:BranchLabel(root) abort
  let layout = s:Layout(a:root)
  if layout.kind ==# 'tag'
    return get(g:, 'subvim_tags', 'tags') . '/' . layout.name
  endif
  return layout.name
endfunction

function! subvim#Statusline(...) abort
  let cur = s:Current()
  if empty(cur)
    return ''
  endif
  let label = s:BranchLabel(cur.root)
  if cur.kind ==# 'blob' || cur.kind ==# 'revision'
    return '[Svn:r' . cur.rev . '(' . label . ')]'
  endif
  return '[Svn(' . label . ')]'
endfunction

" Call after anything that changes the working copy.
function! s:Changed(root) abort
  if has_key(s:info, a:root)
    call remove(s:info, a:root)
  endif
  call subvim#ReloadStatus(a:root)
  call s:Event('SubvimChanged')
endfunction

" Section: :Svn {{{1

let s:subcommands = ['add', 'blame', 'branch', 'cat', 'changelist', 'checkout',
      \ 'cleanup', 'commit', 'copy', 'delete', 'diff', 'difftool', 'export',
      \ 'help', 'import', 'info', 'list', 'lock', 'log', 'merge', 'mergeinfo',
      \ 'mergetool', 'mkdir', 'move', 'patch', 'propdel', 'propedit',
      \ 'propget', 'proplist', 'propset', 'relocate', 'resolve', 'resolved',
      \ 'revert', 'stash', 'status', 'switch', 'tag', 'unlock', 'update',
      \ 'upgrade']

let s:paged = '^\%(log\|diff\|di\|cat\|info\|proplist\|plist\|pl\|propget\|pget\|pg\|list\|ls\|mergeinfo\|status\|stat\|st\|help\|h\|?\)$'

function! subvim#Complete(A, L, P) abort
  let pre = strpart(a:L, 0, a:P)
  let words = split(pre, '\s\+', 1)
  if len(words) <= 2
    return filter(copy(s:subcommands), 'v:val =~# "^" . a:A')
  endif
  let sub = words[1]
  if sub =~# '^\%(switch\|sw\)$' || (sub ==# 'branch' && words[-2] =~# '^-[dD]$\|^--delete$')
    return filter(s:BranchNames(subvim#Root(), 'branches') + [get(g:, 'subvim_trunk', 'trunk')], 'v:val =~# "^" . a:A')
  elseif sub ==# 'stash' && len(words) == 3
    return filter(['push', 'save', 'list', 'show', 'apply', 'pop', 'drop', 'clear'], 'v:val =~# "^" . a:A')
  endif
  return map(getcompletion(a:A, 'file'), 'fnameescape(v:val)')
endfunction

function! subvim#ObjectComplete(A, L, P) abort
  if a:A =~# '@'
    return map(['BASE', 'HEAD', 'PREV', 'COMMITTED'], 'matchstr(a:A, ".*@") . v:val')
  endif
  return map(getcompletion(a:A, 'file'), 'fnameescape(v:val)')
endfunction

function! subvim#RenameComplete(A, L, P) abort
  let dir = expand('%:p:h') . '/'
  return map(getcompletion(dir . a:A, 'file'), 'fnameescape(strpart(v:val, len(dir)))')
endfunction

" Expand a %-style token.  In subvim:// buffers % means the file being shown.
function! s:ExpandToken(tok) abort
  if a:tok !~# '^[%#]\|^<cfile>'
    return a:tok
  endif
  let cur = s:Current()
  if a:tok ==# '%' && !empty(cur) && cur.kind ==# 'blob'
    return cur.path =~# '^\^/' ? s:BlobTarget(cur) : fnamemodify(s:Full(cur.root, cur.path), ':.') . '@' . cur.rev
  endif
  return expandcmd(a:tok)
endfunction

" Split a command line into words, honoring quotes and backslashes.
function! s:SplitArgs(str) abort
  let [args, cur, have, quoted, q, i] = [[], '', 0, 0, '', 0]
  while i < len(a:str)
    let c = a:str[i]
    if empty(q) && c =~# '\s'
      if have
        call add(args, quoted ? cur : s:ExpandToken(cur))
      endif
      let [cur, have, quoted] = ['', 0, 0]
    elseif empty(q) && (c ==# '"' || c ==# "'")
      let [q, have, quoted] = [c, 1, 1]
    elseif c ==# q
      let q = ''
    elseif c ==# '\' && q !=# "'" && i + 1 < len(a:str)
      let i += 1
      let cur .= a:str[i]
      let have = 1
    else
      let cur .= c
      let have = 1
    endif
    let i += 1
  endwhile
  if have
    call add(args, quoted ? cur : s:ExpandToken(cur))
  endif
  return args
endfunction

function! subvim#Command(line1, count, args, bang, mods) abort
  try
    let root = s:RootOrThrow()
    let argv = s:SplitArgs(a:args)
    let paginate = 0
    while !empty(argv) && argv[0] =~# '^\%(-p\|--paginate\)$'
      let paginate = 1
      call remove(argv, 0)
    endwhile
    if empty(argv)
      return s:StatusOpen(root, a:mods)
    endif
    let sub = argv[0]
    let rest = argv[1:]
    if sub =~# '^\%(commit\|ci\)$'
      return s:CommitCommand(root, rest, a:mods)
    elseif sub =~# '^\%(blame\|praise\|annotate\|ann\)$'
      return s:Blame(rest, a:mods)
    elseif sub ==# 'stash'
      return s:StashCommand(root, rest, a:mods)
    elseif sub ==# 'branch'
      return s:BranchCommand(root, 'branches', rest)
    elseif sub ==# 'tag'
      return s:BranchCommand(root, 'tags', rest)
    elseif sub =~# '^\%(switch\|sw\)$'
      return s:Switch(root, rest)
    elseif sub =~# '^\%(propedit\|pedit\|pe\)$'
      if empty(rest)
        call s:Throw('usage: :Svn propedit PROPNAME [PATH]')
      endif
      let path = len(rest) > 1 ? s:Rel(root, rest[1]) : (empty(s:Current().path) ? '.' : s:Current().path)
      return s:PropEdit(root, rest[0], path, '', a:mods)
    elseif sub ==# 'difftool' || sub ==# 'mergetool'
      return s:Difftool(root, sub ==# 'mergetool', rest, a:mods)
    elseif sub =~# s:paged || paginate || a:bang
      return s:Pager(root, argv, a:mods)
    endif
    let [out, status] = s:Run(getcwd(), argv)
    call s:Changed(root)
    if status
      return s:Error(empty(out) ? 'svn ' . sub . ' failed' : out)
    endif
    if !empty(out)
      echo out
    endif
    return ''
  catch /^subvim:/
    return s:Catch()
  endtry
endfunction

" Show the output of an svn command in a scratch split.
function! s:Pager(root, argv, mods) abort
  let [out, status] = s:Run(getcwd(), a:argv)
  if status
    return s:Error(empty(out) ? 'svn ' . a:argv[0] . ' failed' : out)
  endif
  if empty(out)
    return s:Warn('svn ' . a:argv[0] . ': no output')
  endif
  exe (empty(a:mods) ? '' : a:mods . ' ') . 'new'
  let b:subvim_root = a:root
  call setline(1, split(out, "\n"))
  setlocal buftype=nofile bufhidden=wipe noswapfile nomodifiable nomodified nobuflisted
  silent! exe 'file' fnameescape('[svn ' . join(a:argv) . '] ' . bufnr(''))
  let sub = a:argv[0]
  if sub =~# '^\%(diff\|di\)$'
    setlocal filetype=diff
  elseif sub ==# 'log'
    setlocal filetype=subvimlog
    call s:MapRevisionCursor()
  endif
  call s:Map('n', 'gq', ':<C-U>close<CR>')
  1
  return ''
endfunction

" Section: Status parsing {{{1

function! s:StagedDirs(root) abort
  let file = s:Data(a:root, 'staged-dirs')
  let dirs = {}
  for path in filereadable(file) ? readfile(file) : []
    if !empty(path)
      let dirs[path] = 1
    endif
  endfor
  return dirs
endfunction

function! s:SaveStagedDirs(root, dirs) abort
  call mkdir(s:Data(a:root), 'p')
  call writefile(sort(keys(a:dirs)), s:Data(a:root, 'staged-dirs'))
endfunction

" Parse `svn status`.  Returns a dict with Unversioned/Unstaged/Staged lists,
" lists (other changelists: name -> items), order (their names), bypath.
function! s:Status(root) abort
  let [out, status] = s:Run(a:root, ['status', '--ignore-externals'])
  if status
    call s:Throw(out)
  endif
  let st = {'Unversioned': [], 'Unstaged': [], 'Staged': [], 'lists': {}, 'order': [], 'bypath': {}}
  let dirs = s:StagedDirs(a:root)
  let seen_dirs = {}
  let cl = ''
  for line in split(out, "\n")
    let m = matchlist(line, "^--- Changelist '\\(.*\\)':$")
    if !empty(m)
      let cl = m[1]
      continue
    endif
    " Columns 1-7 are flags, column 8 is a space, path starts at column 9.
    if line !~# '^.\{7} \S' || line =~# '^\s*>'
      continue
    endif
    let flags = line[0:6]
    let path = line[8:]
    let [c1, c2] = [flags[0], flags[1]]
    if c1 ==# '?'
      let item = {'code': '?', 'path': path, 'section': 'Unversioned', 'changelist': ''}
      call add(st.Unversioned, item)
      let st.bypath[path] = item
      continue
    elseif c1 =~# '[AMDRC~!]'
      let code = c1
    elseif c2 =~# '[MC]'
      let code = c2
    elseif flags[6] ==# 'C'
      let code = 'C'
    else
      continue
    endif
    let item = {'code': code, 'path': path, 'changelist': cl, 'copied': flags[3] ==# '+'}
    if cl ==# s:Changelist() || (empty(cl) && has_key(dirs, path))
      let item.section = 'Staged'
      let seen_dirs[path] = 1
      call add(st.Staged, item)
    elseif !empty(cl)
      let item.section = 'Changelist ' . cl
      if !has_key(st.lists, cl)
        let st.lists[cl] = []
        call add(st.order, cl)
      endif
      call add(st.lists[cl], item)
    else
      let item.section = 'Unstaged'
      call add(st.Unstaged, item)
    endif
    let st.bypath[path] = item
  endfor
  " Forget staged directories that no longer have anything to commit.
  if len(filter(copy(dirs), '!has_key(seen_dirs, v:key)'))
    call s:SaveStagedDirs(a:root, filter(dirs, 'has_key(seen_dirs, v:key)'))
  endif
  return st
endfunction

function! s:Committable(st) abort
  let items = a:st.Unstaged + a:st.Staged
  for name in a:st.order
    let items += a:st.lists[name]
  endfor
  return items
endfunction

function! s:IsAncestor(dir, path) abort
  return a:dir ==# '.' || stridx(a:path, a:dir . '/') == 0
endfunction

" Section: Staging {{{1

" Put paths into the staged changelist; directories go to staged-dirs.
function! s:ChangelistAdd(root, paths) abort
  if empty(a:paths)
    return
  endif
  let out = s:Svn(a:root, ['changelist', s:Changelist()] + s:Targets(a:paths))
  let dirs = s:StagedDirs(a:root)
  for line in split(out, "\n")
    let skipped = matchstr(line, "^Skipped '\\zs.*\\ze'$")
    if !empty(skipped)
      let dirs[s:Rel(a:root, s:Full(a:root, skipped))] = 1
    endif
  endfor
  call s:SaveStagedDirs(a:root, dirs)
endfunction

function! s:ChangelistRemove(root, paths, ...) abort
  if empty(a:paths)
    return
  endif
  call s:Svn(a:root, ['changelist', '--remove'] + (a:0 ? ['--depth', a:1] : []) + s:Targets(a:paths))
  let dirs = s:StagedDirs(a:root)
  for path in a:paths
    call filter(dirs, a:0 ? '!s:IsAncestor(path, v:key) && v:key !=# path' : 'v:key !=# path')
  endfor
  call s:SaveStagedDirs(a:root, dirs)
endfunction

" Stage (the svn analogue of git add) the given status items.
function! s:Stage(root, items) abort
  let [adds, dels, resolves, paths] = [[], [], [], []]
  for item in a:items
    if item.section ==# 'Unversioned'
      call add(adds, item.path)
    elseif item.code ==# '!'
      call add(dels, item.path)
    elseif item.code ==# 'C'
      call add(resolves, item.path)
    endif
    call add(paths, item.path)
  endfor
  if !empty(adds)
    call s:Svn(a:root, ['add', '--depth', 'infinity', '--'] + adds)
  endif
  if !empty(dels)
    call s:Svn(a:root, ['delete', '--'] + dels)
  endif
  if !empty(resolves)
    call s:Svn(a:root, ['resolve', '--accept', 'working', '--'] + resolves)
  endif
  let st = s:Status(a:root)
  let sel = {}
  for path in paths
    if has_key(st.bypath, path)
      let sel[path] = 1
    endif
  endfor
  " Scheduled additions, deletions and replacements of directories take
  " their contents with them.
  for path in keys(sel)
    if st.bypath[path].code =~# '[ADR]'
      for other in keys(st.bypath)
        if s:IsAncestor(path, other) && st.bypath[other].section !=# 'Unversioned'
          let sel[other] = 1
        endif
      endfor
    endif
  endfor
  " An added path cannot be committed without its added parents.
  for path in keys(sel)
    let [child, parent] = [path, fnamemodify(path, ':h')]
    while parent !=# '.' && parent !=# child
      if has_key(st.bypath, parent) && st.bypath[parent].code =~# '[AR]'
        let sel[parent] = 1
      endif
      let [child, parent] = [parent, fnamemodify(parent, ':h')]
    endwhile
  endfor
  call s:ChangelistAdd(a:root, keys(sel))
endfunction

" Unstage the given items.  Staged additions become unversioned again and
" staged deletions become missing files, mirroring git reset.
function! s:Unstage(root, items) abort
  let st = s:Status(a:root)
  let [remove, unadd, undelete, others] = [{}, [], [], []]
  for item in a:items
    if item.section ==# 'Staged'
      let remove[item.path] = 1
      if item.code =~# '[ADR]'
        for other in st.Staged
          if s:IsAncestor(item.path, other.path)
            let remove[other.path] = 1
          endif
        endfor
      endif
      if item.code ==# 'A'
        call add(unadd, item.path)
      elseif item.code ==# 'D'
        call add(undelete, item.path)
      endif
    elseif item.section =~# '^Changelist '
      call add(others, item.path)
    elseif item.section ==# 'Unstaged' && item.code ==# 'A'
      call add(unadd, item.path)
    endif
  endfor
  if empty(remove) && empty(unadd) && empty(others)
    return 0
  endif
  call s:ChangelistRemove(a:root, keys(remove) + others)
  if !empty(unadd)
    call s:Svn(a:root, ['revert', '--depth', 'infinity', '--'] + unadd)
  endif
  for path in undelete
    let full = s:Full(a:root, path)
    let existed = filereadable(full) || isdirectory(full)
    call s:Svn(a:root, ['revert', '--depth', 'infinity', '--', path])
    if !existed
      call delete(full, 'rf')
    endif
  endfor
  return 1
endfunction

" Move path into .svn/subvim/trash (or copy it there).  Returns the backup.
function! s:Trash(root, path, move) abort
  let dest = s:Data(a:root, 'trash/' . strftime('%Y%m%d-%H%M%S') . '/' . a:path)
  call mkdir(fnamemodify(dest, ':h'), 'p')
  let full = s:Full(a:root, a:path)
  if a:move
    call rename(full, dest)
  elseif filereadable(full)
    call writefile(readfile(full, 'b'), dest, 'b')
  endif
  return dest
endfunction

" Throw away changes to items (git checkout / git clean).  Backups go to
" .svn/subvim/trash.
function! s:Discard(root, items) abort
  let backups = []
  for item in a:items
    let full = s:Full(a:root, item.path)
    if item.section ==# 'Unversioned'
      call add(backups, s:Trash(a:root, item.path, 1))
      continue
    endif
    if item.code !~# '[D!]' && filereadable(full)
      call add(backups, s:Trash(a:root, item.path, 0))
    endif
    call s:ChangelistRemove(a:root, [item.path], 'infinity')
    call s:Svn(a:root, ['revert', '--depth', 'infinity', '--', item.path])
    if item.code ==# 'A' && !item.copied && (filereadable(full) || isdirectory(full))
      call s:Trash(a:root, item.path, 1)
    endif
  endfor
  return backups
endfunction

" Discard a single hunk by rewriting the working file.
function! s:DiscardHunk(root, item, hunk) abort
  let m = matchlist(a:hunk[0], '^@@ -\(\d\+\)\%(,\(\d\+\)\)\= +\(\d\+\)\%(,\(\d\+\)\)\= @@')
  if empty(m)
    call s:Throw('cannot discard this hunk')
  endif
  let body = a:hunk[1:]
  if !empty(filter(copy(body), 'v:val =~# "^\\\\"'))
    call s:Throw('hunk touches the final newline; use X on the file instead')
  endif
  let start = str2nr(m[3])
  let cnt = empty(m[4]) ? 1 : str2nr(m[4])
  let old = map(filter(copy(body), 'v:val =~# "^[ -]"'), 'v:val[1:]')
  let new = map(filter(copy(body), 'v:val =~# "^[ +]"'), 'v:val[1:]')
  let full = s:Full(a:root, a:item.path)
  let lines = readfile(full, 'b')
  let idx = cnt == 0 ? start : start - 1
  if lines[idx : idx + cnt - 1] !=# new
    call s:Throw('hunk does not match ' . a:item.path . '; reload with :e')
  endif
  let backup = s:Trash(a:root, a:item.path, 0)
  let lines = (idx > 0 ? lines[0 : idx - 1] : []) + old + lines[idx + cnt :]
  call writefile(lines, full, 'b')
  return backup
endfunction

" Section: Status buffer {{{1

function! s:StatusOpen(root, mods) abort
  let name = s:Url({'root': a:root, 'kind': 'status'})
  let winnr = bufwinnr('^' . escape(name, '\.*~[]^$') . '$')
  if winnr > 0
    exe winnr . 'wincmd w'
    call s:StatusRender()
    return ''
  endif
  exe (empty(a:mods) ? '' : a:mods . ' ') . 'split ' . fnameescape(name)
  return ''
endfunction

function! s:StatusSetup(root) abort
  let b:subvim_root = a:root
  let b:subvim_status = 1
  let b:subvim_expanded = get(b:, 'subvim_expanded', {})
  setlocal buftype=nofile bufhidden=hide noswapfile nomodeline nobuflisted
  setlocal nomodifiable nolist nowrap foldmethod=syntax foldlevel=1
  setlocal filetype=subvim
  augroup subvim_status_buffer
    autocmd! * <buffer>
    autocmd BufEnter <buffer> call s:StatusRender()
  augroup END
  call s:MapStatus()
endfunction

" Diff lines worth showing inline for one file.
function! s:InlineDiff(root, item) abort
  if a:item.section ==# 'Unversioned'
    return []
  endif
  let [out, status] = s:Run(a:root, ['diff', '--depth', 'empty', '--', a:item.path])
  if status
    return []
  endif
  let lines = split(out, "\n")
  let start = match(lines, '^\%(@@\|Property changes on:\|Cannot display:\)')
  if start < 0
    return []
  endif
  return filter(lines[start :], 'v:val !~# "^_\\{20,}$"')
endfunction

" Render the status buffer.  target {'section', 'path'} picks the cursor line.
function! s:StatusRender(...) abort
  if !exists('b:subvim_status')
    return
  endif
  let root = b:subvim_root
  try
    let st = s:Status(root)
  catch /^subvim:/
    return s:Catch()
  endtry
  let info = s:Info(root, 1)
  let lines = ['Head: ' . s:BranchLabel(root)]
  call add(lines, 'URL: ' . info.relative)
  let wcrev = executable('svnversion') ? substitute(system('svnversion ' . shellescape(root)), '\n', '', 'g') : info.revision
  call add(lines, 'Revision: ' . wcrev)
  let stashes = len(s:StashList(root))
  if stashes
    call add(lines, 'Stashes: ' . stashes)
  endif
  call add(lines, 'Help: g?')
  let meta = {}
  let sections = [['Unversioned', st.Unversioned], ['Unstaged', st.Unstaged], ['Staged', st.Staged]]
  for name in st.order
    call add(sections, ['Changelist ' . name, st.lists[name]])
  endfor
  for [name, list] in sections
    if empty(list)
      continue
    endif
    call extend(lines, ['', name . ' (' . len(list) . ')'])
    for item in list
      call add(lines, item.code . ' ' . item.path)
      let meta[len(lines)] = {'item': item, 'hunk': 0}
      if has_key(b:subvim_expanded, item.path)
        let header = 0
        for diffline in s:InlineDiff(root, item)
          call add(lines, diffline)
          if diffline =~# '^@@'
            let header = len(lines)
          endif
          let meta[len(lines)] = {'item': item, 'hunk': header}
        endfor
      endif
    endfor
  endfor
  if empty(s:Committable(st)) && empty(st.Unversioned)
    call extend(lines, ['', 'Nothing to commit, working copy clean'])
  endif
  let b:subvim_lines = meta
  let pos = getpos('.')
  setlocal modifiable
  silent keepjumps %delete _
  call setline(1, lines)
  setlocal nomodifiable nomodified
  call setpos('.', pos)
  if a:0 && !empty(a:1)
    for [lnum, entry] in items(meta)
      if entry.hunk == 0 && entry.item.path ==# a:1.path && (entry.item.section ==# a:1.section || empty(a:1.section))
        exe lnum
        break
      endif
    endfor
  endif
  call s:Event('SubvimIndex')
endfunction

" Re-render every visible status buffer (optionally only for one root).
function! subvim#ReloadStatus(...) abort
  let cur = winnr()
  let found = 0
  for nr in range(1, winnr('$'))
    let bufnr = winbufnr(nr)
    if !getbufvar(bufnr, 'subvim_status', 0)
      continue
    endif
    if a:0 && getbufvar(bufnr, 'subvim_root') !=# a:1
      continue
    endif
    let found = 1
    noautocmd exe nr . 'wincmd w'
    call s:StatusRender()
  endfor
  if found
    noautocmd exe cur . 'wincmd w'
  endif
endfunction

" Section: Status buffer: selection and actions {{{1

" Return [items, hunk] for lines first..last.  A section heading selects all
" of its items.  hunk is the list of lines of the hunk under the cursor when
" a single hunk line is selected.
function! s:Selection(first, last) abort
  let meta = get(b:, 'subvim_lines', {})
  let result = []
  let seen = {}
  let hunk = []
  for lnum in range(a:first, a:last)
    if has_key(meta, lnum)
      let entry = meta[lnum]
      if a:first == a:last && entry.hunk
        let hunk = [getline(entry.hunk)]
        let l = entry.hunk + 1
        while has_key(meta, l) && meta[l].hunk == entry.hunk
          call add(hunk, getline(l))
          let l += 1
        endwhile
      endif
      let key = entry.item.section . "\n" . entry.item.path
      if !has_key(seen, key)
        let seen[key] = 1
        call add(result, entry.item)
      endif
    elseif getline(lnum) =~# '^\u.* (\d\+)$'
      let l = lnum + 1
      while has_key(meta, l)
        let key = meta[l].item.section . "\n" . meta[l].item.path
        if !has_key(seen, key)
          let seen[key] = 1
          call add(result, meta[l].item)
        endif
        let l += 1
      endwhile
    endif
  endfor
  return [result, hunk]
endfunction

function! s:Range(visual) abort
  if a:visual
    return [line("'<"), line("'>")]
  endif
  return [line('.'), line('.') + max([v:count1, 1]) - 1]
endfunction

" Where the cursor should land after acting on lines first..last.
function! s:NextTarget(last, items) abort
  let meta = get(b:, 'subvim_lines', {})
  let paths = map(copy(a:items), 'v:val.path')
  for lnum in sort(map(keys(meta), 'str2nr(v:val)'), 'n')
    if lnum > a:last && meta[lnum].hunk == 0 && index(paths, meta[lnum].item.path) < 0
      return {'section': meta[lnum].item.section, 'path': meta[lnum].item.path}
    endif
  endfor
  return {}
endfunction

function! s:Do(action, visual) abort
  let [first, last] = s:Range(a:visual)
  let [items, hunk] = s:Selection(first, last)
  let root = b:subvim_root
  try
    if empty(items)
      return s:Error('nothing to ' . (a:action ==# 'Stage' ? 'stage' : a:action ==# 'Unstage' ? 'unstage' : 'toggle') . ' here')
    endif
    let target = s:NextTarget(last, items)
    let action = a:action
    if action ==# 'Toggle'
      let action = items[0].section ==# 'Staged' ? 'Unstage' : 'Stage'
    endif
    if action ==# 'Stage'
      let items = filter(items, 'v:val.section !=# "Staged"')
      if empty(items)
        return s:Error('already staged')
      endif
      call s:Stage(root, items)
      if !empty(hunk)
        call s:Warn('Subversion stages whole files: staged ' . items[0].path)
      endif
    else
      if !s:Unstage(root, items)
        return s:Error('nothing staged here')
      endif
    endif
    call s:StatusRender(target)
    call s:Event('SubvimChanged')
  catch /^subvim:/
    call s:StatusRender()
    return s:Catch()
  endtry
  return ''
endfunction

function! s:UnstageAll() abort
  let root = b:subvim_root
  try
    let st = s:Status(root)
    if empty(st.Staged)
      return s:Error('nothing staged')
    endif
    call s:Unstage(root, st.Staged)
  catch /^subvim:/
    return s:Catch()
  finally
    call s:StatusRender()
  endtry
  return ''
endfunction

function! s:StageDelete(first, last) abort
  let [items, hunk] = s:Selection(a:first, a:last)
  let root = b:subvim_root
  if empty(items)
    return s:Error('nothing to discard here')
  endif
  try
    let target = s:NextTarget(a:last, items)
    if !empty(hunk)
      let backup = s:DiscardHunk(root, items[0], hunk)
      let target = {'section': items[0].section, 'path': items[0].path}
      let msg = 'Discarded hunk in ' . items[0].path . '; backup: ' . fnamemodify(backup, ':~:.')
    else
      let backups = s:Discard(root, items)
      let msg = 'Discarded ' . (len(items) == 1 ? items[0].path : len(items) . ' items')
      if !empty(backups)
        let msg .= '; backup in ' . fnamemodify(backups[0], ':h:~:.')
      endif
    endif
    checktime
    call s:StatusRender(target)
    call s:Event('SubvimChanged')
    echo 'subvim: ' . msg
  catch /^subvim:/
    call s:StatusRender()
    return s:Catch()
  endtry
  return ''
endfunction

function! s:StageInline(mode, first, count) abort
  let meta = get(b:, 'subvim_lines', {})
  let paths = []
  for lnum in range(a:first, a:first + max([a:count, 1]) - 1)
    if has_key(meta, lnum)
      call add(paths, meta[lnum].item.path)
    elseif getline(lnum) =~# '^\u.* (\d\+)$'
      let [items, _] = s:Selection(lnum, lnum)
      let paths += map(items, 'v:val.path')
    endif
  endfor
  if empty(paths)
    return ''
  endif
  let section = get(get(meta, a:first, {}), 'item', {'section': ''}).section
  for path in s:Uniq(paths)
    let show = a:mode ==# 'show' || (a:mode ==# 'toggle' && !has_key(b:subvim_expanded, path))
    if show
      let b:subvim_expanded[path] = 1
    elseif has_key(b:subvim_expanded, path)
      call remove(b:subvim_expanded, path)
    endif
  endfor
  call s:StatusRender({'section': section, 'path': paths[0]})
  return ''
endfunction

function! s:StageIgnore(first, last, count) abort
  let [items, _] = s:Selection(a:first, a:last)
  if empty(items)
    return s:Error('nothing to ignore here')
  endif
  let item = items[0]
  let dir = fnamemodify(item.path, ':h')
  let name = fnamemodify(item.path, ':t')
  return s:PropEdit(b:subvim_root, 'svn:ignore', dir, name, a:count ? 'tab' : '')
endfunction

function! s:StageArgs(visual) abort
  let [first, last] = a:visual ? [line("'<"), line("'>")] : [line('.'), line('.')]
  let [items, _] = s:Selection(first, last)
  return join(map(items, 'fnameescape(fnamemodify(s:Full(b:subvim_root, v:val.path), ":."))'), ' ')
endfunction

" Section: Status buffer: navigation {{{1

function! s:ItemLines(...) abort
  let meta = get(b:, 'subvim_lines', {})
  return sort(map(keys(filter(copy(meta), a:0 ? 'v:val.hunk == str2nr(v:key)' : 'v:val.hunk == 0')), 'str2nr(v:val)'), 'n')
endfunction

function! s:Jump(lnums, count, forward) abort
  let cur = line('.')
  let list = a:forward ? a:lnums : reverse(copy(a:lnums))
  for _ in range(a:count)
    let next = filter(copy(list), a:forward ? 'v:val > cur' : 'v:val < cur')
    if empty(next)
      break
    endif
    let cur = next[0]
  endfor
  exe cur
  return ''
endfunction

function! s:NextItem(count) abort
  return s:Jump(s:ItemLines(), a:count, 1)
endfunction

function! s:PreviousItem(count) abort
  return s:Jump(s:ItemLines(), a:count, 0)
endfunction

function! s:NextHunk(count) abort
  return s:Jump(s:ItemLines(1), a:count, 1)
endfunction

function! s:PreviousHunk(count) abort
  return s:Jump(s:ItemLines(1), a:count, 0)
endfunction

" Jump to the next file or hunk, expanding inline diffs as needed.
function! s:NextExpandedHunk(count) abort
  for _ in range(a:count)
    let meta = get(b:, 'subvim_lines', {})
    let cur = line('.')
    let next = filter(s:ItemLines() + s:ItemLines(1), 'v:val > cur')
    if empty(next)
      break
    endif
    let lnum = min(next)
    let entry = meta[lnum]
    if entry.hunk == 0 && !has_key(b:subvim_expanded, entry.item.path)
      let b:subvim_expanded[entry.item.path] = 1
      call s:StatusRender({'section': entry.item.section, 'path': entry.item.path})
      let lnum = line('.')
      if has_key(get(b:, 'subvim_lines', {}), lnum + 1) && b:subvim_lines[lnum + 1].hunk
        let lnum = b:subvim_lines[lnum + 1].hunk
      endif
    endif
    exe lnum
  endfor
  return ''
endfunction

function! s:SectionLines() abort
  return filter(range(1, line('$')), 'getline(v:val) =~# "^\\u.* (\\d\\+)$"')
endfunction

function! s:NextSection(count) abort
  return s:Jump(s:SectionLines(), a:count, 1)
endfunction

function! s:PreviousSection(count) abort
  return s:Jump(s:SectionLines(), a:count, 0)
endfunction

function! s:SectionJump(count, ...) abort
  for name in a:000
    let lnum = search('^' . name . ' (\d\+)$', 'nw')
    if lnum
      let items = filter(s:ItemLines(), 'v:val > lnum && b:subvim_lines[v:val].item.section ==# name')
      exe get(items, max([a:count, 1]) - 1, items[-1])
      return ''
    endif
  endfor
  return s:Error('no ' . a:1 . ' section')
endfunction

function! s:StatusOpenFile(cmd) abort
  let [items, _] = s:Selection(line('.'), line('.'))
  if empty(items)
    return ''
  endif
  let item = items[0]
  let full = s:Full(b:subvim_root, item.path)
  if !filereadable(full) && !isdirectory(full)
    let target = s:Url({'root': b:subvim_root, 'kind': 'blob', 'rev': 'BASE', 'path': item.path})
  else
    let target = fnamemodify(full, ':~:.')
  endif
  exe a:cmd . ' ' . fnameescape(target)
  return ''
endfunction

function! s:StageDiff(cmd) abort
  let [items, _] = s:Selection(line('.'), line('.'))
  if empty(items)
    return ''
  endif
  let item = items[0]
  let full = s:Full(b:subvim_root, item.path)
  if item.section ==# 'Unversioned' || isdirectory(full)
    return s:StatusOpenFile('edit')
  elseif !filereadable(full)
    return s:StatusOpenFile('edit')
  endif
  exe 'edit ' . fnameescape(fnamemodify(full, ':~:.'))
  exe a:cmd
  return ''
endfunction

function! s:StageDiffEdit() abort
  let [items, _] = s:Selection(line('.'), line('.'))
  if empty(items)
    return ''
  endif
  return s:Pager(b:subvim_root, ['diff', '--', s:Full(b:subvim_root, items[0].path)], '')
endfunction

function! s:Quit() abort
  if winnr('$') == 1 && tabpagenr('$') == 1
    quit
  else
    close
  endif
endfunction

function! s:MapStatus() abort
  call s:Map('n', '-', ":<C-U>execute <SID>Do('Toggle',0)<CR>")
  call s:Map('x', '-', ":<C-U>execute <SID>Do('Toggle',1)<CR>")
  call s:Map('n', 's', ":<C-U>execute <SID>Do('Stage',0)<CR>")
  call s:Map('x', 's', ":<C-U>execute <SID>Do('Stage',1)<CR>")
  call s:Map('n', 'u', ":<C-U>execute <SID>Do('Unstage',0)<CR>")
  call s:Map('x', 'u', ":<C-U>execute <SID>Do('Unstage',1)<CR>")
  call s:Map('n', 'U', ":<C-U>execute <SID>UnstageAll()<CR>")
  call s:Map('n', 'X', ":<C-U>execute <SID>StageDelete(line('.'), line('.') + v:count1 - 1)<CR>")
  call s:Map('x', 'X', ":<C-U>execute <SID>StageDelete(line(\"'<\"), line(\"'>\"))<CR>")
  call s:Map('n', '=', ":<C-U>execute <SID>StageInline('toggle', line('.'), v:count)<CR>")
  call s:Map('n', '<', ":<C-U>execute <SID>StageInline('hide', line('.'), v:count)<CR>")
  call s:Map('n', '>', ":<C-U>execute <SID>StageInline('show', line('.'), v:count)<CR>")
  call s:Map('x', '=', ":<C-U>execute <SID>StageInline('toggle', line(\"'<\"), line(\"'>\") - line(\"'<\") + 1)<CR>")
  call s:Map('x', '<', ":<C-U>execute <SID>StageInline('hide', line(\"'<\"), line(\"'>\") - line(\"'<\") + 1)<CR>")
  call s:Map('x', '>', ":<C-U>execute <SID>StageInline('show', line(\"'<\"), line(\"'>\") - line(\"'<\") + 1)<CR>")
  call s:Map('n', 'i', ":<C-U>execute <SID>NextExpandedHunk(v:count1)<CR>")
  call s:Map('n', 'gI', ":<C-U>execute <SID>StageIgnore(line('.'), line('.'), v:count)<CR>")
  call s:Map('x', 'gI', ":<C-U>execute <SID>StageIgnore(line(\"'<\"), line(\"'>\"), v:count)<CR>")
  call s:Map('n', 'gi', ":<C-U>execute <SID>PropEdit(b:subvim_root, 'svn:ignore', '.', '', v:count ? 'tab' : '')<CR>")
  call s:Map('n', 'dd', ":<C-U>execute <SID>StageDiff('Sdiffsplit')<CR>")
  call s:Map('n', 'dh', ":<C-U>execute <SID>StageDiff('Shdiffsplit')<CR>")
  call s:Map('n', 'ds', ":<C-U>execute <SID>StageDiff('Shdiffsplit')<CR>")
  call s:Map('n', 'dv', ":<C-U>execute <SID>StageDiff('Svdiffsplit')<CR>")
  call s:Map('n', 'dp', ":<C-U>execute <SID>StageDiffEdit()<CR>")
  call s:Map('n', 'd?', ":<C-U>help subvim_d<CR>")
  call s:Map('n', ')', ":<C-U>execute <SID>NextItem(v:count1)<CR>")
  call s:Map('n', '(', ":<C-U>execute <SID>PreviousItem(v:count1)<CR>")
  call s:Map('n', '<C-N>', ":<C-U>execute <SID>NextItem(v:count1)<CR>")
  call s:Map('n', '<C-P>', ":<C-U>execute <SID>PreviousItem(v:count1)<CR>")
  call s:Map('n', ']m', ":<C-U>execute <SID>NextItem(v:count1)<CR>")
  call s:Map('n', '[m', ":<C-U>execute <SID>PreviousItem(v:count1)<CR>")
  call s:Map('n', ']/', ":<C-U>execute <SID>NextItem(v:count1)<CR>")
  call s:Map('n', '[/', ":<C-U>execute <SID>PreviousItem(v:count1)<CR>")
  call s:Map('n', 'J', ":<C-U>execute <SID>NextHunk(v:count1)<CR>")
  call s:Map('n', 'K', ":<C-U>execute <SID>PreviousHunk(v:count1)<CR>")
  call s:Map('n', ']c', ":<C-U>execute <SID>NextHunk(v:count1)<CR>")
  call s:Map('n', '[c', ":<C-U>execute <SID>PreviousHunk(v:count1)<CR>")
  call s:Map('n', ']]', ":<C-U>execute <SID>NextSection(v:count1)<CR>")
  call s:Map('n', '[[', ":<C-U>execute <SID>PreviousSection(v:count1)<CR>")
  call s:Map('n', 'gu', ":<C-U>execute <SID>SectionJump(v:count, 'Unversioned', 'Unstaged')<CR>")
  call s:Map('n', 'gU', ":<C-U>execute <SID>SectionJump(v:count, 'Unstaged', 'Unversioned')<CR>")
  call s:Map('n', 'gs', ":<C-U>execute <SID>SectionJump(v:count, 'Staged')<CR>")
  call s:Map('n', '<CR>', ":<C-U>execute <SID>StatusOpenFile('edit')<CR>")
  call s:Map('n', 'o', ":<C-U>execute <SID>StatusOpenFile('split')<CR>")
  call s:Map('n', 'gO', ":<C-U>execute <SID>StatusOpenFile('vsplit')<CR>")
  call s:Map('n', 'O', ":<C-U>execute <SID>StatusOpenFile('tabedit')<CR>")
  call s:Map('n', 'p', ":<C-U>execute <SID>StatusOpenFile('pedit')<CR>")
  call s:Map('n', 'cc', ":<C-U>Svn commit<CR>")
  call s:Map('n', 'cvc', ":<C-U>Svn commit -v<CR>")
  call s:Map('n', 'c<Space>', ':Svn commit<Space>', '')
  call s:Map('n', 'cm<Space>', ':Svn merge<Space>', '')
  call s:Map('n', 'c?', ":<C-U>help subvim_c<CR>")
  call s:Map('n', 'cb<Space>', ':Svn branch<Space>', '')
  call s:Map('n', 'co<Space>', ':Svn switch<Space>', '')
  call s:Map('n', 'cb?', ":<C-U>help subvim_cb<CR>")
  call s:Map('n', 'co?', ":<C-U>help subvim_cb<CR>")
  call s:MapStash()
  call s:Map('n', 'gq', ":<C-U>call <SID>Quit()<CR>")
  call s:Map('n', 'R', ":<C-U>echohl WarningMsg<Bar>echo 'Reloading is automatic.  Use :e to force'<Bar>echohl NONE<CR>")
  call s:Map('n', '.', ':<C-U> <C-R>=<SID>StageArgs(0)<CR><Home>', '')
  call s:Map('x', '.', ':<C-U> <C-R>=<SID>StageArgs(1)<CR><Home>', '')
  call s:Map('n', 'g?', ":<C-U>help subvim-maps<CR>")
endfunction

function! s:MapStash() abort
  call s:Map('n', 'czz', ":<C-U>execute <SID>StashMap(v:count ? ['push', '--include-untracked'] : ['push'])<CR>")
  call s:Map('n', 'czw', ":<C-U>execute <SID>StashMap(['push', '--keep-index'] + (v:count ? ['--include-untracked'] : []))<CR>")
  call s:Map('n', 'czs', ":<C-U>execute <SID>StashMap(['push', '--staged'])<CR>")
  call s:Map('n', 'czA', ":<C-U>execute <SID>StashMap(['apply', v:count])<CR>")
  call s:Map('n', 'cza', ":<C-U>execute <SID>StashMap(['apply', '--index', v:count])<CR>")
  call s:Map('n', 'czP', ":<C-U>execute <SID>StashMap(['pop', v:count])<CR>")
  call s:Map('n', 'czp', ":<C-U>execute <SID>StashMap(['pop', '--index', v:count])<CR>")
  call s:Map('n', 'cz<Space>', ':Svn stash<Space>', '')
  call s:Map('n', 'cz?', ":<C-U>help subvim_cz<CR>")
endfunction

" Section: Committing {{{1

let s:commits = {}
let s:valued = '^\%(-m\|--message\|-F\|--file\|--depth\|--with-revprop\|--changelist\|--cl\|--targets\|--encoding\|--editor-cmd\|--config-option\|--config-dir\|--username\|--password\)$'

function! s:CommitCommand(root, args, mods) abort
  let [all, verbose, opts, paths, has_msg] = [0, 0, [], [], 0]
  let i = 0
  while i < len(a:args)
    let arg = a:args[i]
    if arg ==# '--'
      let paths += a:args[i + 1 :]
      break
    elseif arg =~# '^\%(-a\|--all\)$'
      let all = 1
    elseif arg =~# '^\%(-v\|--verbose\)$'
      let verbose = 1
    elseif arg =~# s:valued
      let has_msg = has_msg || arg =~# '^\%(-m\|--message\|-F\|--file\)$'
      let opts += [arg, get(a:args, i + 1, '')]
      let i += 1
    elseif arg =~# '^-[mF].'
      let has_msg = 1
      call add(opts, arg)
    elseif arg =~# '^-'
      call add(opts, arg)
    else
      call add(paths, fnamemodify(arg, ':p'))
    endif
    let i += 1
  endwhile
  let st = s:Status(a:root)
  if !empty(paths)
    let commit = {'paths': paths, 'items': []}
  else
    if all
      let items = filter(s:Committable(st), 'v:val.changelist !=# "ignore-on-commit"')
    else
      let items = copy(st.Staged)
    endif
    if empty(items)
      return s:Error(all ? 'nothing to commit' : 'no changes added to commit (use s to stage, or :Svn commit -a)')
    endif
    let commit = {'paths': [], 'items': items}
  endif
  let commit.root = a:root
  let commit.opts = opts
  if has_msg
    return s:CommitExecute(commit)
  endif
  return s:CommitOpen(commit, verbose, [], a:mods)
endfunction

function! s:CommitOpen(commit, verbose, message, mods) abort
  let dir = tempname()
  call mkdir(dir, 'p')
  " The svn-commit*.tmp name gets Vim's built-in svn filetype.
  let file = dir . '/svn-commit.tmp'
  let lines = (empty(a:message) ? [''] : a:message) + [s:ignore_line, '']
  if empty(a:commit.paths)
    for item in a:commit.items
      call add(lines, item.code . '    ' . item.path)
    endfor
    let st = s:Status(a:commit.root)
    let paths = map(copy(a:commit.items), 'v:val.path')
    let left = filter(s:Committable(st), 'index(paths, v:val.path) < 0')
    if !empty(left)
      call extend(lines, ['', 'Changes not staged for commit:'])
      call extend(lines, map(left, '"  " . v:val.code . "    " . v:val.path'))
    endif
  else
    call extend(lines, map(copy(a:commit.paths), 'fnamemodify(v:val, ":.")'))
  endif
  if a:verbose
    let targets = empty(a:commit.paths) ? ['--depth', 'empty', '--'] + map(copy(a:commit.items), 'v:val.path') : ['--'] + a:commit.paths
    let [out, status] = s:Run(a:commit.root, ['diff'] + targets)
    if !status && !empty(out)
      call extend(lines, [''] + split(out, "\n"))
    endif
  endif
  call writefile(lines, file)
  exe (empty(a:mods) ? '' : a:mods . ' ') . 'split ' . fnameescape(file)
  setlocal bufhidden=wipe noswapfile
  let s:commits[bufnr('')] = extend(copy(a:commit), {'file': file, 'dir': dir, 'written': 0})
  augroup subvim_commit
    autocmd! * <buffer>
    autocmd BufWritePost <buffer> let s:commits[+expand('<abuf>')].written = 1
    autocmd BufWipeout <buffer> call s:CommitFinish(+expand('<abuf>'))
  augroup END
  1
  return ''
endfunction

function! s:CommitMessage(lines) abort
  let idx = index(a:lines, s:ignore_line)
  let lines = idx < 0 ? copy(a:lines) : (idx == 0 ? [] : a:lines[0 : idx - 1])
  while !empty(lines) && lines[-1] =~# '^\s*$'
    call remove(lines, -1)
  endwhile
  while !empty(lines) && lines[0] =~# '^\s*$'
    call remove(lines, 0)
  endwhile
  return lines
endfunction

function! s:CommitFinish(bufnr) abort
  let state = remove(s:commits, a:bufnr)
  " Finish outside of the wipeout autocommand.
  call timer_start(0, {-> s:CommitRun(state)})
endfunction

function! s:CommitRun(state) abort
  let state = a:state
  try
    if !state.written
      return s:Error('commit aborted (message not written)')
    endif
    let msg = s:CommitMessage(readfile(state.file))
    if empty(msg)
      return s:Error('aborting commit due to empty commit message')
    endif
    let msgfile = state.dir . '/message.txt'
    call writefile(msg, msgfile, 'b')
    call s:CommitExecute(extend(copy(state), {'opts': ['-F', msgfile] + state.opts}))
  finally
    call delete(state.dir, 'rf')
  endtry
endfunction

function! s:CommitExecute(commit) abort
  let root = a:commit.root
  if empty(a:commit.paths)
    let targets = ['--depth', 'empty'] + s:Targets(map(copy(a:commit.items), 'v:val.path'))
  else
    let targets = ['--'] + a:commit.paths
  endif
  let [out, status] = s:Run(root, ['commit'] + a:commit.opts + targets)
  call s:Changed(root)
  if status
    return s:Error(out)
  endif
  for line in split(out, "\n")
    echomsg line
  endfor
  return ''
endfunction

" Section: Object buffers {{{1

function! subvim#BufReadCmd(name) abort
  try
    let url = s:ParseUrl(a:name)
    if url.kind ==# 'status'
      call s:StatusSetup(url.root)
      call s:StatusRender()
    elseif url.kind ==# 'revision'
      call s:RevisionLoad(url)
    else
      call s:BlobLoad(url)
    endif
  catch /^subvim:/
    setlocal buftype=nowrite nomodifiable
    return s:Catch()
  endtry
  return ''
endfunction

function! subvim#FileReadCmd(name) abort
  try
    let url = s:ParseUrl(a:name)
    if url.kind !=# 'blob'
      call s:Throw('can only :read files')
    endif
    let tmp = tempname()
    let [err, status] = s:RunToFile(url.root, ['cat', '--', s:BlobTarget(url)], tmp)
    if status
      call s:Throw(err)
    endif
    exe 'silent keepalt read ' . fnameescape(tmp)
    call delete(tmp)
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

function! s:BlobLoad(url) abort
  let tmp = tempname()
  let [err, status] = s:RunToFile(a:url.root, ['cat', '--', s:BlobTarget(a:url)], tmp)
  setlocal modifiable noreadonly
  silent keepjumps %delete _
  if status
    call delete(tmp)
    setlocal buftype=nowrite nomodifiable
    call s:Throw(err)
  endif
  " Reading into an empty buffer replaces its single empty line.
  exe 'silent keepjumps keepalt read ++edit ' . fnameescape(tmp)
  call delete(tmp)
  let b:subvim_root = a:url.root
  setlocal buftype=nowrite noswapfile nomodifiable readonly nomodified
  exe 'silent doautocmd <nomodeline> filetypedetect BufRead ' . fnameescape(fnamemodify(a:url.path, ':t'))
  call s:Map('n', '~', ":<C-U>execute <SID>Ancestor(v:count1)<CR>")
  call s:Map('n', 'P', ":<C-U>execute <SID>Ancestor(v:count1)<CR>")
  call s:Map('n', 'C', ":<C-U>execute subvim#Open('edit', '@' . <SID>Current().rev, '')<CR>")
  call s:Map('n', 'gq', ":<C-U>call <SID>Quit()<CR>")
  call s:MapRevert()
  call s:Event('SubvimBlob')
endfunction

" Revision number of an object ('' if it cannot be resolved).
function! s:RevNumber(root, target) abort
  let [out, status] = s:Run(a:root, ['info', '--show-item', 'last-changed-revision', '--', a:target])
  return status ? '' : matchstr(out, '\d\+')
endfunction

" Open the current file at the [count]th previous revision where it changed.
function! s:Ancestor(count) abort
  try
    let cur = s:Current()
    let [out, status] = s:Run(cur.root, ['log', '-q', '-l', a:count + 1, '--', s:BlobTarget(cur)])
    if status
      call s:Throw(out)
    endif
    let revs = map(filter(split(out, "\n"), 'v:val =~# "^r\\d"'), 'matchstr(v:val, "^r\\zs\\d\\+")')
    " The first entry is the revision shown unless it is a keyword like BASE.
    let current = cur.rev =~# '^\d\+$' ? cur.rev : get(revs, 0, '')
    call filter(revs, 'str2nr(v:val) < str2nr(current)')
    if empty(revs)
      call s:Throw('no earlier revision of ' . cur.path)
    endif
    exe 'edit ' . fnameescape(s:Url(extend(copy(cur), {'rev': revs[min([a:count, len(revs)]) - 1]})))
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

function! subvim#Open(cmd, args, mods) abort
  try
    let obj = s:Expand(a:args)
    let mods = empty(a:mods) ? '' : a:mods . ' '
    exe mods . a:cmd . ' ' . fnameescape(s:Url(obj))
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Default comparison object for :Sread and :Sdiffsplit.
function! s:DefaultObject(args) abort
  let cur = s:CurrentFile()
  if empty(a:args)
    return cur.kind ==# 'blob' ? s:Expand('') : s:Expand('%@BASE')
  elseif a:args =~# '^@[^/]\+$' || a:args =~# '^\%(\d\+\|r\d\+\|\u\+\)$'
    return s:Expand('%@' . substitute(a:args, '^@', '', ''))
  endif
  return s:Expand(a:args)
endfunction

function! s:ObjectLines(obj) abort
  if a:obj.kind ==# 'work'
    return readfile(s:Full(a:obj.root, a:obj.path))
  endif
  let tmp = tempname()
  let [err, status] = s:RunToFile(a:obj.root, ['cat', '--', s:BlobTarget(a:obj)], tmp)
  let lines = status ? [] : readfile(tmp)
  call delete(tmp)
  if status
    call s:Throw(err)
  endif
  return lines
endfunction

function! subvim#Read(args) abort
  try
    let obj = s:DefaultObject(a:args)
    let lines = s:ObjectLines(obj)
    let save = &l:modifiable
    setlocal modifiable
    silent keepjumps %delete _
    call setline(1, lines)
    let &l:modifiable = save
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Write the buffer and stage the result (git add).  In a blob, write its
" contents to the working file first (git checkout).
function! subvim#Write(args, bang) abort
  try
    let cur = s:CurrentFile()
    if cur.kind ==# 'blob'
      let lines = getline(1, '$')
      let full = s:Full(cur.root, cur.path)
      call writefile(lines, full)
      exe 'edit ' . fnameescape(fnamemodify(full, ':~:.'))
      let path = cur.path
    elseif empty(a:args)
      exe 'write' . (a:bang ? '!' : '')
      let path = cur.path
    else
      let full = fnamemodify(expand(a:args), ':p')
      exe 'write' . (a:bang ? '!' : '') . ' ' . fnameescape(full)
      let path = s:Rel(cur.root, full)
    endif
    let st = s:Status(cur.root)
    if has_key(st.bypath, path)
      call s:Stage(cur.root, [st.bypath[path]])
    endif
    call s:Changed(cur.root)
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Section: Diff {{{1

function! s:ConflictFiles(root, path) abort
  let [out, status] = s:Run(a:root, ['info', '--', a:path])
  if status
    return []
  endif
  let ours = matchstr(out, 'Conflict Previous Working File: \zs[^\n]*')
  let theirs = matchstr(out, 'Conflict Current Base File: \zs[^\n]*')
  if empty(ours) || empty(theirs)
    return []
  endif
  let dir = fnamemodify(s:Full(a:root, a:path), ':h')
  return map([ours, theirs], 'v:val =~# "^/" ? v:val : dir . "/" . v:val')
endfunction

function! subvim#Diffsplit(autodir, keepfocus, mods, args) abort
  try
    let cur = s:CurrentFile()
    let mods = substitute(a:mods, '^\s*$', '', '')
    if cur.kind ==# 'work' && (empty(a:args) || a:args ==# '++conflict')
      let conflict = s:ConflictFiles(cur.root, cur.path)
      if !empty(conflict)
        return s:Diff3(conflict, mods)
      endif
    endif
    let obj = s:DefaultObject(a:args)
    if a:autodir && &diffopt =~# 'vertical' && mods !~# '\<vert\%[ical]\>'
      let mods = 'vertical ' . mods
    endif
    let back = win_getid()
    diffthis
    let w:subvim_diff = 1
    exe 'leftabove ' . mods . ' split ' . fnameescape(s:Url(obj))
    diffthis
    let w:subvim_diff = 1
    if a:keepfocus
      call win_gotoid(back)
    endif
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Three-way diff of a conflicted file: ours on the left, theirs on the right.
function! s:Diff3(files, mods) abort
  let mods = a:mods =~# '\<vert' || a:mods =~# '\<hor' ? a:mods : 'vertical ' . a:mods
  let back = win_getid()
  let bufs = []
  diffthis
  let w:subvim_diff = 1
  for [file, where] in [[a:files[0], 'leftabove'], [a:files[1], 'rightbelow']]
    call win_gotoid(back)
    exe where . ' ' . mods . ' split ' . fnameescape(fnamemodify(file, ':~:.'))
    setlocal nomodifiable readonly
    diffthis
    let w:subvim_diff = 1
    call add(bufs, bufnr(''))
  endfor
  call win_gotoid(back)
  exe 'nnoremap <buffer> <silent> d2o :<C-U>diffget ' . bufs[0] . '<Bar>diffupdate<CR>'
  exe 'nnoremap <buffer> <silent> d3o :<C-U>diffget ' . bufs[1] . '<Bar>diffupdate<CR>'
  return ''
endfunction

function! subvim#DiffClose() abort
  let back = win_getid()
  for nr in reverse(range(1, winnr('$')))
    if nr != winnr() && getwinvar(nr, 'subvim_diff', 0)
      exe nr . 'close'
    endif
  endfor
  call win_gotoid(back)
  diffoff
  unlet! w:subvim_diff
  return ''
endfunction

" Section: :SMove, :SDelete {{{1

function! subvim#Move(dest, force, rename) abort
  try
    let cur = s:CurrentFile()
    if cur.kind !=# 'work'
      call s:Throw('can only move working copy files')
    endif
    let src = s:Full(cur.root, cur.path)
    if a:dest =~# '^/'
      let dest = s:Full(cur.root, a:dest[1:])
    elseif a:rename
      let dest = fnamemodify(src, ':h') . '/' . a:dest
    else
      let dest = fnamemodify(a:dest, ':p')
    endif
    if isdirectory(dest)
      let dest = substitute(dest, '/$', '', '') . '/' . fnamemodify(src, ':t')
    endif
    if &modified
      write
    endif
    call s:Svn(cur.root, ['move'] + (a:force ? ['--force'] : []) + ['--', src, dest])
    let st = s:Status(cur.root)
    let items = filter(map([cur.path, s:Rel(cur.root, dest)], 'get(st.bypath, v:val, {})'), '!empty(v:val)')
    call s:Stage(cur.root, items)
    exe 'silent keepalt file ' . fnameescape(fnamemodify(dest, ':~:.'))
    edit!
    call s:Changed(cur.root)
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

function! subvim#Delete(mode, force) abort
  try
    let cur = s:CurrentFile()
    if cur.kind !=# 'work'
      call s:Throw('can only delete working copy files')
    endif
    if &modified && !a:force
      call s:Throw('buffer has unsaved changes (add ! to discard them)')
    endif
    call s:Svn(cur.root, ['delete'] + (a:force ? ['--force'] : []) + ['--', cur.path])
    let st = s:Status(cur.root)
    if has_key(st.bypath, cur.path)
      call s:Stage(cur.root, [st.bypath[cur.path]])
    endif
    if a:mode ==# 'delete'
      exe 'bdelete' . (a:force ? '!' : '')
    else
      edit!
    endif
    call s:Changed(cur.root)
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Section: :SBrowse {{{1

function! subvim#Browse(bang, line1, line2, range, args) abort
  try
    let obj = empty(a:args) ? s:Current() : s:Expand(a:args)
    if empty(obj)
      call s:Throw('not a Subversion working copy')
    endif
    let info = s:Info(obj.root)
    if obj.kind ==# 'revision' || obj.kind ==# 'status' || obj.kind ==# 'other'
      let url = obj.kind ==# 'revision' ? info.repos : info.url
      let path = ''
    elseif obj.path =~# '^\^/'
      let url = info.repos . obj.path[1:]
      let path = obj.path[1:]
    else
      let url = info.url . (obj.path ==# '.' ? '' : '/' . obj.path)
      let path = info.relative[1:] . (obj.path ==# '.' ? '' : '/' . obj.path)
    endif
    let opts = {'url': url, 'repos': info.repos, 'path': path, 'rev': obj.rev,
          \ 'kind': obj.kind, 'line1': a:range ? a:line1 : 0, 'line2': a:range ? a:line2 : 0}
    let result = ''
    for Handler in get(g:, 'subvim_browse_handlers', [])
      let result = call(Handler, [copy(opts)])
      if !empty(result)
        break
      endif
    endfor
    if empty(result)
      let result = url
      if obj.rev =~# '^\d\+$'
        let result .= '?p=' . obj.rev
      endif
    endif
    if a:bang
      if has('clipboard')
        let @+ = result
        let @* = result
      endif
      let @" = result
      echo result
    elseif exists(':Open') == 2
      exe 'Open ' . fnameescape(result)
    elseif exists('*netrw#BrowseX')
      call netrw#BrowseX(result, 0)
    else
      echo result
    endif
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Section: :Sgrep, :Sclog, :Scd {{{1

function! subvim#Grep(type, bang, args) abort
  try
    let root = s:RootOrThrow()
    let cmd = 'cd ' . shellescape(root) . ' && grep -rnI --exclude-dir=.svn ' . a:args . ' .'
    let lines = map(systemlist(cmd), 'substitute(v:val, "^\\./", "", "")')
    let lines = map(lines, 'fnamemodify(s:Full(root, matchstr(v:val, "^[^:]*")), ":~:.") . matchstr(v:val, ":.*")')
    let efm = &errorformat
    try
      let &errorformat = '%f:%l:%m'
      exe a:type . 'getexpr lines'
    finally
      let &errorformat = efm
    endtry
    let title = ':S' . (a:type ==# 'c' ? '' : 'l') . 'grep ' . a:args
    if a:type ==# 'c'
      call setqflist([], 'a', {'title': title})
    else
      call setloclist(0, [], 'a', {'title': title})
    endif
    if empty(lines)
      return s:Warn('no matches')
    elseif !a:bang
      exe a:type . 'first'
    endif
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Parse `svn log` output into [{rev, author, date, subject, message}].
function! s:ParseLog(out) abort
  let entries = []
  let entry = {}
  let state = ''
  for line in split(a:out, "\n")
    if line =~# s:sep_line
      if !empty(entry)
        call add(entries, entry)
      endif
      let [entry, state] = [{}, 'header']
    elseif state ==# 'header'
      let m = matchlist(line, '^r\(\d\+\) | \(.\{-}\) | \(\S\+ \S\+\)')
      if !empty(m)
        let entry = {'rev': m[1], 'author': m[2], 'date': m[3], 'message': [], 'paths': []}
        let state = 'meta'
      endif
    elseif state ==# 'meta'
      if line =~# '^Changed paths:'
        continue
      elseif line =~# '^   \u '
        call add(entry.paths, line)
      elseif empty(line)
        let state = 'message'
      endif
    elseif state ==# 'message'
      call add(entry.message, line)
    endif
  endfor
  if !empty(entry)
    call add(entries, entry)
  endif
  for entry in entries
    let entry.subject = get(filter(copy(entry.message), '!empty(v:val)'), 0, '')
  endfor
  return entries
endfunction

function! subvim#Log(type, bang, count, args) abort
  try
    let cur = s:Current()
    let root = empty(cur) ? s:RootOrThrow() : cur.root
    let argv = s:SplitArgs(a:args)
    let [opts, paths, i] = [[], [], 0]
    while i < len(argv)
      if argv[i] =~# '^\%(-l\|--limit\|-r\|--revision\|-c\|--change\|--search\|--search-and\|--depth\)$' && i + 1 < len(argv)
        let opts += argv[i : i + 1]
        let i += 1
      elseif argv[i] =~# '^-'
        call add(opts, argv[i])
      else
        call add(paths, argv[i])
      endif
      let i += 1
    endwhile
    let file = ''
    if a:count == 0
      let file = s:CurrentFile().path
    elseif len(paths) == 1 && paths[0] !~# '^\^/'
      let file = s:Expand(paths[0]).path
    endif
    if !empty(file)
      let target = s:Info(root).url . '/' . file
    elseif !empty(paths)
      let target = paths[0]
    else
      " Use the URL so that history newer than the working copy is shown.
      let target = s:Info(root).url
    endif
    if empty(filter(copy(opts), 'v:val =~# "^\\%(-l\\|--limit\\|-r\\|--revision\\|-c\\|--change\\)"'))
      let opts += ['-l', get(g:, 'subvim_log_limit', 256)]
    endif
    let out = s:Svn(root, ['log'] + opts + ['--', target])
    let list = []
    for entry in s:ParseLog(out)
      let obj = empty(file) ? {'root': root, 'kind': 'revision', 'rev': entry.rev, 'path': ''}
            \ : {'root': root, 'kind': 'blob', 'rev': entry.rev, 'path': file}
      call add(list, {'filename': s:Url(obj), 'lnum': 0,
            \ 'module': 'r' . entry.rev . (empty(file) ? '' : ':' . file),
            \ 'text': entry.author . ' ' . entry.date . ': ' . entry.subject})
    endfor
    let title = ':S' . a:type . 'log ' . a:args
    if a:type ==# 'c'
      call setqflist([], ' ', {'items': list, 'title': title})
    else
      call setloclist(0, [], ' ', {'items': list, 'title': title})
    endif
    if empty(list)
      return s:Warn('no log entries')
    elseif !a:bang
      exe a:type . 'first'
    endif
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

function! subvim#Cd(cmd, dir) abort
  try
    let root = s:RootOrThrow()
    exe a:cmd . ' ' . fnameescape(empty(a:dir) ? root : s:Full(root, a:dir))
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

function! s:Difftool(root, conflicts, args, mods) abort
  let st = s:Status(a:root)
  let items = s:Committable(st)
  if a:conflicts
    call filter(items, 'v:val.code ==# "C"')
  endif
  let list = map(copy(items), '{"filename": fnamemodify(s:Full(a:root, v:val.path), ":~:."), "lnum": 1, "text": v:val.code . " " . v:val.section}')
  call setqflist([], ' ', {'items': list, 'title': ':Svn ' . (a:conflicts ? 'mergetool' : 'difftool')})
  if empty(list)
    return s:Warn(a:conflicts ? 'no conflicts' : 'no changes')
  endif
  if index(a:args, '-y') >= 0
    for item in list
      exe 'tabedit ' . fnameescape(item.filename)
      Sdiffsplit
    endfor
    return ''
  endif
  cfirst
  return ''
endfunction

" Section: Blame {{{1

function! s:Blame(args, mods) abort
  let cur = s:CurrentFile()
  let source_win = win_getid()
  if cur.kind ==# 'blob'
    let target = s:BlobTarget(cur)
  else
    let target = cur.path
  endif
  let [out, status] = s:Run(cur.root, ['blame', '-v'] + filter(copy(a:args), 'v:val =~# "^-"') + ['--', target])
  if status
    call s:Throw(out)
  endif
  let entries = []
  for line in split(out, "\n")
    let m = matchlist(line, '^\s*\(\d\+\|-\)\s\+\(\S\+\)\s\+\(\d\{4}-\d\d-\d\d\) \(\d\d:\d\d\)')
    call add(entries, empty(m) ? {'rev': '', 'author': '', 'date': ''} : {'rev': m[1], 'author': m[2], 'date': m[3]})
  endfor
  " svn blames the file on disk (local edits show as '-'); map unsaved
  " buffer changes onto it.
  let current = getline(1, '$')
  if cur.kind ==# 'work' && exists('*diff') && &modified
    let base = readfile(s:Full(cur.root, cur.path))
    if base !=# current
      let mapped = repeat([{}], len(current))
      let [bi, ci] = [0, 0]
      for hunk in diff(base, current, {'output': 'indices'})
        while ci < hunk.to_idx
          let mapped[ci] = get(entries, bi, {})
          let [bi, ci] = [bi + 1, ci + 1]
        endwhile
        let bi += hunk.from_count
        let ci += hunk.to_count
      endfor
      while ci < len(current)
        let mapped[ci] = get(entries, bi, {})
        let [bi, ci] = [bi + 1, ci + 1]
      endwhile
      let entries = map(mapped, 'empty(v:val) ? {"rev": "", "author": "", "date": ""} : v:val')
    endif
  endif
  let revw = max(map(copy(entries), 'len(v:val.rev)')) + 1
  let authw = max(map(copy(entries), 'strdisplaywidth(v:val.author)'))
  let lines = []
  for entry in entries
    if empty(entry.rev) || entry.rev ==# '-'
      call add(lines, printf('%-*s %s', revw + authw + 12, '', 'Not Committed Yet'))
    else
      call add(lines, printf('r%-*s %-*s %s', revw - 1, entry.rev, authw, entry.author, entry.date))
    endif
  endfor
  let top = line('w0')
  let lnum = line('.')
  setlocal scrollbind cursorbind
  let w:subvim_blamed = 1
  exe 'keepalt leftabove vertical new'
  let b:subvim_root = cur.root
  let b:subvim_blame = {'entries': entries, 'source': source_win, 'path': cur.path, 'rev': cur.rev}
  call setline(1, lines)
  setlocal buftype=nofile bufhidden=wipe noswapfile nomodifiable nowrap nolist nonumber norelativenumber
  setlocal nofoldenable foldcolumn=0 winfixwidth scrollbind cursorbind filetype=subvimblame
  silent! exe 'file' fnameescape('[svn blame] ' . cur.path . (empty(cur.rev) ? '' : '@' . cur.rev) . ' ' . bufnr(''))
  exe 'vertical resize ' . (max(map(copy(lines), 'strdisplaywidth(v:val)')) + 1)
  exe 'keepjumps normal! ' . top . 'Gzt' . lnum . 'G'
  syncbind
  let b:subvim_blame.widths = {'C': revw + 1, 'A': revw + authw + 1, 'D': revw + authw + 12}
  augroup subvim_blame
    autocmd! * <buffer>
    autocmd BufWipeout <buffer> call s:BlameLeave(+expand('<abuf>'))
  augroup END
  call s:Map('n', 'gq', ":<C-U>close<CR>")
  call s:Map('n', '<CR>', ":<C-U>execute <SID>BlameCommit('edit', 1)<CR>")
  call s:Map('n', 'o', ":<C-U>execute <SID>BlameCommit('split', 0)<CR>")
  call s:Map('n', 'O', ":<C-U>execute <SID>BlameCommit('tabedit', 0)<CR>")
  call s:Map('n', 'p', ":<C-U>execute <SID>BlameCommit('pedit', 0)<CR>")
  call s:Map('n', '-', ":<C-U>execute <SID>BlameJump(0)<CR>")
  call s:Map('n', 's', ":<C-U>execute <SID>BlameJump(0)<CR>")
  call s:Map('n', 'u', ":<C-U>execute <SID>BlameJump(0)<CR>")
  call s:Map('n', '~', ":<C-U>execute <SID>BlameJump(v:count1)<CR>")
  call s:Map('n', 'P', ":<C-U>execute <SID>BlameJump(v:count1)<CR>")
  for key in ['A', 'C', 'D']
    call s:Map('n', key, ":<C-U>exe 'vertical resize ' . b:subvim_blame.widths['" . key . "']<CR>")
  endfor
  call s:Map('n', 'g?', ":<C-U>help subvim-blame<CR>")
  call s:MapRevert()
  call s:Event('SubvimBlame')
  return ''
endfunction

function! s:BlameLeave(bufnr) abort
  let blame = getbufvar(a:bufnr, 'subvim_blame', {})
  let winnr = win_id2win(get(blame, 'source', 0))
  if winnr
    call setwinvar(winnr, '&scrollbind', 0)
    call setwinvar(winnr, '&cursorbind', 0)
  endif
endfunction

function! s:BlameRev() abort
  let entry = get(b:subvim_blame.entries, line('.') - 1, {})
  if empty(entry) || empty(entry.rev) || entry.rev ==# '-'
    call s:Throw('line not committed yet')
  endif
  return entry.rev
endfunction

function! s:BlameCommit(cmd, leave) abort
  try
    let rev = s:BlameRev()
    let url = s:Url({'root': b:subvim_root, 'kind': 'revision', 'rev': rev})
    if a:leave
      let source = b:subvim_blame.source
      close
      call win_gotoid(source)
    endif
    exe a:cmd . ' ' . fnameescape(url)
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Reblame at the revision under the cursor, or [count] revisions before it.
function! s:BlameJump(back) abort
  try
    let rev = str2nr(s:BlameRev()) - a:back
    if rev < 1
      call s:Throw('no earlier revision')
    endif
    let blame = b:subvim_blame
    let root = b:subvim_root
    let lnum = line('.')
    close
    call win_gotoid(blame.source)
    exe 'edit ' . fnameescape(s:Url({'root': root, 'kind': 'blob', 'rev': rev, 'path': blame.path}))
    exe 'keepjumps ' . min([lnum, line('$')])
    return s:Blame([], '')
  catch /^subvim:/
    return s:Catch()
  endtry
endfunction

" Section: Revisions and log {{{1

function! s:RevisionLoad(url) abort
  let info = s:Info(a:url.root)
  let rev = a:url.rev
  let log = s:Svn(a:url.root, ['log', '-v', '-c', rev, '--', info.repos])
  let lines = filter(split(log, "\n"), 'v:val !~# s:sep_line')
  let [diff, status] = s:Run(a:url.root, ['diff', '-c', rev, '--', info.repos])
  if !status && !empty(diff)
    call extend(lines, [''] + split(diff, "\n"))
  endif
  setlocal modifiable noreadonly
  silent keepjumps %delete _
  call setline(1, lines)
  let b:subvim_root = a:url.root
  setlocal buftype=nowrite noswapfile nomodifiable readonly nomodified filetype=subvimlog
  call s:MapRevisionCursor()
  call s:Map('n', '~', ":<C-U>execute subvim#Open('edit', '@' . (str2nr(<SID>Current().rev) - v:count1), '')<CR>")
  call s:Map('n', 'P', ":<C-U>execute subvim#Open('edit', '@' . (str2nr(<SID>Current().rev) - v:count1), '')<CR>")
  call s:Map('n', 'gq', ":<C-U>call <SID>Quit()<CR>")
  call s:Event('SubvimRevision')
endfunction

" Revision of the entry under the cursor in a revision, log or blame buffer.
function! s:CursorRev() abort
  if exists('b:subvim_blame')
    return s:BlameRev()
  endif
  let cur = s:Current()
  if !empty(cur) && cur.kind =~# 'revision\|blob' && cur.rev =~# '^\d\+$'
    return cur.rev
  endif
  let lnum = search('^r\d\+ |', 'bcnW')
  if !lnum
    let lnum = search('^r\d\+ |', 'cnW')
  endif
  if !lnum
    call s:Throw('no revision under cursor')
  endif
  return matchstr(getline(lnum), '^r\zs\d\+')
endfunction

" Convert a repository path such as /trunk/foo.c to a working copy path.
function! s:RepoToWc(root, repopath) abort
  let prefix = s:Info(a:root).relative[1:]
  let path = '/' . substitute(a:repopath, '^/', '', '')
  if path ==# prefix
    return '.'
  elseif stridx(path, prefix . '/') == 0 || prefix ==# ''
    return strpart(path, len(prefix) + 1)
  endif
  return '^' . path
endfunction

" The object under the cursor in a revision or log buffer.
function! s:RevisionCfile() abort
  let root = b:subvim_root
  let rev = s:CursorRev()
  let line = getline('.')
  let m = matchlist(line, '^   \([ADMR]\) \(/.\{-}\)\%( (from \(.*\):\(\d\+\))\)\=$')
  if !empty(m)
    let path = s:RepoToWc(root, m[2])
    let r = m[1] ==# 'D' ? rev - 1 : rev
    return {'root': root, 'kind': 'blob', 'rev': r, 'path': path}
  endif
  let m = matchlist(line, '^\%(---\|+++\) \(\S.\{-}\)\t\=\s*(\%(revision \(\d\+\)\|nonexistent\|working copy\))')
  if !empty(m)
    let path = s:RepoToWc(root, m[1])
    let r = empty(m[2]) ? rev : m[2]
    return {'root': root, 'kind': 'blob', 'rev': r, 'path': path}
  endif
  let index = search('^Index: ', 'bcnW')
  if index && line =~# '^[ +-@]' && index > search('^r\d\+ |', 'bcnW')
    let path = s:RepoToWc(root, matchstr(getline(index), '^Index: \zs.*'))
    let r = line =~# '^-' ? rev - 1 : rev
    return {'root': root, 'kind': 'blob', 'rev': r, 'path': path}
  endif
  return {'root': root, 'kind': 'revision', 'rev': rev, 'path': ''}
endfunction

function! s:RevisionOpen(cmd) abort
  try
    let obj = s:RevisionCfile()
    if obj.kind ==# 'revision' && s:Current().kind ==# 'revision' && a:cmd ==# 'edit'
      return ''
    endif
    exe a:cmd . ' ' . fnameescape(s:Url(obj))
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

function! s:MapRevisionCursor() abort
  call s:Map('n', '<CR>', ":<C-U>execute <SID>RevisionOpen('edit')<CR>")
  call s:Map('n', 'o', ":<C-U>execute <SID>RevisionOpen('split')<CR>")
  call s:Map('n', 'gO', ":<C-U>execute <SID>RevisionOpen('vsplit')<CR>")
  call s:Map('n', 'O', ":<C-U>execute <SID>RevisionOpen('tabedit')<CR>")
  call s:Map('n', 'p', ":<C-U>execute <SID>RevisionOpen('pedit')<CR>")
  call s:Map('n', '(', ":<C-U>call search('^r\\d\\+ <Bar>\\<Bar>^Index: ', 'bW')<CR>")
  call s:Map('n', ')', ":<C-U>call search('^r\\d\\+ <Bar>\\<Bar>^Index: ', 'W')<CR>")
  call s:MapRevert()
endfunction

function! s:MapRevert() abort
  call s:Map('n', 'crc', ":<C-U>execute <SID>RevertRev(1)<CR>")
  call s:Map('n', 'crn', ":<C-U>execute <SID>RevertRev(0)<CR>")
  call s:Map('n', 'cr<Space>', ':Svn merge -c -', '')
  call s:Map('n', 'coo', ":<C-U>execute <SID>CheckoutRev()<CR>")
  call s:Map('n', 'cr?', ":<C-U>help subvim_cr<CR>")
endfunction

" Undo a revision with a reverse merge, stage the result and optionally open
" a commit message (git revert / git revert -n).
function! s:RevertRev(commit) abort
  try
    let root = b:subvim_root
    let rev = s:CursorRev()
    let info = s:Info(root)
    let out = s:Svn(root, ['merge', '-c', '-' . rev, '--', info.url, '.'])
    let st = s:Status(root)
    let paths = []
    for line in split(out, "\n")
      let m = matchlist(line, '^\([ADUCGER ]\)\([ADUCGER ]\)\([ C]\)\s\+\(.\+\)$')
      if !empty(m) && line !~# '^--- '
        call add(paths, m[4])
      endif
    endfor
    let items = filter(map(s:Uniq(paths), 'get(st.bypath, v:val, {})'), '!empty(v:val) && v:val.code !=# "C"')
    call s:Stage(root, items)
    call s:Changed(root)
    if !empty(filter(copy(items), 'v:val.code ==# "C"')) || out =~# '\n\s*C\s'
      call s:StatusOpen(root, '')
      return s:Warn('reverse merge of r' . rev . ' has conflicts; resolve them, then stage and commit')
    endif
    if a:commit
      let entries = s:ParseLog(s:Svn(root, ['log', '-c', rev, '--', info.repos]))
      let subject = empty(entries) ? '' : entries[0].subject
      let st = s:Status(root)
      return s:CommitOpen({'root': root, 'paths': [], 'items': st.Staged, 'opts': []}, 0,
            \ ['Revert r' . rev . (empty(subject) ? '' : ': ' . subject), '', 'This reverts r' . rev . '.'], '')
    endif
    echo 'subvim: reverted r' . rev . ' in the working copy (staged, not committed)'
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

function! s:CheckoutRev() abort
  try
    let root = b:subvim_root
    let rev = s:CursorRev()
    echo s:Svn(root, ['update', '-r', rev])
    call s:Changed(root)
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

" Section: Branches {{{1

let s:branch_cache = {}

function! s:BranchNames(root, kind) abort
  if empty(a:root)
    return []
  endif
  let key = a:root . "\n" . a:kind
  if has_key(s:branch_cache, key) && localtime() - s:branch_cache[key][0] < 30
    return copy(s:branch_cache[key][1])
  endif
  let layout = s:Layout(a:root)
  let dir = get(g:, 'subvim_' . a:kind, a:kind)
  let [out, status] = s:Run(a:root, ['list', '--', layout.base . '/' . dir])
  let names = status ? [] : map(filter(split(out, "\n"), 'v:val =~# "/$"'), 'v:val[0:-2]')
  let s:branch_cache[key] = [localtime(), names]
  return copy(names)
endfunction

function! s:BranchUrl(root, name) abort
  let layout = s:Layout(a:root)
  if empty(layout.kind)
    call s:Throw('working copy is not in a trunk/branches/tags layout (see g:subvim_trunk)')
  endif
  let trunk = get(g:, 'subvim_trunk', 'trunk')
  if a:name ==# trunk
    return layout.base . '/' . trunk
  elseif a:name =~# '/'
    return layout.base . '/' . a:name
  endif
  return layout.base . '/' . get(g:, 'subvim_branches', 'branches') . '/' . a:name
endfunction

" :Svn branch [-d] [NAME] [-m MSG], :Svn tag likewise.
function! s:BranchCommand(root, kind, args) abort
  let dir = get(g:, 'subvim_' . a:kind, a:kind)
  let layout = s:Layout(a:root)
  if empty(layout.kind)
    call s:Throw('working copy is not in a trunk/branches/tags layout (see g:subvim_trunk)')
  endif
  let args = copy(a:args)
  let msg = ''
  let i = index(args, '-m')
  if i >= 0 && i + 1 < len(args)
    let msg = args[i + 1]
    call remove(args, i, i + 1)
  endif
  if empty(args)
    let names = s:BranchNames(a:root, a:kind)
    if a:kind ==# 'branches'
      call insert(names, get(g:, 'subvim_trunk', 'trunk'))
    endif
    if a:kind ==# 'tags'
      let current = layout.kind ==# 'tag' ? layout.name : ''
    else
      let current = layout.kind =~# '^\%(trunk\|branch\)$' ? layout.name : ''
    endif
    echo join(map(names, '(v:val ==# current ? "* " : "  ") . v:val'), "\n")
    return ''
  endif
  if args[0] =~# '^\%(-d\|-D\|--delete\)$'
    let name = get(args, 1, '')
    let url = layout.base . '/' . dir . '/' . name
    echo s:Svn(a:root, ['delete', '-m', empty(msg) ? 'Delete ' . a:kind[0:-2] . ' ' . name : msg, '--', url])
  else
    let name = args[0]
    let from = len(args) > 1 ? s:BranchUrl(a:root, args[1]) : layout.branch
    let url = layout.base . '/' . dir . '/' . name
    let msg = empty(msg) ? 'Create ' . (a:kind ==# 'tags' ? 'tag ' : 'branch ') . name . ' from ' . s:BranchLabel(a:root) : msg
    echo s:Svn(a:root, ['copy', '-m', msg, '--', from, url])
    if a:kind ==# 'branches'
      echo 'subvim: switch to it with :Svn switch ' . name
    endif
  endif
  let s:branch_cache = {}
  return ''
endfunction

" :Svn switch NAME accepts plain branch names (or trunk).
function! s:Switch(root, args) abort
  let args = copy(a:args)
  for i in range(len(args))
    if args[i] !~# '^-' && (i == 0 || args[i - 1] !~# '^\%(-r\|--revision\|--depth\|--set-depth\|--accept\)$')
      if args[i] !~# '^\^\|://\|^\.\|^/'
        let args[i] = s:BranchUrl(a:root, args[i]) . s:Layout(a:root).sub
      endif
      break
    endif
  endfor
  let [out, status] = s:Run(a:root, ['switch'] + args)
  call s:Changed(a:root)
  if status
    return s:Error(out)
  endif
  echo out
  return ''
endfunction

" Section: Stash {{{1

" Stashes, newest first: [{id, dir, message, staged, dirs}]
function! s:StashList(root) abort
  let base = s:Data(a:root, 'stash')
  if !isdirectory(base)
    return []
  endif
  let list = []
  for dir in reverse(sort(glob(base . '/*', 1, 1)))
    let meta = dir . '/message'
    call add(list, {'dir': dir, 'message': filereadable(meta) ? get(readfile(meta), 0, '') : '',
          \ 'staged': filereadable(dir . '/staged') ? readfile(dir . '/staged') : [],
          \ 'strip': filereadable(dir . '/strip') ? str2nr(get(readfile(dir . '/strip'), 0, '0')) : 0})
  endfor
  return list
endfunction

function! s:Strip(root) abort
  return len(split(s:Info(a:root).relative[1:], '/'))
endfunction

function! s:StashPush(root, scope, untracked, msg) abort
  let st = s:Status(a:root)
  if a:untracked && !empty(st.Unversioned)
    call s:Svn(a:root, ['add', '--depth', 'infinity', '--'] + map(copy(st.Unversioned), 'v:val.path'))
    let st = s:Status(a:root)
  endif
  if a:scope ==# 'staged'
    let items = st.Staged
  elseif a:scope ==# 'keep'
    let items = st.Unstaged
  else
    let items = s:Committable(st)
  endif
  if empty(items)
    return s:Warn('no local changes to save')
  endif
  let paths = map(copy(items), 'v:val.path')
  let id = strftime('%Y%m%d-%H%M%S') . printf('-%03d', len(s:StashList(a:root)))
  let dir = s:Data(a:root, 'stash/' . id)
  call mkdir(dir, 'p')
  let patch = dir . '/patch.diff'
  let [err, status] = s:RunToFile(a:root, ['diff', '--git', '--depth', 'empty', '--'] + paths, patch)
  if status || getfsize(patch) <= 0
    call delete(dir, 'rf')
    return s:Error(status ? err : 'no local changes to save')
  endif
  let msg = empty(a:msg) ? 'WIP on ' . s:BranchLabel(a:root) . '@r' . s:Info(a:root).revision : 'On ' . s:BranchLabel(a:root) . ': ' . a:msg
  call writefile([msg], dir . '/message')
  call writefile(map(filter(copy(items), 'v:val.section ==# "Staged"'), 'v:val.path'), dir . '/staged')
  call writefile([s:Strip(a:root)], dir . '/strip')
  " Reset the stashed paths.
  call s:ChangelistRemove(a:root, paths)
  let deep = map(filter(copy(items), 'v:val.code =~# "[ADR]"'), 'v:val.path')
  let shallow = map(filter(copy(items), 'v:val.code !~# "[ADR]"'), 'v:val.path')
  if !empty(deep)
    call s:Svn(a:root, ['revert', '--depth', 'infinity'] + s:Targets(deep))
  endif
  if !empty(shallow)
    call s:Svn(a:root, ['revert', '--depth', 'empty'] + s:Targets(shallow))
  endif
  for item in reverse(sort(filter(copy(items), 'v:val.code ==# "A"'), {a, b -> a.path ==# b.path ? 0 : a.path ># b.path ? 1 : -1}))
    call delete(s:Full(a:root, item.path), 'rf')
  endfor
  call s:Changed(a:root)
  echo 'Saved working copy state stash@{0}: ' . msg
  return ''
endfunction

function! s:StashIndex(args) abort
  let n = get(filter(copy(a:args), 'v:val !~# "^-"'), 0, '0')
  return str2nr(matchstr(n, '\d\+'))
endfunction

function! s:StashGet(root, n) abort
  let list = s:StashList(a:root)
  if a:n >= len(list)
    call s:Throw(empty(list) ? 'no stash entries found' : 'stash@{' . a:n . '} does not exist')
  endif
  return list[a:n]
endfunction

function! s:StashApply(root, n, index, drop) abort
  let entry = s:StashGet(a:root, a:n)
  let [out, status] = s:Run(a:root, ['patch', '--strip', entry.strip, '--', entry.dir . '/patch.diff', '.'])
  let conflicts = status || out =~# '\%(^\|\n\)\%(C \|>\|Skipped\)'
  if a:index && !empty(entry.staged)
    let st = s:Status(a:root)
    let items = filter(map(copy(entry.staged), 'get(st.bypath, v:val, {})'), '!empty(v:val)')
    call s:ChangelistAdd(a:root, map(items, 'v:val.path'))
  endif
  if conflicts
    call s:Changed(a:root)
    return s:Error(out . "\nstash@{" . a:n . '} was kept because it did not apply cleanly')
  endif
  if a:drop
    call delete(entry.dir, 'rf')
  endif
  call s:Changed(a:root)
  echo (a:drop ? 'Dropped stash@{' . a:n . '} (' : 'Applied stash@{' . a:n . '} (') . entry.message . ')'
  return ''
endfunction

function! s:StashCommand(root, args, mods) abort
  let sub = get(a:args, 0, 'push')
  let rest = a:args[1:]
  if sub =~# '^-'
    let [sub, rest] = ['push', a:args]
  endif
  if sub ==# 'push' || sub ==# 'save'
    let [scope, untracked, msg, words] = ['all', 0, '', []]
    let i = 0
    while i < len(rest)
      let arg = rest[i]
      if arg =~# '^\%(-u\|--include-untracked\|-a\|--all\)$'
        let untracked = 1
      elseif arg =~# '^\%(-k\|--keep-index\)$'
        let scope = 'keep'
      elseif arg =~# '^\%(-S\|--staged\)$'
        let scope = 'staged'
      elseif arg =~# '^\%(-m\|--message\)$'
        let msg = get(rest, i + 1, '')
        let i += 1
      else
        call add(words, arg)
      endif
      let i += 1
    endwhile
    return s:StashPush(a:root, scope, untracked, empty(msg) ? join(words) : msg)
  elseif sub ==# 'list'
    let list = s:StashList(a:root)
    echo join(map(list, '"stash@{" . v:key . "}: " . v:val.message'), "\n")
    return ''
  elseif sub ==# 'show'
    let entry = s:StashGet(a:root, s:StashIndex(rest))
    exe (empty(a:mods) ? '' : a:mods . ' ') . 'split ' . fnameescape(entry.dir . '/patch.diff')
    setlocal readonly nomodifiable bufhidden=wipe
    return ''
  elseif sub ==# 'apply' || sub ==# 'pop'
    return s:StashApply(a:root, s:StashIndex(rest), index(rest, '--index') >= 0, sub ==# 'pop')
  elseif sub ==# 'drop'
    let n = s:StashIndex(rest)
    let entry = s:StashGet(a:root, n)
    call delete(entry.dir, 'rf')
    call s:Changed(a:root)
    echo 'Dropped stash@{' . n . '} (' . entry.message . ')'
    return ''
  elseif sub ==# 'clear'
    call delete(s:Data(a:root, 'stash'), 'rf')
    call s:Changed(a:root)
    return ''
  endif
  call s:Throw('unknown stash subcommand ' . sub)
endfunction

function! s:StashMap(args) abort
  try
    let args = map(copy(a:args), 'type(v:val) == type(0) ? string(v:val) : v:val')
    return s:StashCommand(b:subvim_root, args, '')
  catch /^subvim:/
    return s:Catch()
  endtry
endfunction

" Section: Properties {{{1

" Edit a property (e.g. svn:ignore) in a buffer; writing it sets the property.
function! s:PropEdit(root, prop, path, append, mods) abort
  try
    let [out, status] = s:Run(a:root, ['propget', a:prop, '--', a:path])
    let lines = status || empty(out) ? [] : split(out, "\n")
    if !empty(a:append) && index(lines, a:append) < 0
      call add(lines, a:append)
    endif
    let name = 'subvimprop://' . a:root . '//' . a:path . '//' . a:prop
    exe (empty(a:mods) ? '' : a:mods . ' ') . 'split ' . fnameescape(name)
    let b:subvim_root = a:root
    let b:subvim_prop = {'prop': a:prop, 'path': a:path}
    setlocal buftype=acwrite bufhidden=wipe noswapfile
    silent keepjumps %delete _
    call setline(1, empty(lines) ? [''] : lines)
    setlocal nomodified
    augroup subvim_prop
      autocmd! * <buffer>
      autocmd BufWriteCmd <buffer> call s:PropWrite()
    augroup END
    if !empty(a:append)
      call search('^' . escape(a:append, '\.*~[]^$') . '$', 'w')
      setlocal modified
    endif
  catch /^subvim:/
    return s:Catch()
  endtry
  return ''
endfunction

function! s:PropWrite() abort
  try
    let lines = filter(getline(1, '$'), '!empty(v:val)')
    let p = b:subvim_prop
    if empty(lines)
      call s:Run(b:subvim_root, ['propdel', p.prop, '--', p.path])
    else
      let tmp = tempname()
      call writefile(lines, tmp)
      call s:Svn(b:subvim_root, ['propset', p.prop, '-F', tmp, '--', p.path])
      call delete(tmp)
    endif
    setlocal nomodified
    call s:Changed(b:subvim_root)
    echo 'subvim: set ' . p.prop . ' on ' . p.path
  catch /^subvim:/
    return s:Catch()
  endtry
endfunction

" Section: Global maps {{{1

function! subvim#ObjectPath() abort
  let cur = s:Current()
  if empty(cur)
    return ''
  elseif cur.kind ==# 'blob'
    return s:BlobTarget(cur)
  elseif cur.kind ==# 'revision'
    return '@' . cur.rev
  endif
  return cur.path
endfunction

function! subvim#BufferMaps() abort
  if exists('b:subvim_buffer_maps') || get(g:, 'subvim_no_maps', 0)
    return
  endif
  let b:subvim_buffer_maps = 0
  if empty(subvim#Root())
    return
  endif
  let b:subvim_buffer_maps = 1
  cnoremap <buffer> <expr> <C-R><C-G> fnameescape(subvim#ObjectPath())
  nnoremap <buffer> <silent> y<C-G> :<C-U>call setreg(v:register, subvim#ObjectPath())<CR>
  nnoremap <buffer> <silent> dq :<C-U>call subvim#DiffClose()<CR>
endfunction

" vim:set et sw=2 foldmethod=marker:
