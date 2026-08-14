function historya
    set pipecmd "cat"
    if isatty 1
        set pipecmd "less"
    end

    echo -e ".separator '  '\nSELECT strftime('%Y-%m-%d %H:%M:%S', start_time, 'unixepoch', 'localtime'), command FROM commands ORDER BY start_time ASC, id ASC" \
        | fishql-query \
        | eval $pipecmd
end
