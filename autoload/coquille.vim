let s:current_dir=expand("<sfile>:p:h")
let g:counter=0

if !exists('coquille_auto_move')
    let g:coquille_auto_move="false"
endif

" Load vimbufsync if not already done
call vimbufsync#init()

py import sys, vim
py if not vim.eval("s:current_dir") in sys.path:
\    sys.path.append(vim.eval("s:current_dir"))
py import coquille

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
        py coquille.kill_coqtop()

        setlocal ei=InsertEnter,BufEnter,BufLeave
    endif
endfunction

function! coquille#RawQuery(...)
    py coquille.coq_raw_query(*vim.eval("a:000"))
endfunction

function! coquille#FNMapping()
    "" --- Function keys bindings
    "" Works under all tested config.
    map <buffer> <silent> <F2> :CoqUndo<CR>
    map <buffer> <silent> <F3> :CoqNext<CR>
    map <buffer> <silent> <F4> :CoqToCursor<CR>

    imap <buffer> <silent> <F2> <C-\><C-o>:CoqUndo<CR>
    imap <buffer> <silent> <F3> <C-\><C-o>:CoqNext<CR>
    imap <buffer> <silent> <F4> <C-\><C-o>:CoqToCursor<CR>
endfunction

function! coquille#CoqideMapping()
    "" ---  CoqIde key bindings
    "" Unreliable: doesn't work with all terminals, doesn't work through tmux,
    ""  etc.
    map <buffer> <silent> <C-A-Up>    :CoqUndo<CR>
    map <buffer> <silent> <C-A-Left>  :CoqToCursor<CR>
    map <buffer> <silent> <C-A-Down>  :CoqNext<CR>
    map <buffer> <silent> <C-A-Right> :CoqToCursor<CR>

    imap <buffer> <silent> <C-A-Up>    <C-\><C-o>:CoqUndo<CR>
    imap <buffer> <silent> <C-A-Left>  <C-\><C-o>:CoqToCursor<CR>
    imap <buffer> <silent> <C-A-Down>  <C-\><C-o>:CoqNext<CR>
    imap <buffer> <silent> <C-A-Right> <C-\><C-o>:CoqToCursor<CR>
endfunction

function! coquille#LeaderMapping()
    map <buffer> <silent> <leader>cc :CoqLaunch<CR>
    map <buffer> <silent> <leader>cq :CoqKill<CR>

    map <buffer> <silent> <leader>cj :CoqNext<CR>
    map <buffer> <silent> <leader>ck :CoqUndo<CR>
    map <buffer> <silent> <leader>cl :CoqToCursor<CR>

    imap <buffer> <silent> <leader>cj <C-\><C-o>:CoqNext<CR>
    imap <buffer> <silent> <leader>ck <C-\><C-o>:CoqUndo<CR>
    imap <buffer> <silent> <leader>cl <C-\><C-o>:CoqToCursor<CR>

    map <buffer> <silent> <leader>c1 :Coq SearchAbout <C-r>=expand("<cword>")<CR>.<CR>
    map <buffer> <silent> <leader>c2 :Coq Check <C-r>=expand("<cword>")<CR>.<CR>
    map <buffer> <silent> <leader>c3 :Coq About <C-r>=expand("<cword>")<CR>.<CR>
    map <buffer> <silent> <leader>c4 :Coq Print <C-r>=expand("<cword>")<CR>.<CR>
    map <buffer> <silent> <leader>c5 :Coq About <C-r>=expand("<cword>")<CR>.<CR>
    map <buffer> <silent> <leader>c6 :Coq Locate <C-r>=expand("<cword>")<CR>.<CR>
endfunction

function! coquille#Launch(...)
    if b:coq_running == 1
        echo "Coq is already running"
    else
        let b:coq_running = 1

        if exists('g:coquille_args')
            let extra_args = split(g:coquille_args)
        else
            let extra_args = []
        endif

        " initialize the plugin (launch coqtop)
        py coquille.launch_coq(*vim.eval("map(copy(extra_args+a:000),'expand(v:val)')"))

        " make the different commands accessible
        command! -buffer GotoDot py coquille.goto_last_sent_dot()
        command! -buffer CoqNext py coquille.coq_next()
        command! -buffer CoqUndo py coquille.coq_rewind()
        command! -buffer CoqToCursor py coquille.coq_to_cursor()
        command! -buffer CoqKill call coquille#KillSession()

        command! -buffer -nargs=* Coq call coquille#RawQuery(<f-args>)

        call coquille#ShowPanels()

        " Automatically sync the buffer when entering insert mode: this is usefull
        " when we edit the portion of the buffer which has already been sent to coq,
        " we can then rewind to the appropriate point.
        " It's still incomplete though, the plugin won't sync when you undo or
        " delete some part of your buffer. So the highlighting will be wrong, but
        " nothing really problematic will happen, as sync will be called the next
        " time you explicitly call a command (be it 'rewind' or 'interp')
        au InsertEnter <buffer> py coquille.sync()
        au BufLeave <buffer> py coquille.hide_color()
        au BufEnter <buffer> py coquille.reset_color(); coquille.remem_goal()
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
    else
        let l:winnb = winnr()
        only
        if exists('b:goal_buf')
            let l:goal_buf = b:goal_buf
            let l:info_buf = b:info_buf
            execute 'rightbelow vertical sbuffer ' . l:goal_buf
            execute 'rightbelow sbuffer ' . l:info_buf
            execute l:winnb . 'wincmd w'
        endif
    endif

    command! -bar -buffer -nargs=* -complete=file CoqLaunch call coquille#Launch(<f-args>)
endfunction
