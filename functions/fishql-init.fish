#echo "loading fishql-init"
function fishql-init -v fishql_db -d "Init fishql by setting fishql_db"
    #echo "calling fishql-init: $fishql_db"
    if test -n "$argv"
        fishql-initdb
    end
end

