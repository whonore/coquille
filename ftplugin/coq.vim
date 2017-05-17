"Check that coq version is not 8.4
if empty(system('coqtop --version | grep 8.4'))
    call coquille#Register()
endif
