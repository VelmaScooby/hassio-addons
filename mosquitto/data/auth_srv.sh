#!/bin/bash
# shellcheck disable=SC2244,SC1117
set -e

CONFIG_PATH=/data/options.json
SYSTEM_USER=/data/system_user.json
REQUEST=()
REQUEST_BODY=""

declare -A LOCAL_DB

## Functions

function http_ok() {
    echo -e "HTTP/1.1 200 OK\n"
    exit 0
}

function http_error() {
    echo -e "HTTP/1.1 400 Bad Request\n"
    exit 0
}


function create_userdb() {
    local hass_pw=""
    local addons_pw=""
    local users=()
    local passwords=()
    local user=""
    #sorry about that, but it way faster than jq
    local sys_user_rex="[\{\}[:blank:]]*\"homeassistant\"\:[\{\}[:blank:]]*\"password\"\:[[:blank:]]*\"([[:alnum:]]+)\"[\{\}\,[:blank:]]*\"addons\"\:[\{\}[:blank:]]*\"password\"\:[[:blank:]]*\"([[:alnum:]]+)\""
    mapfile -t passwords <<< $(jq -r '.logins[].password' $CONFIG_PATH)
    mapfile -t users <<< $(jq -r '.logins[].username' $CONFIG_PATH)

    for i in ${!users[@]}
    do 
        user="${users[i]}"
        LOCAL_DB["${user}"]="${passwords[i]}"
    done

    # Add system user to DB
    [[ $(cat $SYSTEM_USER) =~ $sys_user_rex ]] && LOCAL_DB['homeassistant']=${BASH_REMATCH[1]} && LOCAL_DB['addons']=${BASH_REMATCH[2]}
}


function read_request() {
    local content_length=0

    while read -r line; do
        line="${line%%[[:cntrl:]]}"

        if [[ "${line}" =~ Content-Length ]]; then
            content_length="${line//[!0-9]/}"
        fi

        if [ -z "$line" ]; then
            if [ "${content_length}" -gt 0 ]; then
                read -r -n "${content_length}" REQUEST_BODY
            fi
            break
        fi

        REQUEST+=("$line")
    done
}



function get_var() {
    local variable=$1
    local value=""
    local rex="^.*$variable=([[:alnum:]%[:blank:]]*)(&|$)"

    urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }

    [[ $REQUEST_BODY =~ $rex ]] && value="${BASH_REMATCH[1]}"
    
    urldecode "${value}"
}


## MAIN ##

read_request

# This feature currently not implemented, we response with 200
if [[ "${REQUEST[0]}" =~ /superuser ]] || [[ "${REQUEST[0]}" =~ /acl ]]; then
    http_ok
fi

# We read now the user data
create_userdb

username="$(get_var username)"
password="$(get_var password)"

# If local user
if [ "${LOCAL_DB["${username}"]}" == "${password}" ]; then
    echo "[INFO] found ${username} on local database" >&2
    http_ok
elif [ ${LOCAL_DB["${username}"]+_} ]; then
    echo "[WARN] Not found ${username} on local database" >&2
    http_error
fi

# Ask HomeAssistant Auth
auth_header="X-Hassio-Key: ${HASSIO_TOKEN}"
content_type="Content-Type: application/x-www-form-urlencoded"

if curl -s -f -X POST -d "${REQUEST_BODY}" -H "${content_type}" -H "${auth_header}" http://hassio/auth > /dev/null; then
    echo "[INFO] found ${username} on Home Assistant" >&2
    http_ok
fi

echo "[ERROR] Auth error with ${username}" >&2
http_error
