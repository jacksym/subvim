" Runs one test case from $TESTS against the working copy $WC.
" Invoked by test/run.sh; not meant to be sourced directly.
set nocompatible nomore
let &rtp = $PLUGIN . ',' . &rtp
filetype plugin on | syntax on
runtime plugin/subvim.vim
let g:out = $OUT
let g:wc = $WC
exe 'cd' fnameescape(g:wc)
function! Log(msg) abort
  call writefile([a:msg], g:out, 'a')
endfunction
function! Svn(cmd) abort
  return system('cd ' . shellescape(g:wc) . ' && svn ' . a:cmd . ' 2>&1')
endfunction
function! Go(pat) abort
  call cursor(1, 1)
  if !search(a:pat, 'cW')
    throw 'pattern not found: ' . a:pat . "\n" . join(getline(1, '$'), "\n")
  endif
endfunction
function! Section(name) abort
  let lnum = search('^' . a:name . ' (\d\+)$', 'nw')
  if !lnum | return [] | endif
  let res = []
  let l = lnum + 1
  while l <= line('$') && getline(l) !~# '^$'
    if getline(l) =~# '^[MADRC?!~] ' | call add(res, getline(l)) | endif
    let l += 1
  endwhile
  return res
endfunction
function! Test(name, fn) abort
  let v:errors = []
  try
    call call(a:fn, [])
  catch
    call add(v:errors, 'EXCEPTION ' . v:exception . ' @ ' . v:throwpoint)
  endtry
  call Log((empty(v:errors) ? 'PASS ' : 'FAIL ') . a:name)
  for e in v:errors | call Log('    ' . e) | endfor
  if !empty(v:errors) | call Log(execute('messages')) | endif
  only | enew!
endfunction
exe 'source' fnameescape($TESTS)
call Log('DONE')
qa!
