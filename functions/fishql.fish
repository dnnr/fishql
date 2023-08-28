# Entry function named after this file for autoloading
function fishql -a cmd -d "Call with 'init' to initialize fishql and start a new session"
    switch $cmd
        case "" -h --help
            echo "Usage: fishql init    Initialize fishql and start a new session"
        case init
            _fishql_init
        case \*
            echo "fishql: Unknown command: \"$cmd\"" >&2
            return 1
    end
end

function _fishql_init -d "Initialize fishql database and session"
    set -g fishql_dbfile $__fish_user_data_dir/fishql.db

    if not test -s "$fishql_dbfile"
        echo "
        CREATE TABLE sessions (
          id integer primary key autoincrement,
          hostname varchar(128),
          host_ip varchar(40),
          ppid int(5) not null,
          pid int(5) not null,
          time_zone str(3) not null,
          start_time integer not null,
          end_time integer,
          duration integer,
          tty varchar(20) not null,
          uid int(16) not null,
          euid int(16) not null,
          logname varchar(48),
          shell varchar(50) not null,
          sudo_user varchar(48),
          sudo_uid int(16),
          ssh_client varchar(60),
          ssh_connection varchar(100)
        );
        CREATE TABLE commands (
          id integer primary key autoincrement,
          session_id integer,
          shell_level integer,
          command_no integer,
          tty varchar(20),
          euid int(16),
          cwd varchar(256),
          rval int(5),
          start_time integer,
          end_time integer not null,
          duration integer,
          pipe_cnt int(3),
          pipe_vals varchar(80),
          command varchar(1000) not null,
          UNIQUE(session_id, command_no)
        );
        " | fishql-query
        chmod 600 $fishql_dbfile
    end

    _fishql_begin_session
end

function _fishql_begin_session -d "Start new fishql session"
    if not test -s "$fishql_dbfile"
        # This should never happen!
        echo "fishql: DB file missing, cannot begin new session" >&2
        return 1
    end

    set -l hn (hostname)
    set -l hni (_fishql_hni)
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
    set -g _fishql_session_id (echo "select seq from sqlite_sequence where name='sessions'"|fishql-query)
end

function _fishql_preexec --on-event fish_preexec
    if test -z "$argv"
        return
    end
    set -g _fishql_command_start (date +%s)
    set -g _fishql_command_cwd (pwd)
    set -g _fishql_command_id (math $_fishql_command_id + 1)
end

function _fishql_postexec --on-event fish_postexec -d "Store final info about a command"
    set -l ec $status

    if test -z "$argv"
        return
    end

    if not test -s "$fishql_dbfile"
        echo "WARNING: fishql DB file lost, initializing new DB"
        _fishql_init
    end

    set -l cmd (echo $argv | sed -e "s/'/''/g" | string trim)
    set -l et (date +%s)
    set -l dt (math $CMD_DURATION / 1000.0)

    echo ".timeout $_fishql_timeout
    INSERT INTO
        commands('session_id', 'shell_level', 'command_no', 'tty', 'euid', 'cwd', 'rval', 'start_time', 'end_time', 'duration', 'pipe_cnt', 'pipe_vals', 'command')
        VALUES('$_fishql_session_id', '$SHLVL', '$_fishql_command_id', '$_fishql_session_tty', '$_fishql_session_euid', '$_fishql_command_cwd', '$ec', '$_fishql_command_start', '$et', '$dt', '$pipestatus', '', '$cmd')
    " | fishql-query
end

function _fishql_hni -d 'Helper to determine current IP addresses'
    switch (uname)
        case Darwin
            # hostname -I doesn't work on MacOS and there's no simple substitute either
            echo ""
        case '*'
            hostname -I
    end
end
