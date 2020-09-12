# This should be called once per session prior to any commands.
# 
function fishql-session -d "Start a fishql session"
    set -l hn (hostname)
    set -l hni (hostname -I)
    set -l ppid (ps -o ppid -p $fish_pid)[2]
    set -l tz (date +%Z)
    set -l sst (date +%s)
    set -l tty (tty)
    set -l rid (id -ur)
    set -l uid (id -u)
    set -l nid (id -un)

    echo "
    INSERT INTO
    sessions('hostname', 'host_ip', 'ppid', 'pid', 'time_zone', 'start_time', 'tty', 'uid', 'euid', 'logname', 'shell', 'sudo_user', 'sudo_uid', 'ssh_client', 'ssh_connection')
    VALUES('$hn', '$hni', '$ppid', '$fish_pid', '$tz', '$sst', '$tty', '$rid', '$uid', '$nid', '$SHELL', '', '', '$SSH_CLIENT', '$SSH_CONNECTION')
    " | fishql-query

    set -g _fishql_timeout 100
    set -g _fishql_session_tty (tty)
    set -g _fishql_session_euid (id -u)
    set -g _fishql_session_start (date +%s)
    set -g _fishql_command_id 0
    set -g _fishql_session_id (echo 'select seq from sqlite_sequence where name="sessions"'|fishql-query)

end
