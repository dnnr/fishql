function fishql-now 
    printf "
    select
      c.cwd as 'cwd',
      c.command
    from
      commands as c
      left outer join sessions as s
        on c.session_id = s.id
    where
      c.session_id = $_fishql_session_id
    order by
      c.id
    ;
    " | fishql-query | sed 's/^.*|//' | uniq | fzf --tac +s +m -e --ansi --reverse
end
