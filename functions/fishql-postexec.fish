function fishql-postexec --on-event fish_postexec -d "Store final info about a command"
    set -l ec $status
    if test -z "$argv"
        return
    end
    if not test -s $fishql_dbfile
        echo "fishql: remaking lost DB file $fishql_dbfile"
        fishql-initdb
    end


    set -l cmd (echo $argv | sed -e "s/'/''/g")
    set -l et (date +%s)
    set -l dt (math $CMD_DURATION / 1000.0)

    # echo "========="
    # echo $cmd
    # echo "========="

    echo "
.timeout $_fishql_timeout
INSERT INTO 
commands('session_id', 'shell_level', 'command_no', 'tty', 'euid', 'cwd', 'rval', 'start_time', 'end_time', 'duration', 'pipe_cnt', 'pipe_vals', 'command')
VALUES('$_fishql_session_id', '$SHLVL', '$_fishql_command_id', '$_fishql_session_tty', '$_fishql_session_euid', '$_fishql_command_cwd', '$ec', '$_fishql_command_start', '$et', '$dt', '$pipestatus', '', '$cmd')
" | fishql-query
end

