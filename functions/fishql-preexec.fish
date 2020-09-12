function fishql-preexec --on-event fish_preexec
    if test -z "$argv"
        return
    end
    set -g _fishql_command_start (date +%s)
    set -g _fishql_command_cwd (pwd)
    set -g _fishql_command_id (math $_fishql_command_id + 1)
end
