if exists("b:current_syntax")
  finish
endif

syn match subvimblameRevision /^r\d\+/ nextgroup=subvimblameAuthor skipwhite
syn match subvimblameAuthor /\S\+/ contained nextgroup=subvimblameDate skipwhite
syn match subvimblameDate /\d\{4}-\d\d-\d\d/ contained
syn match subvimblameUncommitted /^\s\+Not Committed Yet$/

hi def link subvimblameRevision Identifier
hi def link subvimblameAuthor String
hi def link subvimblameDate PreProc
hi def link subvimblameUncommitted Comment

let b:current_syntax = "subvimblame"
