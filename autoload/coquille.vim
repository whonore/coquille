" Only source once
if exists('g:coquille_sourced')
    finish
endif
let g:coquille_sourced = 1

" TODO: add support for py3
if g:pyv != 2
    echo "Coquille requires python2 support"
    finish
endif

" TODO: should be s: variable, but since Py command is in .vimrc it doesn't see it
let g:coquille#current_dir = expand("<sfile>:p:h")
let g:counter = 0
let g:proj_file = '_CoqProject'

if !exists('coquille_auto_move')
    let g:coquille_auto_move="false"
endif

" Load vimbufsync if not already done
call vimbufsync#init()

Py import sys, vim
Py if not vim.eval("g:coquille#current_dir") in sys.path:
\    sys.path.append(vim.eval("g:coquille#current_dir"))
Py import coquille

function! coquille#ShowPanels()
    " open the Goals & Infos panels before going back to the main window
    let l:winnb = winnr()
    execute 'rightbelow vnew Goals' . g:counter
        setlocal buftype=nofile
        setlocal filetype=coq-goals
        setlocal noswapfile
        let l:goal_buf = bufnr("%")
    execute 'rightbelow new Infos' . g:counter
        setlocal buftype=nofile
        setlocal filetype=coq-infos
        setlocal noswapfile
        let l:info_buf = bufnr("%")
    execute l:winnb . 'winc w'
    let b:goal_buf = l:goal_buf
    let b:info_buf = l:info_buf
    let g:counter += 1
endfunction

function! coquille#KillSession()
    if b:coq_running == 1
        let b:coq_running = 0

        execute 'bdelete' . b:goal_buf
        execute 'bdelete' . b:info_buf
        Py coquille.kill_coqtop()

        au! coquille#Main * <buffer>

        unlet b:goal_buf b:info_buf
    endif
endfunction

function! coquille#RawQuery(...)
    Py coquille.coq_raw_query(*vim.eval("a:000"))
endfunction

function! coquille#GetCurWord()
    setlocal iskeyword+=.
    let l:cword = expand("<cword>")
    if l:cword =~ ".*[.]$"
       let l:cword = l:cword[:-2]
    endif
    setlocal iskeyword-=.

    return l:cword
endfunction

function! coquille#QueryMapping()
    map <silent> <leader>cs :Coq SearchAbout <C-r>=expand(coquille#GetCurWord())<CR>.<CR>
    map <silent> <leader>ch :Coq Check <C-r>=expand(coquille#GetCurWord())<CR>.<CR>
    map <silent> <leader>ca :Coq About <C-r>=expand(coquille#GetCurWord())<CR>.<CR>
    map <silent> <leader>cp :Coq Print <C-r>=expand(coquille#GetCurWord())<CR>.<CR>
    map <silent> <leader>cf :Coq Locate <C-r>=expand(coquille#GetCurWord())<CR>.<CR>

    map <silent> <leader>co :CoqGoTo <C-r>=expand(coquille#GetCurWord())<CR><CR>
endfunction

function! coquille#LeaderMapping()
    map <silent> <leader>cc :CoqLaunch<CR>
    map <silent> <leader>cq :CoqKill<CR>

    map <silent> <leader>cj :CoqNext<CR>
    map <silent> <leader>ck :CoqUndo<CR>
    map <silent> <leader>cl :CoqToCursor<CR>

    imap <silent> <leader>cj <C-\><C-o>:CoqNext<CR>
    imap <silent> <leader>ck <C-\><C-o>:CoqUndo<CR>
    imap <silent> <leader>cl <C-\><C-o>:CoqToCursor<CR>

    map <silent> <leader>cG :GotoDot<CR>

    call coquille#QueryMapping()
endfunction

function! coquille#RestorePanels()
    let l:winnb = winnr()
    let l:goal_buf = b:goal_buf
    let l:info_buf = b:info_buf
    execute 'rightbelow vertical sbuffer ' . l:goal_buf
    execute 'rightbelow sbuffer ' . l:info_buf
    execute l:winnb . 'wincmd w'
endfunction

function! coquille#Launch(...)
    if b:coq_running == 1
        echo "Coq is already running"
    else
        let b:coq_running = 1

        if filereadable(g:proj_file)
            let l:proj_args = split(join(readfile(g:proj_file)))
        else
            let l:proj_args = []
        endif

        if exists('g:coquille_args')
            let l:coq_args = split(g:coquille_args)
        else
            let l:coq_args = []
        endif

        let l:extra_args = l:proj_args + l:coq_args

        " initialize the plugin (launch coqtop)
        Py coquille.launch_coq(*vim.eval("map(copy(l:extra_args+a:000),'expand(v:val)')"))

        " make the different commands accessible
        command! -buffer GotoDot Py coquille.goto_last_sent_dot()
        command! -buffer CoqNext Py coquille.coq_next()
        command! -buffer CoqUndo Py coquille.coq_rewind()
        command! -buffer CoqToCursor Py coquille.coq_to_cursor()
        command! -buffer CoqKill call coquille#KillSession()

        command! -buffer -nargs=* Coq call coquille#RawQuery(<f-args>)

        command! -buffer -nargs=1 CoqGoTo Py coquille.coq_goto(<f-args>)

        call coquille#ShowPanels()

        " Automatically sync the buffer when entering insert mode: this is usefull
        " when we edit the portion of the buffer which has already been sent to coq,
        " we can then rewind to the appropriate point.
        " It's still incomplete though, the plugin won't sync when you undo or
        " delete some part of your buffer. So the highlighting will be wrong, but
        " nothing really problematic will happen, as sync will be called the next
        " time you explicitly call a command (be it 'rewind' or 'interp')
        " TODO: fix switching args while in info or goal buffer
        augroup coquille#Main
            au InsertEnter <buffer> Py coquille.sync()
            au BufWinLeave <buffer> only
            au BufWinLeave <buffer> Py coquille.hide_color()
            au BufWinEnter <buffer> call coquille#RestorePanels()
            au BufWinEnter <buffer> Py coquille.reset_color(); coquille.remem_goal()
        augroup end
    endif
endfunction"

function! coquille#Register()
    hi default CheckedByCoq ctermbg=17 guibg=LightGreen
    hi default SentToCoq ctermbg=60 guibg=LimeGreen
    hi link CoqError Error

    if !exists('b:coq_running')
        let b:coq_running = 0
        let b:checked = -1
        let b:sent    = -1
        let b:errors  = -1
    endif

    command! -bar -buffer -nargs=* -complete=file CoqLaunch call coquille#Launch(<f-args>)
endfunction
