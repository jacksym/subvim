if exists("b:current_syntax")
  finish
endif

syn sync fromstart
syn spell notoplevel

syn match subvimHeader /^[A-Z][a-z][^:]*:/
syn match subvimHeader /^Revision:/ nextgroup=subvimRevision skipwhite
syn match subvimHelpHeader /^Help:/ nextgroup=subvimHelpTag skipwhite
syn match subvimHelpTag    /\S\+/ contained
syn match subvimRevision   /r\d\+/ contained

syn region subvimSection start=/^\%(.*(\d\+)$\)\@=/ contains=subvimHeading end=/^$/ fold
syn match subvimHeading /^[A-Z][a-z][^:]*\ze (\d\+)$/ contained nextgroup=subvimCount skipwhite
syn match subvimCount /(\d\+)/hs=s+1,he=e-1 contained

for s:section in ['Unversioned', 'Missing', 'Changes']
  exe 'syn region subvim' . s:section . 'Section start=/^\%(' . s:section . ' (\d\+)$\)\@=/ contains=subvim' . s:section . 'Heading end=/^$/ fold'
  exe 'syn match subvim' . s:section . 'Modifier /^[MADRC?!~] / contained containedin=subvim' . s:section . 'Section'
  exe 'syn match subvim' . s:section . 'Heading /^[A-Z][a-z][^:]*\ze (\d\+)$/ contained nextgroup=subvimCount skipwhite'
endfor
unlet s:section

" Mirror fugitive's highlight choices: Unversioned ~ Untracked,
" Missing ~ Unstaged, Changes ~ Staged.
hi def link subvimHelpHeader subvimHeader
hi def link subvimHeader Label
hi def link subvimHelpTag Tag
hi def link subvimRevision Identifier
hi def link subvimHeading PreProc
hi def link subvimUnversionedHeading PreCondit
hi def link subvimMissingHeading Macro
hi def link subvimChangesHeading Include
hi def link subvimUnversionedModifier StorageClass
hi def link subvimMissingModifier Structure
hi def link subvimChangesModifier Typedef
hi def link subvimCount Number

let b:current_syntax = "subvim"
