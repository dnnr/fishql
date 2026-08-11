# Entry function named after this file for autoloading
function fishql-suppress -a cmd -d "Hide commands from the history search, or reveal them again"
    switch $cmd
        case ""
            _fishql_suppress_pick
        case list
            _fishql_suppress_list
        case -h --help
            echo "Usage: fishql-suppress         Pick commands to suppress or un-suppress"
            echo "       fishql-suppress list    Show the full suppression log"
            echo ""
            echo "Keys in the picker:"
            echo "  enter    Toggle each pick: suppress the visible ones, reveal the hidden ones"
            echo "  ctrl-s   Suppress every pick, skipping the ones already suppressed"
            echo "  ctrl-x   Un-suppress every pick, skipping the ones already visible"
            echo "  ctrl-r   Toggle between input order and best-match order"
            echo "  tab      Add a line to the selection; esc leaves without writing anything"
            echo ""
            echo "Suppressed commands are hidden from search_history (ctrl-r). They are"
            echo "never removed from the recorded history itself -- historya still lists"
            echo "them, and 'historya --marks' shows which ones are suppressed."
        case \*
            echo "fishql-suppress: Unknown command: \"$cmd\"" >&2
            return 1
    end
end

function _fishql_suppress_ready -d "Check that this shell can use the suppression list"
    if test -z "$fishql_dbfile"
        echo "fishql-suppress: fishql is not initialized in this shell (run 'fishql init')" >&2
        return 1
    end
    # _fishql_db_version is recorded at session start, so this costs no query.
    # Only refuse when we positively know the schema is too old.
    if set -q _fishql_db_version
        and string match -qr '^[0-9]+$' -- "$_fishql_db_version"
        and test $_fishql_db_version -lt 1
        echo "fishql-suppress: this database predates the suppression schema." >&2
        echo "                 A schema upgrade failed; see earlier fishql warnings." >&2
        return 1
    end
    return 0
end

function _fishql_suppress_plural -a n
    if test $n -eq 1
        echo command
    else
        echo commands
    end
end

function _fishql_suppress_show -a title -d "Print a heading and an indented list of command texts"
    if test (count $argv) -lt 2
        return 0
    end
    echo $title
    for t in $argv[2..]
        echo "  "(string replace -a \n ' ⏎ ' -- $t)
    end
end

function _fishql_suppress_pick -d "Pick commands via fzf and suppress or un-suppress them"
    _fishql_suppress_ready
    or return 1

    if not type -q fzf
        echo "fishql-suppress: fzf is required for interactive selection" >&2
        return 1
    end

    # Same two-space separator as the other views, so this lines up with
    # 'historya --marks'. The id rides along as a hidden first column, purely as
    # a handle for fetching the exact stored bytes later -- the suppression
    # itself is keyed on the command *text*, so it covers every occurrence of it.
    # Every row in a group has the same command by construction, so max(c.id) and
    # max(c.start_time) need not come from the same row.
    #
    # The marker for an unsuppressed command is two NON-BREAKING spaces. fzf
    # splits fields on runs of tabs and ordinary spaces, so a NBSP renders as
    # blank while still holding a field of its own. With real spaces the empty
    # marker would dissolve into the separator, leaving unsuppressed rows one
    # field short of suppressed ones -- which drops the first word of the command
    # out of the --nth match for half the list. char(160,160) rather than literal
    # NBSPs in this file, because an invisible character in source is one stray
    # reformat away from becoming an ordinary space, with no visible diff.
    # ('historya --marks' pads with plain spaces instead: its output is
    # pipeline-facing, where a NBSP would surprise cut and awk.)
    #
    # Newlines and tabs are collapsed in the displayed text only, so that one
    # stored command is always exactly one fzf line. The real text is fetched by
    # id later, never reconstructed from this output.
    set -l out (echo ".separator '  '
SELECT max(c.id),
       CASE WHEN s.command IS NULL THEN char(160,160) ELSE '🚫' END,
       strftime('%Y-%m-%d %H:%M:%S', max(c.start_time), 'unixepoch', 'localtime'),
       replace(replace(c.command, char(10), ' ⏎ '), char(9), ' ')
FROM commands c
LEFT JOIN suppressions s ON s.command = c.command
GROUP BY c.command
ORDER BY max(c.start_time) DESC" | fishql-query |
        # --with-nth hides the id column from display, and --nth applies to that
        # transformed string, so 4.. matches on the command only: whitespace
        # splitting makes the date and the time two separate fields. No
        # --delimiter is needed for any of it.
        #
        # --expect makes fzf print the key that accepted the selection as its
        # first output line, which is how the picker learns the direction the
        # user meant. Re-invoking fishql-suppress from a --bind=...:execute()
        # instead cannot work: fishql_dbfile is set -g rather than exported and
        # conf.d only runs 'fishql init' for interactive shells, so a fish
        # spawned by fzf would have no database at all -- and the fish-history
        # purge at the end of _fishql_suppress_apply has to happen in *this*
        # shell, or this shell's in-memory history keeps feeding the command back
        # through autosuggestions and up-arrow. 'enter' is named explicitly
        # because otherwise it reports itself as an empty first line, and relying
        # on that surviving command substitution is not worth the risk.
        #
        # ctrl-x, not the more obvious ctrl-u, which is fzf's own
        # clear-the-query-line key.
        fzf -m --no-sort --bind=ctrl-r:toggle-sort --with-nth=2.. --nth=4.. \
            --expect=enter,ctrl-s,ctrl-x \
            --header='enter: toggle  ctrl-s: suppress  ctrl-x: un-suppress  ctrl-r: sort')

    # ESC aborts with no output at all, so a single line means a key came back
    # without a selection (an empty picker). Neither is an error.
    if test (count $out) -lt 2
        return 0
    end

    set -l mode
    switch $out[1]
        case enter
            set mode auto
        case ctrl-s
            set mode suppress
        case ctrl-x
            set mode unsuppress
        case \*
            echo "fishql-suppress: unexpected key from fzf, aborting" >&2
            return 1
    end

    set -l ids
    for row in $out[2..]
        set -l id (string split -f1 '  ' -- $row)
        if not string match -qr '^[1-9][0-9]*$' -- "$id"
            echo "fishql-suppress: unexpected selection format, aborting" >&2
            return 1
        end
        set -a ids $id
    end

    _fishql_suppress_apply $mode $ids
end

function _fishql_suppress_apply -a mode -d "Confirm and record suppression changes for the given command ids"
    set -l ids $argv[2..]
    if test (count $ids) -eq 0
        return 0
    end

    # The current state of every pick, resolved in one query; the command text is
    # fetched separately below because it may contain newlines. Asking for the
    # state rather than a ready-made action keeps this one query serving all
    # three modes. The LEFT JOIN cannot fan out: the suppressions view holds at
    # most one row per command, and the picker groups by command, so the ids
    # arriving here name distinct texts.
    set -l pairs (echo "SELECT c.id, CASE WHEN s.command IS NULL THEN 'off' ELSE 'on' END
FROM commands c
LEFT JOIN suppressions s ON s.command = c.command
WHERE c.id IN ("(string join ',' $ids)")" | fishql-query)

    if test (count $pairs) -eq 0
        echo "fishql-suppress: could not look up the selected commands" >&2
        return 1
    end

    # 'auto' (enter) derives the direction from each pick's current state, while
    # the explicit keys force one and drop the picks that are already there. That
    # skipping is the point of the explicit keys -- it is what makes "suppress all
    # of these" mean one thing when the selection mixes hidden and visible
    # commands.
    set -l sup_ids
    set -l sup_texts
    set -l uns_ids
    set -l uns_texts
    set -l skipped
    for pair in $pairs
        set -l parts (string split -m1 '|' -- $pair)
        set -l id $parts[1]
        # string collect keeps an embedded newline inside one list element
        # instead of splitting the command across several.
        set -l text (echo "SELECT command FROM commands WHERE id = $id;" | fishql-query | string collect)

        if test "$parts[2]" = off; and test "$mode" != unsuppress
            set -a sup_ids $id
            set -a sup_texts $text
        else if test "$parts[2]" = on; and test "$mode" != suppress
            set -a uns_ids $id
            set -a uns_texts $text
        else
            set -a skipped $text
        end
    end

    set -l ns (count $sup_ids)
    set -l nu (count $uns_ids)
    set -l nk (count $skipped)

    # Only the explicit keys ever skip anything, so every skip in one run has the
    # same reason.
    set -l skipword "already suppressed"
    if test "$mode" = unsuppress
        set skipword "not suppressed"
    end

    # Nothing left to write once the skips are taken out: say so and stop before
    # the prompts, rather than asking to confirm a no-op. Not an error -- the
    # picks simply were already the way the user asked for.
    if test $ns -eq 0; and test $nu -eq 0
        if test $nk -eq 1
            echo "That command is $skipword. Nothing to do."
        else
            echo "All $nk selected commands are $skipword. Nothing to do."
        end
        return 0
    end

    _fishql_suppress_show "Skipping, $skipword:" $skipped
    _fishql_suppress_show "Will be suppressed:" $sup_texts
    _fishql_suppress_show "Will be un-suppressed:" $uns_texts

    read -P "Note (optional, applies to all)> " -l note

    set -l question
    if test $ns -gt 0; and test $nu -gt 0
        set question "Suppress $ns and un-suppress $nu "(_fishql_suppress_plural (math $ns + $nu))"?"
    else if test $ns -gt 0
        set question "Suppress $ns "(_fishql_suppress_plural $ns)"?"
    else
        set question "Un-suppress $nu "(_fishql_suppress_plural $nu)"?"
    end

    read -P "$question [y/N] " -l answer
    if not string match -qir '^y(es)?$' -- "$answer"
        echo "Aborted, nothing written."
        return 1
    end

    set -l now (date +%s)
    set -l notesql NULL
    if test -n "$note"
        set notesql "'"(string replace -a -- "'" "''" $note)"'"
    end
    set -l sessionsql NULL
    if string match -qr '^[1-9][0-9]*$' -- "$_fishql_session_id"
        set sessionsql $_fishql_session_id
    end

    # One transaction for the whole batch. The command text is copied inside SQL
    # straight from the row it came from, so it can never be mangled on its way
    # through the shell -- the stored key is byte-identical to what was recorded.
    # Dot-commands have to stay unindented for sqlite3 to see them.
    set -l sql ".bail on
.timeout 5000
BEGIN IMMEDIATE;"
    if test $ns -gt 0
        set sql "$sql
INSERT INTO suppression_log(command, action, action_time, note, session_id)
  SELECT command, 'suppress', $now, $notesql, $sessionsql FROM commands WHERE id IN ("(string join ',' $sup_ids)");"
    end
    if test $nu -gt 0
        set sql "$sql
INSERT INTO suppression_log(command, action, action_time, note, session_id)
  SELECT command, 'unsuppress', $now, $notesql, $sessionsql FROM commands WHERE id IN ("(string join ',' $uns_ids)");"
    end
    set sql "$sql
COMMIT;"

    echo $sql | fishql-query
    if test $status -ne 0
        echo "fishql-suppress: failed to update the suppression log" >&2
        return 1
    end

    if test $ns -gt 0
        # Suppressing only hides a command from this tool's search. fish keeps
        # its own history, which feeds autosuggestions and up-arrow, so a
        # suppressed command would stay one keystroke from running. Drop it from
        # there too.
        for t in $sup_texts
            history delete --exact --case-sensitive -- $t
        end
        history save
        echo "Suppressed $ns "(_fishql_suppress_plural $ns)", also removed from fish's own history."
        echo "Note: that removal is not undone by un-suppressing, running the command again"
        echo "      re-adds it, and other fish sessions already running may restore it."
    end
    if test $nu -gt 0
        echo "Un-suppressed $nu "(_fishql_suppress_plural $nu)"."
    end
end

function _fishql_suppress_list -d "Show the full suppression log"
    _fishql_suppress_ready
    or return 1

    # This view is for reading, not for piping into cut or awk: it is grouped,
    # indented and coloured. Anything that wants the raw log should query the
    # suppression_log table through fishql-query.
    set -l human 0
    set -l pipecmd cat
    if isatty 1
        set human 1
        # -R so the colours below survive the pager.
        set pipecmd "less -R"
    end

    # Tab between the fields. The two-space separator the other views use is fine
    # for output that is only ever looked at, but this one is parsed back apart
    # to colour each field, and a command containing two spaces would split in
    # the wrong place. A tab is safe because every field below has its own tabs
    # replaced before the join -- and because tab and newline are the only two
    # control characters a recent sqlite3 shell still emits verbatim (as of
    # 3.53 it rewrites the rest into caret notation, so char(31) arrives here as
    # a literal '^_'). A fancier separator would work against an older sqlite3
    # and quietly stop splitting against a newer one.
    set -l us \t

    # The log is append-only, so a command can appear in it several times; those
    # entries are that command's history and are grouped under it rather than
    # scattered through the listing by date. 'last' picks the entry in effect for
    # a command exactly the way the suppressions view does, highest id wins, and
    # its action is what the group heading shows -- which is why a command whose
    # latest entry is an 'unsuppress' still gets a heading here, even though the
    # view deliberately does not list it (it only holds what is hidden now).
    #
    # Groups are ordered by when they were last acted on and entries within a
    # group oldest first, so the listing as a whole still reads forwards in time.
    # 'head' marks the entry that opens a group; the caller prints the heading
    # off that flag instead of comparing command texts itself.
    #
    # Newlines and tabs are collapsed so that one log entry is always one line
    # to parse and one line to print.
    set -l rows (echo "WITH last AS (
  SELECT command, id, action, action_time FROM (
    SELECT command, id, action, action_time,
           ROW_NUMBER() OVER (PARTITION BY command ORDER BY id DESC) AS rn
    FROM suppression_log
  ) WHERE rn = 1
)
SELECT CASE WHEN ROW_NUMBER() OVER (PARTITION BY e.command
                                    ORDER BY e.action_time, e.id) = 1
            THEN 'head' ELSE 'body' END
    || char(9) || CASE WHEN e.id = l.id THEN 'now' ELSE 'old' END
    || char(9) || l.action
    || char(9) || strftime('%Y-%m-%d %H:%M', e.action_time, 'unixepoch', 'localtime')
    || char(9) || e.action
    || char(9) || replace(replace(e.command, char(10), ' ⏎ '), char(9), ' ')
    || char(9) || coalesce(replace(replace(e.note, char(10), ' ⏎ '), char(9), ' '), '')
FROM suppression_log e
JOIN last l ON l.command = e.command
ORDER BY l.action_time, l.command, e.action_time, e.id" | fishql-query)

    if test (count $rows) -eq 0
        echo "Nothing suppressed yet. Run 'fishql-suppress' to pick commands to hide."
        return 0
    end

    # Colours only when a human is looking at them; set_color would happily
    # write escapes into a pipe otherwise.
    set -l off ""
    set -l c_meta "" # superseded entries
    set -l c_time ""
    set -l c_cmd "" # the command a group is about
    set -l c_hide "" # suppress, in both the bar and the word
    set -l c_show "" # unsuppress
    set -l c_note ""
    if test $human -eq 1
        set off (set_color normal)
        set c_meta (set_color brblack)
        set c_time (set_color cyan)
        set c_cmd (set_color -o)
        set c_hide (set_color -o red)
        set c_show (set_color -o green)
        set c_note (set_color yellow)
    end

    begin
        set -l opened 0
        for row in $rows
            set -l f (string split $us -- $row)
            # An empty note is a trailing empty field, which command
            # substitution drops, so the last field may simply not be there.
            set -l note ""
            if test (count $f) -ge 7
                set note (string join $us $f[7..])
            end

            if test "$f[1]" = head
                # A blank line between groups, but not above the first one.
                if test $opened -eq 1
                    echo
                end
                set opened 1
                # The heading says what the command is and where it stands right
                # now; everything under it is how it got there. The emoji is
                # spent here alone, so scanning the left edge answers "what is
                # hidden" without reading a single date.
                set -l gly 🚫
                if test "$f[3]" = unsuppress
                    set gly 👀
                end
                echo "$gly "$c_cmd$f[6]$off
            end

            # The gap absorbs the two-character difference between the words, so
            # notes line up under either one. It is only ever printed in front of
            # a note, which keeps entries without one from trailing whitespace.
            set -l word suppress
            set -l gap "    "
            set -l accent $c_hide
            if test "$f[5]" = unsuppress
                set word unsuppress
                set gap "  "
                set accent $c_show
            end

            if test "$f[2]" = now
                set -l line "   "$accent"▌"$off" "$c_time$f[4]$off"  "$accent$word$off
                if test -n "$note"
                    set line $line$gap$c_note"📝 $note"$off
                end
                echo $line
            else
                # One dim run for the whole line, bar column left empty: a
                # superseded entry is context, not something to read word by word.
                set -l line $c_meta"     $f[4]  $word"
                if test -n "$note"
                    set line $line$gap"📝 $note"
                end
                echo $line$off
            end
        end
    end | eval $pipecmd
end
