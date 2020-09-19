function fishql -a cmd
    if test "$cmd" = "init"
        set mydir (dirname (realpath (status --current-filename)))
        source $mydir/fishql-init.fish
        source $mydir/fishql-preexec.fish
        source $mydir/fishql-postexec.fish
        if not set -q fishql_db
            #echo "using fishql database 'default'"
            set -g fishql_db default
        end
        return
    end

    echo "unknown command: $cmd"

end

