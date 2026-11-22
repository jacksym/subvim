" Location:     autoload/subvim.vim
" Subversion counterpart to fugitive.vim.  Keybindings follow fugitive so the
" workflow is the same; where git "stages", Subversion "adds".

if exists('g:autoloaded_subvim')
  finish
endif
let g:autoloaded_subvim = 1

let s:ignore_line = '--This line, and those below, will be ignored--'

" Section helpers {{{1

function! s:Throw(msg) abort
  throw 'subvim: ' . a:msg
endfunction

function! s:Error(msg) abort
  echohl ErrorMsg
  echomsg 'subvim: ' . a:msg
  echohl NONE
  return ''
endfunction

function! s:Map(mode, lhs, rhs) abort
  exe a:mode . 'noremap <buffer> <silent> <nowait> ' . a:lhs . ' ' . a:rhs
endfunction

" Run svn with a list of arguments in directory dir.  Returns [output, status].
function! s:Run(dir, args) abort
  let cmd = 'cd ' . shellescape(a:dir) . ' && svn --non-interactive '
        \ . join(map(copy(a:args), 'shellescape(v:val)'), ' ')
  let out = system(cmd)
  return [substitute(out, '\n\+$', '', ''), v:shell_error]
endfunction

" Working copy detection {{{1

function! subvim#Root(...) abort
  if a:0 && type(a:1) == type('') && !empty(a:1)
    let path = fnamemodify(a:1, ':p')
  elseif exists('b:subvim_root')
    return b:subvim_root
  elseif empty(&buftype) && !empty(expand('%'))
    let path = expand('%:p')
  else
    let path = getcwd()
  endif
  let dir = isdirectory(path) ? path : fnamemodify(path, ':h')
  " Walk up looking for .svn; SVN >= 1.7 keeps a single .svn at the root.
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

" :Svn {{{1

let s:subcommands = ['add', 'blame', 'cat', 'changelist', 'checkout',
      \ 'cleanup', 'commit', 'copy', 'delete', 'diff', 'export', 'help',
      \ 'import', 'info', 'list', 'lock', 'log', 'merge', 'mergeinfo',
      \ 'mkdir', 'move', 'patch', 'propdel', 'propedit', 'propget',
      \ 'proplist', 'propset', 'relocate', 'resolve', 'resolved', 'revert',
      \ 'status', 'switch', 'unlock', 'update', 'upgrade']

function! subvim#Complete(A, L, P) abort
  let pre = strpart(a:L, 0, a:P)
  if pre =~# '^\s*\S*\s\+\S*$'
    return filter(copy(s:subcommands), 'v:val =~# "^" . a:A')
  endif
  return map(getcompletion(a:A, 'file'), 'fnameescape(v:val)')
endfunction

function! subvim#Command(args, bang, mods) abort
  try
    let root = s:RootOrThrow()
    if a:args =~# '^\s*$'
      return s:StatusOpen(root, a:mods)
    endif
    let argv = map(split(a:args, '\%(\\\@<!\s\)\+'),
          \ 'expandcmd(substitute(v:val, "\\\\\\(\\s\\)", "\\1", "g"))')
    let sub = argv[0]
    if sub =~# '^\%(commit\|ci\)$'
      let rest = argv[1:]
      if empty(filter(copy(rest), 'v:val =~# "^\\%(-m\\|-F\\|--message\\|--file\\)\\%(=\\|$\\)\\|^-[mF]."'))
        return s:CommitOpen(root, rest, a:mods)
      endif
    endif
    let [out, status] = s:Run(getcwd(), argv)
    call subvim#ReloadStatus()
    if status
      return s:Error(empty(out) ? 'svn ' . sub . ' failed' : out)
    endif
    if !empty(out)
      echo out
    endif
    return ''
  catch /^subvim:/
    return 'echoerr ' . string(v:exception)
  endtry
endfunction

" Status parsing {{{1

" Parse `svn status` into lists of items, each {'code', 'path', 'section'}.
function! s:Status(root) abort
  let [out, status] = s:Run(a:root, ['status', '--ignore-externals'])
  if status
    call s:Throw(out)
  endif
  let sections = {'Unversioned': [], 'Missing': [], 'Changes': []}
  for line in split(out, "\n")
    " Columns 1-7 are flags, column 8 is a space, path starts at column 9.
    if line !~# '^.\{7} \S' || line =~# '^\s*>' || line =~# '^--- Changelist'
      continue
    endif
    let flags = line[0:6]
    let path = line[8:]
    let c1 = flags[0]
    let c2 = flags[1]
    if c1 ==# '?'
      call add(sections.Unversioned, {'code': '?', 'path': path})
    elseif c1 ==# '!'
      call add(sections.Missing, {'code': '!', 'path': path})
    elseif c1 =~# '[AMDRC~]'
      call add(sections.Changes, {'code': c1, 'path': path})
    elseif c2 =~# '[MC]'
      " Property-only modification or property conflict.
      call add(sections.Changes, {'code': c2, 'path': path})
    elseif flags[6] ==# 'C'
      call add(sections.Changes, {'code': 'C', 'path': path})
    endif
  endfor
  return sections
endfunction

function! s:Info(root) abort
  let [out, status] = s:Run(a:root, ['info', '--show-item', 'url'])
  let url = status ? '' : out
  let [rev, status] = s:Run(a:root, ['info', '--show-item', 'revision'])
  let [rel, status2] = s:Run(a:root, ['info', '--show-item', 'relative-url'])
  return {'url': url, 'revision': status ? '' : rev, 'relative': status2 ? '' : rel}
endfunction

" Status buffer {{{1

let s:section_order = ['Unversioned', 'Missing', 'Changes']

function! s:StatusBufName(root) abort
  return 'subvim://' . a:root . '//'
endfunction

function! s:StatusOpen(root, mods) abort
  let name = s:StatusBufName(a:root)
  let winnr = bufwinnr('^' . escape(name, '\.*~[]^$') . '$')
  if winnr > 0
    exe winnr . 'wincmd w'
    call s:StatusRender()
    return ''
  endif
  exe (empty(a:mods) ? '' : a:mods . ' ') . 'split ' . fnameescape(name)
  call s:StatusSetup(a:root)
  call s:StatusRender()
  return ''
endfunction

function! s:StatusSetup(root) abort
  let b:subvim_root = a:root
  let b:subvim_status = 1
  setlocal buftype=nofile bufhidden=hide noswapfile nomodeline nobuflisted
  setlocal nomodifiable nolist nowrap foldmethod=syntax foldlevel=1
  setlocal filetype=subvim
  augroup subvim_status_buffer
    autocmd! * <buffer>
    autocmd BufEnter <buffer> call s:StatusRender()
  augroup END
  call s:MapStatus()
endfunction

function! s:StatusRender() abort
  if !exists('b:subvim_status')
    return
  endif
  let root = b:subvim_root
  try
    let sections = s:Status(root)
  catch /^subvim:/
    return s:Error(v:exception)
  endtry
  let info = s:Info(root)
  let lines = ['Root: ' . root]
  call add(lines, 'Repository: ' . (empty(info.relative) ? info.url : info.relative))
  if !empty(info.revision)
    call add(lines, 'Revision: r' . info.revision)
  endif
  call add(lines, 'Help: g?')
  let items = {}
  for name in s:section_order
    let list = sections[name]
    if empty(list)
      continue
    endif
    call extend(lines, ['', name . ' (' . len(list) . ')'])
    for item in list
      call add(lines, item.code . ' ' . item.path)
      let items[len(lines)] = extend(copy(item), {'section': name})
    endfor
  endfor
  if empty(sections.Unversioned) && empty(sections.Missing) && empty(sections.Changes)
    call extend(lines, ['', 'Nothing to commit, working copy clean'])
  endif
  let b:subvim_items = items
  let pos = getpos('.')
  setlocal modifiable
  silent keepjumps %delete _
  call setline(1, lines)
  setlocal nomodifiable nomodified
  call setpos('.', pos)
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

" Items under cursor / range {{{1

" Return the items covered by lines first..last.  A section heading selects
" every item in that section.
function! s:Selection(first, last) abort
  let result = []
  let items = get(b:, 'subvim_items', {})
  for lnum in range(a:first, a:last)
    if has_key(items, lnum)
      call add(result, items[lnum])
    elseif getline(lnum) =~# '^\u\l\+ (\d\+)$'
      let section = matchstr(getline(lnum), '^\u\l\+')
      let l = lnum + 1
      while has_key(items, l) && items[l].section ==# section
        if index(result, items[l]) < 0
          call add(result, items[l])
        endif
        let l += 1
      endwhile
    endif
  endfor
  return result
endfunction

function! s:Range(visual) abort
  if a:visual
    return [line("'<"), line("'>")]
  endif
  return [line('.'), line('.') + max([v:count1, 1]) - 1]
endfunction

" Adding (s), un-adding (u), toggling (-) {{{1

" What `s` does to an item: returns the svn subcommand, or '' if nothing.
function! s:AddAction(item) abort
  if a:item.section ==# 'Unversioned'
    return 'add'
  elseif a:item.section ==# 'Missing'
    return 'delete'
  endif
  return ''
endfunction

" What `u` does: only scheduled adds and deletes can be undone without
" touching the user's edits.
function! s:UnaddAction(item) abort
  if a:item.section ==# 'Changes' && a:item.code =~# '^[AD]$'
    return 'revert'
  endif
  return ''
endfunction

function! s:Apply(items, ActionFn, verb) abort
  let root = b:subvim_root
  let groups = {}
  let skipped = []
  for item in a:items
    let action = a:ActionFn(item)
    if empty(action)
      call add(skipped, item)
    else
      let groups[action] = get(groups, action, []) + [item.path]
    endif
  endfor
  if empty(groups)
    if empty(a:items)
      return s:Error('nothing to ' . a:verb . ' here')
    endif
    let item = a:items[0]
    if a:verb ==# 'add'
      return s:Error(item.path . ' is already added (it will be committed)')
    elseif item.code ==# 'M' || item.code ==# 'R'
      return s:Error('cannot un-add a modification: Subversion has no staging area')
    endif
    return s:Error('cannot ' . a:verb . ' ' . item.path)
  endif
  for [action, paths] in items(groups)
    let args = [action]
    if action ==# 'add'
      let args += ['--parents']
    elseif action ==# 'revert'
      let args += ['--depth', 'infinity']
    endif
    let [out, status] = s:Run(root, args + ['--'] + paths)
    if status
      call s:StatusRender()
      return s:Error(out)
    endif
  endfor
  call s:StatusRender()
  return ''
endfunction

function! s:Add(visual) abort
  let [first, last] = s:Range(a:visual)
  return s:Apply(s:Selection(first, last), function('s:AddAction'), 'add')
endfunction

function! s:Unadd(visual) abort
  let [first, last] = s:Range(a:visual)
  return s:Apply(s:Selection(first, last), function('s:UnaddAction'), 'un-add')
endfunction

function! s:Toggle(visual) abort
  let [first, last] = s:Range(a:visual)
  let items = s:Selection(first, last)
  if empty(items)
    return s:Error('nothing to toggle here')
  endif
  if !empty(s:AddAction(items[0]))
    return s:Apply(items, function('s:AddAction'), 'add')
  endif
  return s:Apply(items, function('s:UnaddAction'), 'un-add')
endfunction

" Navigation {{{1

function! s:NextItem(count) abort
  let lnums = sort(map(keys(get(b:, 'subvim_items', {})), 'str2nr(v:val)'), 'n')
  let cur = line('.')
  for _ in range(a:count)
    let next = filter(copy(lnums), 'v:val > cur')
    if empty(next)
      break
    endif
    let cur = next[0]
  endfor
  exe cur
  return ''
endfunction

function! s:PreviousItem(count) abort
  let lnums = reverse(sort(map(keys(get(b:, 'subvim_items', {})), 'str2nr(v:val)'), 'n'))
  let cur = line('.')
  for _ in range(a:count)
    let prev = filter(copy(lnums), 'v:val < cur')
    if empty(prev)
      break
    endif
    let cur = prev[0]
  endfor
  exe cur
  return ''
endfunction

function! s:SectionJump(...) abort
  for name in a:000
    let lnum = search('^' . name . ' (\d\+)$', 'nw')
    if lnum
      exe lnum + 1
      return ''
    endif
  endfor
  return s:Error('no ' . a:1 . ' section')
endfunction

function! s:Open(cmd) abort
  let items = s:Selection(line('.'), line('.'))
  if empty(items)
    return ''
  endif
  let path = b:subvim_root . '/' . items[0].path
  if items[0].section ==# 'Missing' || items[0].code ==# 'D'
    return s:Error(items[0].path . ' does not exist in the working copy')
  endif
  exe a:cmd . ' ' . fnameescape(fnamemodify(path, ':~:.'))
  return ''
endfunction

function! s:Quit() abort
  if winnr('$') == 1 && tabpagenr('$') == 1
    quit
  else
    close
  endif
endfunction

function! s:MapStatus() abort
  call s:Map('n', 's', ":<C-U>execute <SID>Add(0)<CR>")
  call s:Map('x', 's', ":<C-U>execute <SID>Add(1)<CR>")
  call s:Map('n', 'u', ":<C-U>execute <SID>Unadd(0)<CR>")
  call s:Map('x', 'u', ":<C-U>execute <SID>Unadd(1)<CR>")
  call s:Map('n', '-', ":<C-U>execute <SID>Toggle(0)<CR>")
  call s:Map('x', '-', ":<C-U>execute <SID>Toggle(1)<CR>")
  call s:Map('n', 'cc', ":<C-U>Svn commit<CR>")
  call s:Map('n', ')', ":<C-U>execute <SID>NextItem(v:count1)<CR>")
  call s:Map('n', '(', ":<C-U>execute <SID>PreviousItem(v:count1)<CR>")
  call s:Map('n', 'gu', ":<C-U>execute <SID>SectionJump('Unversioned', 'Missing')<CR>")
  call s:Map('n', 'gU', ":<C-U>execute <SID>SectionJump('Missing', 'Unversioned')<CR>")
  call s:Map('n', 'gs', ":<C-U>execute <SID>SectionJump('Changes')<CR>")
  call s:Map('n', '<CR>', ":<C-U>execute <SID>Open('edit')<CR>")
  call s:Map('n', 'o', ":<C-U>execute <SID>Open('split')<CR>")
  call s:Map('n', 'gO', ":<C-U>execute <SID>Open('vsplit')<CR>")
  call s:Map('n', 'O', ":<C-U>execute <SID>Open('tabedit')<CR>")
  call s:Map('n', 'gq', ":<C-U>call <SID>Quit()<CR>")
  call s:Map('n', 'g?', ":<C-U>help subvim-maps<CR>")
endfunction

" Committing {{{1

let s:commits = {}

function! s:CommitOpen(root, targets, mods) abort
  let sections = s:Status(a:root)
  if empty(sections.Changes)
    return s:Error('nothing to commit' . (empty(sections.Unversioned) ? '' : ' (use s to add unversioned files)'))
  endif
  let dir = tempname()
  call mkdir(dir, 'p')
  " The svn-commit*.tmp name gets Vim's built-in svn filetype.
  let file = dir . '/svn-commit.tmp'
  let lines = ['', s:ignore_line, '']
  for item in sections.Changes
    call add(lines, item.code . '    ' . item.path)
  endfor
  call writefile(lines, file)
  exe (empty(a:mods) ? '' : a:mods . ' ') . 'split ' . fnameescape(file)
  setlocal bufhidden=wipe noswapfile
  " Path targets are relative to Vim's cwd but svn runs from the root.
  let targets = map(copy(a:targets), 'v:val =~# "^-" ? v:val : fnamemodify(v:val, ":p")')
  let s:commits[bufnr('')] = {'root': a:root, 'file': file, 'dir': dir,
        \ 'targets': targets, 'written': 0}
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
    let [out, status] = s:Run(state.root, ['commit', '-F', msgfile] + state.targets)
    if status
      return s:Error(out)
    endif
    for line in split(out, "\n")
      echomsg line
    endfor
  finally
    call delete(state.dir, 'rf')
    call subvim#ReloadStatus(state.root)
  endtry
endfunction

" vim:set et sw=2 foldmethod=marker:
