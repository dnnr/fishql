# Source this in your config

# avoid race on command exit 
set -x _fishql_timeout 100
set -x _fishql_session_tty (tty)
set -x _fishql_session_euid (id -u)
set -x _fishql_session_start (date +%s)

