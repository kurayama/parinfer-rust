if !exists('g:parinfer_mode')
  let g:parinfer_mode = "smart"
endif
if !exists('g:parinfer_enabled')
  let g:parinfer_enabled = 1
endif
if !exists('g:parinfer_force_balance')
  let g:parinfer_force_balance = 0
endif

if !exists('g:parinfer_dylib_path')
  if has('macunix')
    let g:parinfer_dylib_path = expand('<sfile>:p:h:h'). '/target/release/libparinfer_rust.dylib'
  elseif has('unix')
    let s:uname = system("uname")
    if s:uname == "Darwin\n"
      let g:parinfer_dylib_path = expand('<sfile>:p:h:h'). '/target/release/libparinfer_rust.dylib'
    else
      let g:parinfer_dylib_path = expand('<sfile>:p:h:h'). '/target/release/libparinfer_rust.so'
    endif
  elseif has('win32')
    let g:parinfer_dylib_path = expand('<sfile>:p:h:h'). '/target/release/parinfer_rust.dll'
  else
    " I hope we don't come here!
  endif
endif

command! ParinferOn let g:parinfer_enabled = 1
command! ParinferOff let g:parinfer_enabled = 0

" Logging {{{1

function! s:parinfer_log(...)
  if a:0 > 0
    let g:parinfer_logfile = a:1
    echomsg 'Parinfer is now logging to '.a:1
  else
    unlet g:parinfer_logfile
    echomsg 'Parinfer is no longer logging'
  endif
endfunction

function! s:log(tag, data) abort
  if exists('g:parinfer_logfile')
    call writefile([printf('%20s: %s', a:tag, json_encode(a:data))], g:parinfer_logfile, 'a')
  endif
endfunction

function! s:log_diff(from, to) abort
  if exists('g:parinfer_logfile')
    let l:from_lines = split(a:from, "\n")
    let l:to_lines = split(a:to, "\n")

    " Compute the edit distance
    let l:table = map(range(0, len(l:from_lines)), 'repeat([19999], 1+len(l:to_lines))')
    for i in range(0, len(l:from_lines)) | let l:table[i][0] = i | endfor
    for j in range(0, len(l:to_lines)) | let l:table[0][j] = j | endfor
    for i in range(1, len(l:from_lines))
      for j in range(1, len(l:to_lines))
        let l:table[i][j] = min([ 1 + l:table[i-1][j], 1 + l:table[i][j-1] ])
        if l:from_lines[i-1] ==# l:to_lines[j-1]
          let l:table[i][j] = min([ l:table[i][j], 0 + l:table[i-1][j-1] ])
        endif
      endfor
    endfor

    " Construct a diff
    let l:i = len(l:from_lines)
    let l:j = len(l:to_lines)
    let l:diff = []
    while l:i > 0 || l:j > 0
      if l:i > 0 && l:j > 0 && l:table[i-1][j-1] == l:table[i][j] && l:from_lines[i-1] ==# l:to_lines[j-1]
        let l:diff += ['     ' . l:from_lines[i-1]]
        let l:i -= 1
        let l:j -= 1
      elseif l:j > 0 && 1+l:table[i][j-1] == l:table[i][j]
        let l:diff += ['    +' . l:to_lines[j-1]]
        let l:j -= 1
      elseif l:i > 0 && 1+l:table[i-1][j] == l:table[i][j]
        let l:diff += ['    -' . l:from_lines[i-1]]
        let l:i -= 1
      else
        throw 'bad case ' . l:i . ',' . l:j
      endif
    endwhile

    call writefile(reverse(l:diff), g:parinfer_logfile, 'a')
  endif
endfunction

command! -nargs=? ParinferLog call <SID>parinfer_log(<f-args>)

" }}}

function! s:enter_window()
  let w:parinfer_previous_cursor = [line('.'), virtcol('.')]
endfunction

function! s:enter_buffer()
  call s:enter_window()
  if !exists('b:parinfer_last_changedtick')
    let b:parinfer_last_changedtick = -10
    let b:parinfer_previous_text = join(getline(1,line('$')),"\n")
  endif
  let orig_mode = g:parinfer_mode
  let g:parinfer_mode = 'paren'
  call s:process_buffer()
  let g:parinfer_mode = orig_mode
endfunction

function! s:process_buffer() abort
  if !g:parinfer_enabled || &paste
    return
  endif
  if !exists('b:parinfer_last_changedtick')
    call s:enter_buffer()
  endif
  if b:parinfer_last_changedtick != b:changedtick
    let l:pos = getpos('.')
    let l:pos[2] = virtcol('.')
    let l:orig_lines = getline(1,line('$'))
    let l:orig_text = join(l:orig_lines, "\n")
    let l:request = { "mode": g:parinfer_mode,
                    \ "text": l:orig_text,
                    \ "options": { "cursorX": l:pos[2] - 1,
                                 \ "cursorLine": l:pos[1] - 1,
                                 \ "forceBalance": g:parinfer_force_balance ? v:true : v:false,
                                 \ "prevCursorX": w:parinfer_previous_cursor[1] - 1,
                                 \ "prevCursorLine": w:parinfer_previous_cursor[0] - 1,
                                 \ "prevText": b:parinfer_previous_text } }
    let l:response = json_decode(libcall(g:parinfer_dylib_path, "run_parinfer", json_encode(l:request)))
    if l:response["success"]
      if l:response["text"] !=# l:orig_text
        call s:log('change-request', l:request)
        call s:log('change-response', l:response)
        call s:log_diff(l:orig_text, l:response['text'])
        let l:lines = split(l:response["text"], "\n", 1)
        let l:changed = filter(range(len(l:lines)), 'l:lines[v:val] !=# l:orig_lines[v:val]')
        silent! undojoin
        try
          call setline(l:changed[0]+1, l:lines[l:changed[0]:l:changed[-1]])
        catch /E523:/ " not allowed here
          " If an event doesn't allow us to modify the buffer, that's OK.
          " Usually another event will happen before a redraw.
          call s:log('not-allowed-here', {})
        endtry
      endif
      let l:pos[1] = l:response["cursorLine"] + 1
      let l:pos[2] = strlen(strcharpart(getline(l:pos[1]), 0, l:response["cursorX"])) + 1
      call setpos('.', l:pos)

      let b:parinfer_previous_text = l:response["text"]
    else
      call s:log('error-response', l:response)
      let g:parinfer_last_error = l:response["error"]
      let b:parinfer_previous_text = join(getline(1,line('$')),"\n")
    endif
    let b:parinfer_last_changedtick = b:changedtick
  endif
  let w:parinfer_previous_cursor = [line('.'), virtcol('.')]
endfunction

let s:EVENTS = {
  \ 'BufEnter': function('<SID>enter_buffer'),
  \ 'CursorMoved': function('<SID>process_buffer'),
  \ 'InsertCharPre': function('<SID>process_buffer'),
  \ 'InsertEnter': function('<SID>process_buffer'),
  \ 'TextChanged': function('<SID>process_buffer'),
  \ 'TextChangedI': function('<SID>process_buffer'),
  \ 'TextChangedP': function('<SID>process_buffer'),
  \ 'WinEnter': function('<SID>enter_window') }

function! s:event(name)
  call s:log('event', {'name': a:name, 'bufnr': bufnr('%'), 'changedtick': b:changedtick })
  call call(s:EVENTS[a:name], [])
endfunction

function! s:initialize_buffer() abort
  " We can't get the buffer in the command-line window, so don't initialize
  " it.  This happens with vim-fireplace's `cqq`.
  if getcmdwintype() !=# ''
    return
  endif
  
  " Don't enable if preview window
  if &previewwindow
    return
  endif

  for event_name in filter(keys(s:EVENTS),'exists("##".v:val)')
    execute "autocmd! Parinfer ".event_name." <buffer> call <SID>event('".event_name."')"
  endfor
endfunction

augroup Parinfer
  autocmd FileType clojure,scheme,lisp,racket,hy call <SID>initialize_buffer()
augroup END

" vim:set sts=2 sw=2 ai et foldmethod=marker:
