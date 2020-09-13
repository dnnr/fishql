set -l mydir (dirname (realpath (status --current-filename)))
for one in $mydir/functions/*.fish
    source $one
end

