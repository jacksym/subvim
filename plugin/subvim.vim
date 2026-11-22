" subvim.vim - A Subversion wrapper in the spirit of fugitive.vim
" Version:      0.1

if exists('g:loaded_subvim')
  finish
endif
let g:loaded_subvim = 1

" SubvimRoot() returns the working copy root for the given path (default: the
" current buffer, or the current directory for special buffers), or an empty
" string when not inside a Subversion working copy.
function! SubvimRoot(...) abort
  return call('subvim#Root', a:000)
endfunction

command! -bang -nargs=* -complete=customlist,subvim#Complete Svn
      \ exe subvim#Command(<q-args>, <bang>0, <q-mods>)

augroup subvim
  autocmd!
  autocmd BufWritePost * call subvim#ReloadStatus()
  autocmd FocusGained  * call subvim#ReloadStatus()
augroup END
