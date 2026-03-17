#!/bin/bash

# Install requirement
apt update -qq && apt install curl jq -y -qq

read -r -p "Cloudflare API token: " CF_API_TOKEN
echo
read -r -p "Domain [example.com]: " DOMAIN
echo

# Hard coded varialbes
A_SUBDOMAIN="ns"
NS_SUBDOMAINS=(
    "t"
    "d"
    "s"
    "ds"
    "n"
    "z"
    "x"
)
FULL_SUBDOMAINS=(
    "${NS_SUBDOMAINS[@]/%/.${DOMAIN}}"
    "${A_SUBDOMAIN}/%/.${DOMAIN}"
)

# Functions

get_ip() {
    curl -4 -fsSL ip.me
}

get_zone_id() {
    curl -sS -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" | jq -r '.result[0].id'
}

PUBLIC_IP=$(get_ip)
ZONE_ID=$(get_zone_id)

# gurad to check variables
[[ -n "$ZONE_ID" && "$ZONE_ID" != "null" ]] || {
    echo "Failed to get ZONE_ID for domain: $DOMAIN"
    exit 1
}
: "${CF_API_TOKEN:?CF_API_TOKEN is not set}"
: "${DOMAIN:?DOMAIN is not set}"

#
confirm_or_abort() {
    local prompt="${1:-Continue? [y/N]: }"
    local answer
    read -r -p "$prompt" answer

    case "$answer" in
    y | Y | yes | YES | Yes) ;;
    *)
        echo "Aborted."
        exit 1
        ;;
    esac
}

check_conflicting_records() {
    local conflict
    local conflict_record_ids
    local conflict_found=false

    conflict="$(
        curl -sS -X GET \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?per_page=5000" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" | jq -r --argjson targets "$(printf '%s\n' "${FULL_SUBDOMAINS[@]}" | jq -R . | jq -s .)" '
	      .result
	      | map(select(.name as $n | $targets | index($n)))
	      | group_by(.name)[]
	      | . as $group
	      | ($group | map(.type) | unique) as $types
	      | select((($types | index("NS")) and ($types | length > 1)) or ($group | length > 0))
	      | "conflict: \($group[0].name)\n|\n" +
		(
		  $group
		  | to_entries
		  | map(
		      (if .key == (length - 1) then "└" else "├" end) + "─ id: \(.value.id)\n" +
		      "   ├─ name: \(.value.name)\n" +
		      "   ├─ type: \(.value.type)\n" +
		      "   ├─ content: \(.value.content)\n" +
		      "   ├─ ttl: \(.value.ttl)\n" +
		      "   └─ proxied: \(.value.proxied // "null")"
		    )
		  | join("\n")
		) + "\n"
        '
    )"

    if [[ -n "$conflict" ]]; then
        conflict_found=true
        echo "Conflicting records was found!"
        echo "$conflict"
        confirm_or_abort "Delete the conflicting records and create new ones? [y/N]: "

        conflict_record_ids="$(
            printf '%s\n' "$conflict" |
                grep 'id:' |
                sed 's/.*id: //'
        )"

        delete_conflicting_records "$conflict_record_ids"

    else
        conflict_found=false
    fi
}

delete_conflicting_records() {
    local record_ids_str=("$1")

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue

        response=$(
            curl -sS -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${id}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json"
        )

        if [[ "$(jq -r '.success // false' <<<"$response")" == "true" ]]; then
            echo "Deleted record id: $id"
        else
            echo "Failed to delete record id: $id"
            echo "$response"
        fi
    done <<<"$record_ids_str"
}

delete_all_existing_records() {
    curl -sS -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?per_page=5000" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" |
        jq -r '.result[]?.id' |
        while IFS= read -r id; do
            [ -n "$id" ] || continue

            response=$(
                curl -sS -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${id}" \
                    -H "Authorization: Bearer ${CF_API_TOKEN}" \
                    -H "Content-Type: application/json"
            )

            if [ "$(printf '%s' "$response" | jq -r '.success // false')" = "true" ]; then
                echo "Deleted record id: $id"
            else
                echo "Failed to delete record id: $id"
                echo "$response"
            fi
        done
}

preview_batch_and_confirm() {
    local batch_payload="$1"

    echo "The following batch will be submitted:"
    echo

    printf '%s\n' "$batch_payload" | jq -r '
	    .posts[]
	    | if .type == "A" then
		"A   " + .name + " -> " + .content + "  (ttl=" + (.ttl|tostring) + ", proxied=" + (.proxied|tostring) + ")"
	      elif .type == "NS" then
		"NS  " + .name + " -> " + .content + "  (ttl=" + (.ttl|tostring) + ")"
	      else
		.type + "  " + .name + " -> " + .content
	      end
	  '
    printf "%s Continue? [y/N]: "
    read -r answer

    case "$answer" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
    esac
}

create_records_batch_mode() {
    BATCH_PAYLOAD="$(
        jq -n \
            --arg public_ip "$PUBLIC_IP" \
            --arg ns_host "${A_SUBDOMAIN}.${DOMAIN}" \
            --argjson ns_targets "$(printf '%s\n' "${NS_SUBDOMAINS[@]}" | jq -R . | jq -s .)" \
            '
    {
      posts:
      (
        [
          {
            type: "A",
            name: $ns_host,
            content: $public_ip,
            ttl: 60,
            proxied: false
          }
        ]
        +
        [
          $ns_targets[]
          | {
              type: "NS",
              name: .,
              content: $ns_host,
              ttl: 60
            }
        ]
      )
    }'
    )"

    if preview_batch_and_confirm "$BATCH_PAYLOAD"; then

        curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/batch" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "$BATCH_PAYLOAD" | jq -r '.success'

    fi
}

run() {
    check_conflicting_records
    create_records_batch_mode

}
run
