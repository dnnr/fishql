function fishql-query -d "Make a query on the fishql database"
    if test -z "$fishql_dbfile"
        echo "fishql-query: no db file, set fishql_dbfile to a name" >&2
        return 1
    end
    if not set -q fishql_dbprog
        set -g fishql_dbprog sqlite3
    end
    # These functions run on every prompt, so a missing sqlite3 must not spew a
    # fish stack trace at each one. type -q is a builtin, so this costs no fork.
    if not type -q $fishql_dbprog
        echo "fishql-query: $fishql_dbprog not found; history is not being recorded" >&2
        return 1
    end
    $fishql_dbprog $argv $fishql_dbfile
end
