function fishql-init -v fishql_db -d "Init fishql by setting fishql_db"
    if test -n "$argv"
        fishql-initdb
    end
end

