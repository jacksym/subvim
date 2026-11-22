" Output of svn log, and revision buffers (log -v followed by the diff).
if exists("b:current_syntax")
  finish
endif

syn include @subvimDiff syntax/diff.vim
syn spell notoplevel

syn match subvimLogSeparator /^-\{72}$/
syn match subvimLogHeader /^r\d\+ | .*$/ contains=subvimLogRev,subvimLogAuthor,subvimLogDate
syn match subvimLogRev /^r\d\+/ contained
syn match subvimLogAuthor /^r\d\+ | \zs[^|]\{-}\ze |/ contained
syn match subvimLogDate /| \zs\d\{4}-\d\d-\d\d [^|]*\ze |/ contained
syn match subvimLogChanged /^Changed paths:$/
syn match subvimLogPath /^   [ADMR] .*$/ contains=subvimLogAction
syn match subvimLogAction /^   \zs[ADMR]/ contained

syn region subvimLogDiff start=/^Index: / end=/^\%(-\{72}$\)\@=/ contains=@subvimDiff,subvimLogIndex fold
syn match subvimLogIndex /^Index: .*$/ contained
syn match subvimLogIndex /^=\{67}$/ contained

hi def link subvimLogSeparator Comment
hi def link subvimLogRev Identifier
hi def link subvimLogAuthor String
hi def link subvimLogDate Number
hi def link subvimLogChanged Label
hi def link subvimLogAction Type
hi def link subvimLogIndex PreProc

let b:current_syntax = "subvimlog"
