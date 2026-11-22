" subvim.vim - A Subversion wrapper in the spirit of fugitive.vim
" Version:      0.2

if exists('g:loaded_subvim')
  finish
endif
let g:loaded_subvim = 1

" SubvimRoot() returns the working copy root for the given path (default: the
" current buffer), or an empty string when not inside a working copy.
function! SubvimRoot(...) abort
  return call('subvim#Root', a:000)
endfunction

" SubvimReal() takes a subvim:// URL and returns the corresponding path in the
" working copy.  Other paths are returned unchanged.
function! SubvimReal(...) abort
  return call('subvim#Real', a:0 ? a:000 : [@%])
endfunction

" SubvimStatusline() returns e.g. [Svn(trunk)] for use in 'statusline'.
function! SubvimStatusline(...) abort
  if empty(subvim#Root())
    return ''
  endif
  return subvim#Statusline()
endfunction

command! -bang -nargs=* -range=-1 -addr=other -complete=customlist,subvim#Complete Svn
      \ exe subvim#Command(<line1>, <count>, <q-args>, <bang>0, <q-mods>)

command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Sedit
      \ exe subvim#Open('edit<bang>', <q-args>, <q-mods>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Ssplit
      \ exe subvim#Open('split', <q-args>, <q-mods>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Svsplit
      \ exe subvim#Open('vsplit', <q-args>, <q-mods>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Stabedit
      \ exe subvim#Open('tabedit', <q-args>, <q-mods>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Spedit
      \ exe subvim#Open('pedit', <q-args>, <q-mods>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Sdrop
      \ exe subvim#Open('drop', <q-args>, <q-mods>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Sread
      \ exe subvim#Read(<q-args>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Swrite
      \ exe subvim#Write(<q-args>, <bang>0)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Swq
      \ exe subvim#Write(<q-args>, <bang>0) . '|quit<bang>'
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Sdiffsplit
      \ exe subvim#Diffsplit(1, <bang>0, <q-mods>, <q-args>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Svdiffsplit
      \ exe subvim#Diffsplit(0, <bang>0, 'vertical <mods>', <q-args>)
command! -bar -bang -nargs=* -complete=customlist,subvim#ObjectComplete Shdiffsplit
      \ exe subvim#Diffsplit(0, <bang>0, '<mods>', <q-args>)
command! -bar -bang -nargs=1 -complete=customlist,subvim#ObjectComplete SMove
      \ exe subvim#Move(<q-args>, <bang>0, 0)
command! -bar -bang -nargs=1 -complete=customlist,subvim#RenameComplete SRename
      \ exe subvim#Move(<q-args>, <bang>0, 1)
command! -bar -bang SDelete exe subvim#Delete('delete', <bang>0)
command! -bar -bang SRemove exe subvim#Delete('remove', <bang>0)
command! -bar -bang SUnlink exe subvim#Delete('unlink', <bang>0)
command! -bar -bang -range -nargs=* -complete=customlist,subvim#ObjectComplete SBrowse
      \ exe subvim#Browse(<bang>0, <line1>, <line2>, <range>, <q-args>)
command! -bang -nargs=+ -complete=file Sgrep  exe subvim#Grep('c', <bang>0, <q-args>)
command! -bang -nargs=+ -complete=file Slgrep exe subvim#Grep('l', <bang>0, <q-args>)
command! -bang -nargs=* -range=-1 -addr=other -complete=customlist,subvim#ObjectComplete Sclog
      \ exe subvim#Log('c', <bang>0, <count>, <q-args>)
command! -bang -nargs=* -range=-1 -addr=other -complete=customlist,subvim#ObjectComplete Sllog
      \ exe subvim#Log('l', <bang>0, <count>, <q-args>)
command! -bar -nargs=? -complete=dir Scd  exe subvim#Cd('cd', <q-args>)
command! -bar -nargs=? -complete=dir Slcd exe subvim#Cd('lcd', <q-args>)

augroup subvim
  autocmd!
  autocmd BufReadCmd  subvim://* exe subvim#BufReadCmd(expand('<amatch>'))
  autocmd FileReadCmd subvim://* exe subvim#FileReadCmd(expand('<amatch>'))
  autocmd BufWritePost * call subvim#ReloadStatus()
  autocmd FocusGained  * call subvim#ReloadStatus()
  autocmd BufWinEnter  * call subvim#BufferMaps()
augroup END
