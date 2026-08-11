function historya -d "Dump the full recorded command history"
    set pipecmd "cat"
    if isatty 1
        set pipecmd "less"
    end

    # The two-space ELSE pads for the double-width emoji so the timestamp
    # column still lines up; may need tweaking for a given terminal/font.
    set query "SELECT CASE WHEN s.command IS NULL THEN '  ' ELSE '🚫' END, strftime('%Y-%m-%d %H:%M:%S', c.start_time, 'unixepoch', 'localtime'), c.command FROM commands c LEFT JOIN suppressions s ON s.command = c.command ORDER BY c.start_time ASC, c.id ASC"

    echo -e ".separator '  '\n$query" \
        | fishql-query \
        | eval $pipecmd
end
