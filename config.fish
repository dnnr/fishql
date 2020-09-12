set -l mydir (dirname (realpath (status --current-filename)))
echo $mydir
for one in $mydir/functions/*.fish
    source $one
end

