" Test cases for subvim.  Each T_name function runs in a fresh working copy
" made by fixture.sh (cwd is the working copy).  Run with test/run.sh.

function! Setup() abort
  call writefile(['new'], 'new.txt') | call mkdir('nd') | call writefile(['y'], 'nd/y.txt')
  call delete('b.txt') | call writefile(['mod'], 'c.txt')
endfunction

function! T_status_sections() abort
  call Setup()
  Svn
  call assert_equal(['? nd', '? new.txt'], Section('Unversioned'))
  call assert_equal(['! b.txt', 'M c.txt'], Section('Unstaged'))
  call assert_equal([], Section('Staged'))
  call assert_match('^Head: trunk', getline(1))
endfunction

function! T_stage_unstage() abort
  call Setup()
  Svn
  call Go('^? new.txt') | exe "normal s"
  call Go('^? nd$') | exe "normal s"
  call Go('^! b.txt') | exe "normal s"
  call Go('^M c.txt') | exe "normal s"
  call assert_equal(sort(['D b.txt', 'M c.txt', 'A nd', 'A nd/y.txt', 'A new.txt']), sort(Section('Staged')))
  call assert_equal([], Section('Unversioned') + Section('Unstaged'))
  call assert_match("Changelist 'subvim-staged'", Svn('status'))
  call Go('^M c.txt') | exe "normal u"
  call assert_equal(['M c.txt'], Section('Unstaged'))
  call Go('^A new.txt') | exe "normal u"
  call assert_equal(['? new.txt'], Section('Unversioned'))
  call Go('^D b.txt') | exe "normal u"
  call assert_equal(['! b.txt', 'M c.txt'], Section('Unstaged'))
  call Go('^A nd$') | exe "normal -"
  call assert_equal(['? nd', '? new.txt'], Section('Unversioned'))
  " heading stages the whole section
  call Go('^Unstaged') | exe "normal s"
  call assert_equal(['D b.txt', 'M c.txt'], Section('Staged'))
  normal U
  call assert_equal([], Section('Staged'))
endfunction

function! T_commit_staged_only() abort
  call Setup()
  Svn
  call Go('^? nd$') | exe "normal s"
  call Go('^M c.txt') | exe "normal s"
  normal cc
  call assert_equal('svn', &filetype)
  call assert_true(search('^A    nd/y.txt', 'nw') > 0)
  call assert_true(search('^Changes not staged', 'nw') > 0)
  call setline(1, 'Commit nd and c')
  wq
  sleep 300m
  let log = Svn('log -v -l1 ^/')
  call assert_match('Commit nd and c', log)
  call assert_match('A /trunk/nd/y.txt', log)
  call assert_match('M /trunk/c.txt', log)
  call assert_notmatch('b.txt', log)
  call assert_equal(['! b.txt'], Section('Unstaged'))
  call assert_equal(['? new.txt'], Section('Unversioned'))
endfunction

function! T_commit_nothing_staged() abort
  Svn
  let msgs = execute('normal cc')
  call assert_match('no changes added to commit', msgs)
  call assert_equal(2, winnr('$'))
endfunction

function! T_discard() abort
  call Setup()
  Svn
  call Go('^? new.txt') | exe "normal X"
  call assert_false(filereadable('new.txt'))
  call assert_equal(1, len(glob('.svn/subvim/trash/*/new.txt', 1, 1)))
  call Go('^! b.txt') | exe "normal X"
  call assert_true(filereadable('b.txt'))
  call assert_equal(['M c.txt'], Section('Unstaged'))
endfunction

function! T_inline_diff_and_hunk_discard() abort
  call writefile(['l1', 'l2', 'CHANGED3', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9', 'TEN'], 'a.txt')
  Svn
  call Go('^M a.txt') | exe "normal ="
  call assert_true(search('^+TEN', 'nw') > 0)
  call assert_true(search('^-l10', 'nw') > 0)
  call Go('^-l10') | exe "normal X"
  call assert_equal('l10', readfile('a.txt')[-1])
  call assert_equal([], Section('Unstaged'))
endfunction

function! T_stash_roundtrip() abort
  call writefile(['stashed'], 'c.txt') | call writefile(['u'], 'u.txt')
  call writefile(['staged-b'], 'b.txt')
  Svn
  call Go('^M b.txt') | exe "normal s"
  exe "normal 1czz"
  call assert_equal('', Svn('status'))
  call assert_false(filereadable('u.txt'))
  call assert_true(search('^Stashes: 1', 'nw') > 0)
  normal czp
  call assert_equal(['stashed'], readfile('c.txt'))
  call assert_equal(['u'], readfile('u.txt'))
  call assert_equal(['M b.txt'], Section('Staged'))
  call assert_equal(['A u.txt', 'M c.txt'], sort(Section('Unstaged')))
  call assert_equal(0, search('^Stashes:', 'nw'))
  call Svn('revert -R . && svn changelist --remove -R . && rm -f u.txt')
endfunction

function! T_objects() abort
  call writefile(['x', 'y'], 'b.txt')
  edit b.txt
  Sedit %@BASE
  call assert_match('^subvim://.*//BASE/b.txt$', bufname(''))
  call assert_equal(['b'], getline(1, '$'))
  call assert_equal(0, &modifiable)
  Sedit
  call assert_equal('b.txt', expand('%'))
  Sedit a.txt@2
  call assert_equal('l3', getline(3))
  normal ~
  call assert_match('//\d\+/a.txt$', bufname(''))
  edit b.txt
  Sdiffsplit
  call assert_equal(2, winnr('$'))
  call assert_true(&diff)
  call assert_match('BASE/b.txt', bufname(''))
  only
  edit b.txt
  Sread
  call assert_equal(['b'], getline(1, '$'))
  call setline(1, 'written')
  Swrite
  call assert_match("Changelist 'subvim-staged'", Svn('status'))
  call Svn('revert b.txt && svn changelist --remove b.txt')
  edit! b.txt
endfunction

function! T_revision_and_log() abort
  Sclog
  let qf = getqflist()
  call assert_true(len(qf) >= 3)
  call assert_match('^r\d\+$', qf[0].module)
  call assert_match('^subvim://.*//\d\+$', bufname(''))
  call assert_true(search('^r\d\+ | ', 'nw') > 0)
  0Sclog
  " :0Sclog needs a file; run on a.txt
  edit a.txt
  0Sclog
  let qf = getqflist()
  call assert_equal(2, len(qf))
  call assert_match('^r\d\+:a.txt$', qf[0].module)
  exe 'Sedit @' . matchstr(qf[0].module, '\d\+')
  call Go('^   M /trunk/a.txt')
  exe "normal \<CR>"
  call assert_match('//\d\+/a.txt$', bufname(''))
  call assert_equal('CHANGED3', getline(3))
  Svn log -l 2
  call assert_equal('subvimlog', &filetype)
endfunction

function! T_blame() abort
  call writefile(['l1', 'l2', 'CHANGED3', 'NEW', 'l4', 'l5', 'l6', 'l7', 'l8', 'l9', 'l10'], 'a.txt')
  edit! a.txt
  Svn blame
  call assert_equal('subvimblame', &filetype)
  call assert_equal(11, line('$'))
  call assert_match('^r3 ', getline(3))
  call assert_match('Not Committed Yet', getline(4))
  call assert_match('^r2 ', getline(5))
  call cursor(3, 1)
  exe "normal \<CR>"
  call assert_match('//3$', bufname(''))
  call Svn('revert a.txt')
endfunction

function! T_move_delete() abort
  edit c.txt
  SMove c2.txt
  call assert_equal('c2.txt', expand('%'))
  let st = Svn('status')
  call assert_match('D       c.txt', st)
  call assert_match('A  +    c2.txt', st)
  call assert_match("Changelist 'subvim-staged'", st)
  SDelete!
  call assert_false(filereadable('c2.txt'))
  call Svn('revert -R . && svn changelist --remove -R . && rm -f c2.txt')
endfunction

function! T_ignore() abort
  call writefile(['o'], 'junk.tmpx')
  Svn
  call Go('^? junk.tmpx') | exe "normal gI"
  call assert_match('subvimprop://', bufname(''))
  call assert_equal('junk.tmpx', getline('.'))
  call setline('.', '*.tmpx')
  write
  call assert_equal("*.tmpx", trim(Svn('propget svn:ignore .')))
  wincmd p
  call assert_equal([], Section('Unversioned'))
  call assert_equal(['M .'], Section('Unstaged'))
  call Svn('revert . && rm -f junk.tmpx')
endfunction

function! T_branches() abort
  Svn branch feature
  call assert_match('feature/', Svn('ls ^/branches'))
  let out = execute('Svn branch')
  call assert_match('\* trunk', out)
  call assert_match('  feature', out)
  Svn switch feature
  call assert_match('\^/branches/feature', Svn('info --show-item relative-url'))
  call assert_equal('[Svn(feature)]', SubvimStatusline())
  Svn switch trunk
  call assert_equal('[Svn(trunk)]', SubvimStatusline())
endfunction

function! T_revert_rev() abort
  Svn
  edit a.txt
  Sedit @3
  normal crn
  call assert_equal('l3', readfile('a.txt')[2])
  Svn
  call assert_equal(['M a.txt'], Section('Staged'))
  call Svn('revert -R . && svn changelist --remove -R .')
endfunction

function! T_grep() abort
  Sgrep! CHANGED3
  let qf = getqflist()
  call assert_equal(1, len(qf))
  call assert_equal('a.txt', fnamemodify(bufname(qf[0].bufnr), ':.'))
endfunction


function! T_commit_dir_delete() abort
  call Svn('delete d')
  Svn
  call assert_equal(['D d'], Section('Unstaged'))
  call Go('^D d$') | exe "normal s"
  call assert_equal(['D d'], Section('Staged'))
  Svn commit -m "remove d"
  call assert_match('D /trunk/d\n', Svn('log -v -l1 ^/'))
  call assert_equal('', Svn('status'))
endfunction

function! T_commit_all_and_verbose() abort
  call writefile(['zz'], 'b.txt') | call writefile(['yy'], 'c.txt')
  Svn
  call Go('^M b.txt') | exe "normal s"
  normal cvc
  call assert_true(search('^+zz', 'nw') > 0)
  call assert_equal(0, search('^+yy', 'nw'))
  q!
  sleep 200m
  Svn commit -a -m "everything"
  call assert_equal('', Svn('status'))
endfunction

function! T_conflict() abort
  " make a conflicting change on the server through a second checkout
  call system('svn -q co ^/trunk ../wc2 2>&1')
  call writefile(['theirs'], '../wc2/b.txt')
  call system('cd ../wc2 && svn -q ci -m theirs')
  call writefile(['ours'], 'b.txt')
  Svn update
  Svn
  call assert_equal(['C b.txt'], Section('Unstaged'))
  only
  edit! b.txt
  Sdiffsplit
  call assert_equal(3, winnr('$'))
  call assert_true(maparg('d2o', 'n') =~# 'diffget')
  only
  call writefile(['merged'], 'b.txt')
  Svn
  call Go('^C b.txt') | exe "normal s"
  call assert_equal(['M b.txt'], Section('Staged'))
endfunction

function! T_stash_variants() abort
  call writefile(['staged'], 'b.txt') | call writefile(['unstaged'], 'c.txt')
  Svn
  call Go('^M b.txt') | exe "normal s"
  normal czw
  call assert_equal(['M b.txt'], Section('Staged'))
  call assert_equal([], Section('Unstaged'))
  normal czs
  call assert_equal('', Svn('status'))
  call assert_match('stash@{1}', execute('Svn stash list'))
  normal czA
  call assert_equal(['staged'], readfile('b.txt'))
  call assert_equal(['M b.txt'], Section('Unstaged'))
  Svn stash drop
  normal czP
  call assert_equal(['unstaged'], readfile('c.txt'))
  call assert_equal(0, search('^Stashes:', 'nw'))
endfunction

function! T_tag_browse_misc() abort
  Svn tag v1
  call assert_match('v1/', Svn('ls ^/tags'))
  edit a.txt
  SBrowse!
  call assert_match('^file://.*/repo/trunk/a.txt$', @")
  Sedit a.txt@2
  SBrowse!
  call assert_match('a.txt?p=2$', @")
  call assert_equal('[Svn:r2(trunk)]', SubvimStatusline())
  edit a.txt
  Svn blame
  call cursor(3, 1)
  normal -
  call assert_match('//3/a.txt$', bufname(winbufnr(2)))
  only
  Sedit @3
  normal coo
  call assert_match('^3', Svn('info --show-item revision'))
  Svn diff -r 2:3
  call assert_equal('diff', &filetype)
  call assert_true(search('^+CHANGED3', 'nw') > 0)
endfunction
function! T_smoke() abort
  call writefile(['zz'], 'b.txt') | call writefile(['n'], 'n.txt')
  let cmds = ['Svn', 'normal gu', 'normal gU', 'normal ]]', 'normal [[', 'normal )', 'normal (', 'normal i', 'normal i',
        \ 'normal J', 'normal K', 'normal >', 'normal <', 'normal dp', 'only', 'Svn', 'normal gi', 'only',
        \ 'Svn difftool', 'Svn mergetool', 'Svn info', 'Svn propedit svn:ignore .', 'only', 'Svn branch -d nosuch',
        \ 'Slgrep zz', 'Sllog -l 1', 'Scd', 'Slcd d', 'cd ' . g:wc, 'edit c.txt', 'SRename c3.txt', 'SRemove', 'Spedit a.txt@2',
        \ 'pclose', 'Sdrop a.txt', 'Sedit @2', 'normal ~', 'normal (', 'normal )', 'Svn log', 'normal o', 'only',
        \ 'Stabedit b.txt', 'tabonly', 'edit a.txt', 'read subvim://' . g:wc . '//2/a.txt', 'edit! a.txt',
        \ 'Svn stash list', 'Svn stash show', 'Svn status', 'normal gq', 'Svn', 'normal gs', 'normal p', 'pclose', 'Svn', 'normal gq',
        \ 'echo SubvimStatusline()', 'Svn -p info', 'Svn! status', 'Svn switch nosuch']
  for c in cmds
    let v:errmsg = ''
    try
      let out = execute(c)
      " Expected failures are reported as subvim: messages; raw Vim errors
      " (lines starting with E123:) are bugs.
      if out =~# '\%(^\|\n\)E\d\+:'
        call add(v:errors, c . ' => ' . substitute(out, "\n", ' | ', 'g'))
      endif
    catch
      call add(v:errors, c . ' => ' . v:exception)
    endtry
    if v:errmsg =~# '^E\d\+' && v:errmsg !~# 'subvim:'
      call add(v:errors, c . ' => ' . v:errmsg)
    endif
  endfor
endfunction

call Test($TEST, 'T_' . $TEST)
