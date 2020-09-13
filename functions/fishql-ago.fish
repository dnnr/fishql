function fishql-ago
    set -l when $argv[1]
    set prec 1
    if test -n "$argv[2]"
        set prec $argv[2]
    end
    printf "
    select datetime(start_time,'unixepoch','localtime'),command from commands where abs(start_time - strftime('%%s', '$when')) < 3600 * 24 * $prec;
    " | fishql-query
end

