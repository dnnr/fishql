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

    # Schema version this copy of fishql expects. Bump it and add a matching
    # step to _fishql_migrate whenever the schema changes.
    set -g _fishql_schema_target 1

    if not test -s "$fishql_dbfile"
        # A brand new DB gets the original (v0) schema and is then brought up to
        # date by the migration path in _fishql_begin_session, exactly like an
        # already existing one. Creating the *current* schema directly here
        # would let fresh and migrated databases drift apart.
        if _fishql_create_v0
            chmod 600 $fishql_dbfile
            # Suppresses the "upgrading" notice below: a new DB is empty, so
            # bringing it to the current version is instant and unremarkable.
            set -g _fishql_db_created 1
        end
    end

    _fishql_begin_session
end

function _fishql_create_v0 -d "Create the original fishql schema (schema version 0)"
    # Kept verbatim on purpose: this is the schema as it shipped before
    # versioning existed, so that migrating an old DB and creating a new one
    # arrive at exactly the same place. Don't edit it -- add a migration step.
    echo "
        CREATE TABLE sessions (
          id integer primary key autoincrement,
          hostname varchar(128),
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
end

function _fishql_migrate -a from -d "Bring the fishql DB schema up to _fishql_schema_target"
    # Only worth announcing for a pre-existing DB: index builds there can stall
    # this one shell launch for a moment. A DB we just created is empty.
    if set -q _fishql_db_created
        set -e _fishql_db_created
    else
        echo "fishql: upgrading database schema (one-time, may take a moment)" >&2
    end

    # Each step is guarded by the version we started from and bumps the version
    # itself, so an interrupted upgrade resumes from where it stopped.
    if test $from -lt 1
        _fishql_migrate_1
        or return 1
    end
    # Future steps go here, guarded the same way:
    #   if test $from -lt 2
    #       _fishql_migrate_2
    #       or return 1
    #   end
end

function _fishql_migrate_1 -d "Schema v1: command suppression list"
    # Every statement is IF NOT EXISTS and the version bump rides inside the
    # same transaction, so shells racing at login cannot corrupt anything: one
    # takes the write lock, the rest wait on it and then find nothing to do.
    # PRAGMA user_version is transactional, so a failure part-way through can
    # never leave the version stamped without the schema it promises.
    #
    # Migrations must stay ADDITIVE ONLY. This config is deployed to many
    # machines, so an older copy of fishql has to keep working against a DB
    # that a newer copy has already migrated.
    # sqlite3 only recognises dot-commands at the very start of a line, so the
    # two below must stay unindented no matter how odd it looks here.
    echo ".bail on
.timeout 5000
BEGIN IMMEDIATE;

    -- Append-only log of suppress/un-suppress actions. A row existing here does
    -- NOT mean the command is currently suppressed -- the latest action per
    -- command wins. Always read current state through the suppressions view.
    CREATE TABLE IF NOT EXISTS suppression_log (
      id integer primary key autoincrement,
      command varchar(1000) not null,
      action varchar(10) not null,
      action_time integer not null,
      note text,
      session_id integer
    );
    CREATE INDEX IF NOT EXISTS suppression_log_cmd_id_idx ON suppression_log(command, id);

    -- Speeds up the GROUP BY command that the history search does.
    CREATE INDEX IF NOT EXISTS commands_command_idx ON commands(command);

    -- The one definition of 'currently suppressed'. Exposes the log id so
    -- callers can tell which log entry is the effective one.
    CREATE VIEW IF NOT EXISTS suppressions AS
      SELECT id, command, action_time, note FROM (
        SELECT id, command, action, action_time, note,
               ROW_NUMBER() OVER (PARTITION BY command ORDER BY id DESC) AS rn
        FROM suppression_log
      ) WHERE rn = 1 AND action = 'suppress';

    PRAGMA user_version = 1;
    COMMIT;
    " | fishql-query

    if test $status -ne 0
        echo "fishql: schema upgrade to v1 failed; suppression features unavailable" >&2
        return 1
    end
end

function _fishql_begin_session -d "Start new fishql session"
    if not test -s "$fishql_dbfile"
        # This should never happen!
        echo "fishql: DB file missing, cannot begin new session" >&2
        return 1
    end

    set -l hn $hostname
    set -l ppid (ps -o ppid -p $fish_pid)[2]
    set -l tz (date +%Z)
    set -l sst (date +%s)
    set -l tty (tty)
    set -l rid (id -ur)
    set -l uid (id -u)
    set -l nid (id -un)

    # One sqlite3 invocation does all three jobs: report the schema version,
    # record this session, and hand back its id. Asking for the id on the same
    # connection is what makes last_insert_rowid() usable, and that is race
    # free -- reading sqlite_sequence in a separate process could return
    # another shell's id when two sessions start at the same moment.
    # The timeout matters on the very first launch after an upgrade: another
    # shell may be holding the write lock to build an index, and without it
    # this insert fails instantly and the session goes unrecorded. Must stay
    # unindented -- sqlite3 only honours dot-commands at the start of a line.
    set -l out (echo ".timeout 5000
    PRAGMA user_version;
    INSERT INTO
    sessions('hostname', 'ppid', 'pid', 'time_zone', 'start_time', 'tty', 'uid', 'euid', 'logname', 'shell', 'sudo_user', 'sudo_uid', 'ssh_client', 'ssh_connection')
    VALUES('$hn', '$ppid', '$fish_pid', '$tz', '$sst', '$tty', '$rid', '$uid', '$nid', '$SHELL', '', '', '$SSH_CLIENT', '$SSH_CONNECTION');
    SELECT last_insert_rowid();
    " | fishql-query)

    # Reuse the values gathered above rather than re-running tty/id/date.
    set -g _fishql_timeout 1000
    set -g _fishql_session_tty $tty
    set -g _fishql_session_euid $uid
    set -g _fishql_session_start $sst
    set -g _fishql_command_id 0
    set -g _fishql_session_id $out[2]

    if not string match -qr '^[1-9][0-9]*$' -- "$_fishql_session_id"
        set -g _fishql_session_id ""
        echo "fishql: could not record session; commands will not be linked to one" >&2
    end

    # Free schema check: the version came back with the insert above. Record the
    # effective version too, so the query front-ends can tell whether the
    # suppression schema exists without paying for another sqlite3 call.
    set -g _fishql_db_version $out[1]
    if set -q _fishql_schema_target
        and string match -qr '^[0-9]+$' -- "$out[1]"
        and test $out[1] -lt $_fishql_schema_target
        if _fishql_migrate $out[1]
            set -g _fishql_db_version $_fishql_schema_target
        end
    end
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
