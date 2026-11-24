#!/bin/bash
# Shared *.home.arpa rewrite logic for generate-adguard-config.sh and sync-adguard-rewrites.sh. Not meant to be run directly.
# Usage: source this file (after colors.sh, uses $RED/$NC), set LAN_SUBNET/VPN_SUBNET, call load_service_hosts and
# detect_rewrite_ips, then the functions below.

# Prints only the `user_rules:` block
user_rules_block() {
    awk '/^user_rules:/{f=1} f && !/^user_rules:/ && /^[^ ]/{exit} f'
}

# awk fragment that swaps the user_rules: block for $USER_RULES_BLOCK, counting swaps in user_rules_subs
# shellcheck disable=SC2034 # read by the scripts that source this file
USER_RULES_SUBST_AWK='
/^user_rules:/ { printf "%s", ENVIRON["USER_RULES_BLOCK"]; user_rules_subs++; u = 1; next }
u && /^[^ ]/ { u = 0 }                           # left it: next top-level key
u { next }                                       # drops the old block lines
'

# Sets SERVICE_HOSTS: one <name>.home.arpa per conf.d/<name>.conf.template, except default
load_service_hosts() {
    local dir="$1" f name
    SERVICE_HOSTS=()
    for f in "$dir"/*.conf.template; do
        # No templates at all: the glob stays literal
        [ -e "$f" ] || continue
        name=$(basename "$f" .conf.template)
        # The catch-all server, not a service
        [ "$name" = "default" ] && continue
        SERVICE_HOSTS+=("$name.home.arpa")
    done
}

# Sets LAN_IP/VPN_IP, this host's own address in each zone. Exits with a clear error if either can't be found
detect_rewrite_ips() {
    # ADGUARD_LAN_IP overrides autodetection (e.g. CI, which is never on $LAN_SUBNET)
    #         Overwrite       Get the real host's IP on the LAN_SUBNET
    LAN_IP="${ADGUARD_LAN_IP:-$(ip -4 route show scope link | awk -v subnet="$LAN_SUBNET" '$1 == subnet { for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }' || true)}"    # `|| true`: don't let set -e kill the script before the check below can

    # If LAN_IP is empty, an error occurred
    if [ -z "$LAN_IP" ]; then
        echo -e "${RED}Error: couldn't detect this host's IP on $LAN_SUBNET.${NC}"
        echo "Set ADGUARD_LAN_IP=<ip> to override (e.g. this host isn't directly on that subnet, or you're in CI)."
        exit 1
    fi

    # ADGUARD_VPN_IP overrides autodetection (e.g. CI, or wg0 not up yet)
    #         Overwrite       Get this host's tunnel IP from wg0
    VPN_IP="${ADGUARD_VPN_IP:-$(ip -4 -o addr show dev wg0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)}"    # `|| true`: same as above

    # If VPN_IP is empty, an error occurred
    if [ -z "$VPN_IP" ]; then
        echo -e "${RED}Error: couldn't detect this host's WireGuard tunnel IP (wg0).${NC}"
        echo "Set ADGUARD_VPN_IP=<ip> to override (e.g. wg0 isn't up on this host yet, or you're in CI)."
        exit 1
    fi
}

# Prints the rule nginx's <host> gets in one zone: ||<host>^$dnsrewrite=NOERROR;A;<ip>,client=<cidr>
managed_rule() {
    printf '%s' "||$1^\$dnsrewrite=NOERROR;A;$2,client=$3"
}

# Prints <host>, or nothing if it isn't a dnsrewrite rule
rule_domain() {
    [[ "$1" =~ ^\|\|([^^]+)\^\$dnsrewrite= ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}
# Prints <ip>, or nothing if it isn't an A rewrite
rule_ip() {
    [[ "$1" =~ \$dnsrewrite=NOERROR\;A\;([^,]+), ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}

# Returns 0 if $1 is one of SERVICE_HOSTS
is_managed_host() {
    local h
    for h in "${SERVICE_HOSTS[@]}"; do [ "$h" = "$1" ] && return 0; done
    return 1
}

# Returns 0 if rule $1 belongs to nginx (rebuilt every run), 1 if it's a custom one (kept)
is_managed_rule() {
    local rule="$1" domain ip
    domain=$(rule_domain "$rule")
    # Not a dnsrewrite: always custom
    [ -z "$domain" ] && return 1
    ip=$(rule_ip "$rule")
    # Not an A rewrite (AAAA, CNAME...): always custom
    [ -z "$ip" ] && return 1
    # A host with a conf.d/ template: nginx's exact rule for either zone, any IP, so an IP change gets replaced
    if is_managed_host "$domain"; then
        [ "$rule" = "$(managed_rule "$domain" "$ip" "$LAN_SUBNET")" ] ||
            [ "$rule" = "$(managed_rule "$domain" "$ip" "$VPN_SUBNET")" ]
        return
    fi
    # A dropped service: only the exact rule this script writes, so your own *.home.arpa rules stay
    [[ "$domain" == *.home.arpa ]] || return 1
    [ "$rule" = "$(managed_rule "$domain" "$LAN_IP" "$LAN_SUBNET")" ] ||
        [ "$rule" = "$(managed_rule "$domain" "$VPN_IP" "$VPN_SUBNET")" ]
}

# Returns 0 if rule $1 has the exact shape of nginx's rules, for any *.home.arpa host, IP and subnet
has_managed_shape() {
    local rule="$1" domain ip cidr
    domain=$(rule_domain "$rule")
    ip=$(rule_ip "$rule")
    cidr="${rule##*,client=}"
    [[ "$domain" == *.home.arpa && -n "$ip" && "$cidr" == */* ]] &&
        [ "$rule" = "$(managed_rule "$domain" "$ip" "$cidr")" ]
}

# Prints the rule in one `  - <rule>` line, without AdGuard's YAML quoting
decode_rule_line() {
    local v="${1#  - }"
    if [[ "$v" == \'*\' ]]; then
        # 'single-quoted': strip the quotes, '' back to '
        v="${v#\'}"
        v="${v%\'}"
        printf '%s' "${v//"''"/"'"}"
    elif [[ "$v" != \"* ]]; then
        # Plain: already the rule
        printf '%s' "$v"
    fi
    # "double-quoted": prints nothing. Never a managed rule, and kept as its original line anyway
}

# Builds a new user_rules: block for <file>, fresh nginx rules first, then every custom rule's line as-is
# Sets: USER_RULES_BLOCK, REWRITES_CHANGED, REWRITE_REPORT (all nginx rules), REWRITE_CHANGES (only the changed ones), KEPT_RULES,
# STALE_RULES (kept ones shaped like nginx's)
# Returns 1 if <file>'s user_rules: isn't in a format this can safely rewrite
# shellcheck disable=SC2034 # read by the scripts that source this file
compute_user_rules() {
    local file="$1" header line rule rule_ip_now h zone cidr ip old_rule old_ip changed new_rule
    local -a old_lines=() old_managed=() new_managed=() new_lines=()
    local -A accounted=() seen=()

    # Missing or inline (`user_rules: [a, b]`) list: AdGuard never writes that, so its format changed
    header=$(user_rules_block < "$file" | head -n 1)
    if [ "$header" != "user_rules:" ] && [ "$header" != "user_rules: []" ]; then
        echo -e "${RED}Error: couldn't find a user_rules: list in $file (got: '${header:-nothing}'). Its format may have changed.${NC}"
        return 1
    fi

    # Loads the current rules, one `  - <rule>` per line
    while IFS= read -r line; do
        # Anything else (e.g. a rule split over several lines) would be mangled below
        if [[ "$line" != "  - "* ]]; then
            echo -e "${RED}Error: unexpected line in $file's user_rules: '$line'. Its format may have changed.${NC}"
            return 1
        fi
        old_lines+=("$line")
    done < <(user_rules_block < "$file" | tail -n +2)

    # Splits the current rules into nginx's and custom ones
    KEPT_RULES=()
    STALE_RULES=()
    for line in "${old_lines[@]}"; do
        rule=$(decode_rule_line "$line")
        if is_managed_rule "$rule"; then
            # nginx's: compared below, then replaced
            old_managed+=("$rule")
        else
            # Custom: its original line is written back untouched
            new_lines+=("$line")
            # For display: decoded, or the raw value if it was "double-quoted"
            KEPT_RULES+=("${rule:-${line#  - }}")
            # Shaped like nginx's (dropped service on an old IP, old subnet...): maybe a leftover, or yours
            if has_managed_shape "$rule"; then STALE_RULES+=("$rule"); fi
        fi
    done

    # The nginx rules wanted now (per host, LAN then VPN), each reported as new, changed IP or unchanged
    REWRITE_REPORT=()
    REWRITE_CHANGES=()
    for h in "${SERVICE_HOSTS[@]}"; do
        for zone in lan vpn; do
            if [ "$zone" = lan ]; then cidr="$LAN_SUBNET" ip="$LAN_IP"; else cidr="$VPN_SUBNET" ip="$VPN_IP"; fi
            new_managed+=("$(managed_rule "$h" "$ip" "$cidr")")

            # Finds this host+zone's current rule (any IP), not already matched to another (duplicates)
            old_rule=""
            old_ip=""
            for rule in "${old_managed[@]}"; do
                # Cheap checks first: another host's rule, or already matched
                [[ "$rule" == "||$h^"* ]] || continue
                [ -z "${accounted[$rule]}" ] || continue
                rule_ip_now=$(rule_ip "$rule")
                if [ -n "$rule_ip_now" ] && [ "$rule" = "$(managed_rule "$h" "$rule_ip_now" "$cidr")" ]; then
                    old_rule="$rule"
                    old_ip="$rule_ip_now"
                    break
                fi
            done

            changed="true"
            if [ -z "$old_rule" ]; then
                # Not there yet
                line="  + $h  $zone -> $ip (new)"
            elif [ "$old_ip" = "$ip" ]; then
                # Same rule: only in REWRITE_REPORT
                line="    $h  $zone -> $ip (unchanged)"
                changed="false"
            else
                # This host's IP changed
                line="  ~ $h  $zone -> $ip (was $old_ip)"
            fi
            [ -n "$old_rule" ] && accounted["$old_rule"]=1
            REWRITE_REPORT+=("$line")
            [ "$changed" = "false" ] || REWRITE_CHANGES+=("$line")
        done
    done

    # Current nginx rules nothing above matched: dropped service, old subnet, duplicate, AAAA...
    for rule in "${old_managed[@]}"; do
        # Matched above: skip its first copy only, so a duplicate shows as removed
        if [ -n "${accounted[$rule]}" ] && [ -z "${seen[$rule]}" ]; then
            seen["$rule"]=1
            continue
        fi
        line="  - $rule (removed)"
        REWRITE_REPORT+=("$line")
        REWRITE_CHANGES+=("$line")
    done

    # Changed if nginx's rules differ, in order (custom rules mixed in between don't count)
    REWRITES_CHANGED="false"
    if [ "$(printf '%s\n' "${old_managed[@]}")" != "$(printf '%s\n' "${new_managed[@]}")" ]; then
        REWRITES_CHANGED="true"
        # Same rules, only in another order
        [ "${#REWRITE_CHANGES[@]}" -eq 0 ] && REWRITE_CHANGES+=("  ~ managed rules reordered")
    fi

    # New block: nginx's rules quoted like AdGuard would, then the custom lines untouched
    local -a final_lines=()
    for new_rule in "${new_managed[@]}"; do
        final_lines+=("  - '${new_rule//"'"/"''"}'")
    done
    final_lines+=("${new_lines[@]}")
    if [ "${#final_lines[@]}" -eq 0 ]; then
        # No rules at all: AdGuard's own empty-list form
        USER_RULES_BLOCK="user_rules: []"$'\n'
    else
        USER_RULES_BLOCK="user_rules:"$'\n'"$(printf '%s\n' "${final_lines[@]}")"$'\n'
    fi
}
