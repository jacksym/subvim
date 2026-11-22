if exists("b:current_syntax")
  finish
endif

syn sync fromstart
syn spell notoplevel

syn include @subvimDiff syntax/diff.vim

syn match subvimHeader /^[A-Z][a-z][^:]*:/
syn match subvimHeader /^Head:/ nextgroup=subvimSymbolicRef skipwhite
syn match subvimHeader /^Revision:/ nextgroup=subvimRevision skipwhite
syn match subvimHelpHeader /^Help:/ nextgroup=subvimHelpTag skipwhite
syn match subvimHelpTag    /\S\+/ contained
syn match subvimSymbolicRef /\S\+/ contained
syn match subvimRevision   /\S\+/ contained

syn region subvimSection start=/^\%(.*(\d\+)$\)\@=/ contains=subvimHeading end=/^$/ fold
syn cluster subvimSection contains=subvimSection
syn match subvimHeading /^[A-Z][a-z][^:]*\ze (\d\+)$/ contained nextgroup=subvimCount skipwhite
syn match subvimCount /(\d\+)/hs=s+1,he=e-1 contained
syn match subvimModifier /^[MADRC?!~] / contained containedin=@subvimSection

syn region subvimHunk start=/^\%(@@\+ -\|Property changes on:\)\@=/ end=/^\%([A-Za-z?!~@]\|$\)\@=/ contains=diffLine,diffRemoved,diffAdded,diffNoEOL containedin=@subvimSection fold

" Unversioned ~ fugitive's Untracked.
for s:section in ['Unversioned', 'Unstaged', 'Staged']
  exe 'syn region subvim' . s:section . 'Section start=/^\%(' . s:section . ' (\d\+)$\)\@=/ contains=subvim' . s:section . 'Heading end=/^$/ fold'
  exe 'syn match subvim' . s:section . 'Modifier /^[MADRC?!~] / contained containedin=subvim' . s:section . 'Section'
  exe 'syn cluster subvimSection add=subvim' . s:section . 'Section'
  exe 'syn match subvim' . s:section . 'Heading /^[A-Z][a-z][^:]*\ze (\d\+)$/ contained nextgroup=subvimCount skipwhite'
endfor
unlet s:section

hi def link subvimHelpHeader subvimHeader
hi def link subvimHeader Label
hi def link subvimHelpTag Tag
hi def link subvimSymbolicRef Function
hi def link subvimRevision Identifier
hi def link subvimHeading PreProc
hi def link subvimUnversionedHeading PreCondit
hi def link subvimUnstagedHeading Macro
hi def link subvimStagedHeading Include
hi def link subvimModifier Type
hi def link subvimUnversionedModifier StorageClass
hi def link subvimUnstagedModifier Structure
hi def link subvimStagedModifier Typedef
hi def link subvimCount Number

let b:current_syntax = "subvim"
