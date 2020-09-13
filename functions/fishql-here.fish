function fishql-here
    printf "
    select
      c.command as 'what'
    from
      commands as c
    where
      c.cwd = '$PWD' 
    order by c.start_time, c.session_id
    ;
    " | fishql-query | uniq | fzf --tac +s +m -e --ansi --reverse
end
