function search_history
  set cmd (commandline)

  # Note: I've tried adding --height=40% here in 08/2023 (like the official fzf
  #       bindings do), but it seems to break my prompt/scrollback buffer contents.
  # Also: The ctrl-r binding toggles between preserving the input order and
  #       sorting by best match.
  set fzf_flags --no-sort --bind=ctrl-r:toggle-sort
  set fzf_query --query \'
  if [ (count $cmd) -gt 0 ]
    # Prepend a quote here to enable exact matching (better than using the
    # --exact flag, which can't be disabled at runtime)
    set fzf_query --query \'"$cmd"
  end

  set -l suppressed "WHERE NOT EXISTS (SELECT 1 FROM suppressions s WHERE s.command = commands.command)"
  if set -q _fishql_db_version
      and string match -qr '^[0-9]+$' -- "$_fishql_db_version"
      and test $_fishql_db_version -lt 1
    set suppressed ""
  end

  # Note 1: The GROUP BY with max() eliminates duplicates in favor of the most recent invocation.
  # Note 2: We order new-to-old so that if the query is slow, the more recent commands appear fastest.
  #         As it so happens, fzf already reverses the output (first line is at bottom), so passing --tac is not needed.
  echo -e ".separator '  '\nSELECT max(strftime('%Y-%m-%d %H:%M:%S', start_time, 'unixepoch', 'localtime')), command FROM commands $suppressed GROUP BY command ORDER BY start_time DESC" \
      | fishql-query \
      | fzf --nth=3.. $fzf_flags $fzf_query \
      # Note: .*? is a non-greedy match that makes sure we only match our own
      #       double space and not one in the payload (the stored command). It's not
      #       supported in sed, therefore we use perl.
      | perl -pe 's/^.*?  //' \
      | read from_fzf

  if [ $from_fzf ]
    commandline -- $from_fzf
  end
end
