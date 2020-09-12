function fishql-query -d "Make a query on the fishql database"
    if test -z "$fishql_dbfile"
        echo "fishql-query: no db file set fishql_db to a name"
        return
    end
    if not set -q fishql_dbprog
        set -g fishql_dbprog sqlite3
    end
    $fishql_dbprog $argv $fishql_dbfile
end
