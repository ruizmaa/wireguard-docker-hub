#!/bin/bash
# Generates services/adguard/conf/AdGuardHome.yaml with a real admin password hash.
# Usage: ./services/generate-adguard-config.sh [--force]
# Non-interactive (e.g. CI): set ADGUARD_SETUP_USER and ADGUARD_SETUP_PASSWORD.
set -eo pipefail

# Prints only the `user_rules:` block
user_rules_block() {
    awk '/^user_rules:/{f=1} f && !/^user_rules:/ && /^[^ ]/{exit} f'
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=scripts/lib/colors.sh
source "$SCRIPT_DIR/../scripts/lib/colors.sh"
# shellcheck source=scripts/lib/writable-guard.sh
source "$SCRIPT_DIR/../scripts/lib/writable-guard.sh"
# shellcheck source=scripts/lib/force-flag.sh
source "$SCRIPT_DIR/../scripts/lib/force-flag.sh"
# shellcheck source=scripts/lib/adguard-users.sh
source "$SCRIPT_DIR/../scripts/lib/adguard-users.sh"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Fails clearly here if .env is incomplete, not with a cryptic docker error later
if ! compose_json=$(docker compose -f "$COMPOSE_FILE" config --format json); then
    echo -e "${RED}Error: 'docker compose config' failed. Check .env is fully filled in.${NC}"
    exit 1
fi
IMAGE=$(echo "$compose_json" | jq -r '.services.adguard.image')

OUT_DIR="$SCRIPT_DIR/adguard/conf"
OUT_FILE="$OUT_DIR/AdGuardHome.yaml"
TEMPLATE_FILE="$SCRIPT_DIR/adguard/AdGuardHome.yaml.template"
# Also created so docker compose up doesn't create it as root first
WORK_DIR="$SCRIPT_DIR/adguard/work"

parse_force_flag "$@"

guard_writable_dir "$OUT_DIR"
guard_writable_dir "$WORK_DIR"
guard_writable_file "$OUT_FILE"

# Refuse to overwrite an existing config unless the caller explicitly opted in
if [ -f "$OUT_FILE" ] && [ "$FORCE" != "true" ]; then
    echo -e "${RED}Error: $OUT_FILE already exists. Pass --force to overwrite it.${NC}"
    exit 1
fi

# The template is tracked in git and should always exist, if not raise an error
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}Error: $TEMPLATE_FILE is missing.${NC}"
    exit 1
fi

# With more than one admin account, they'd all get overwritten with the same one
admin_count=$(count_admin_accounts < "$TEMPLATE_FILE")
if [ "$admin_count" -ne 1 ]; then
    echo -e "${RED}Error: $TEMPLATE_FILE has $admin_count admin accounts; this script only supports managing exactly one.${NC}"
    echo "Edit the extra accounts in by hand after generating, or remove them from the template first."
    exit 1
fi

# Both env vars set (e.g. CI): use them directly, no prompts
if [ -n "$ADGUARD_SETUP_USER" ] && [ -n "$ADGUARD_SETUP_PASSWORD" ]; then
    admin_user="$ADGUARD_SETUP_USER"
    admin_password="$ADGUARD_SETUP_PASSWORD"
# Only one set: likely a typo'd var name, not a deliberate non-interactive run
elif [ -n "$ADGUARD_SETUP_USER" ] || [ -n "$ADGUARD_SETUP_PASSWORD" ]; then
    echo -e "${RED}Error: set both ADGUARD_SETUP_USER and ADGUARD_SETUP_PASSWORD, or neither (only one is set).${NC}"
    exit 1
# Neither set: fall back to interactive prompts
else
    read -r -p "AdGuard admin username: " admin_user
    read -r -s -p "AdGuard admin password: " admin_password
    echo
    read -r -s -p "Confirm password: " admin_password_confirm
    echo
    if [ "$admin_password" != "$admin_password_confirm" ]; then
        echo -e "${RED}Error: passwords didn't match.${NC}"
        exit 1
    fi
fi

# Empty username or password not allowed
if [ -z "$admin_user" ] || [ -z "$admin_password" ]; then
    echo "Error: username and password can't be empty."
    exit 1
fi

# AdGuard's own install API rejects anything shorter than 8 characters
if [ "${#admin_password}" -lt 8 ]; then
    echo "Error: password must be at least 8 characters (AdGuard's own requirement)."
    exit 1
fi

# Split-horizon DNS for *.home.arpa (see SERVICES.md), only if nginx is in this deployment.
LAN_SUBNET=$(echo "$compose_json" | jq -r '.services.nginx.environment.LAN_SUBNET // empty')
VPN_SUBNET=$(echo "$compose_json" | jq -r '.services.nginx.environment.VPN_SUBNET // empty')
USER_RULES_BLOCK=""

# LAN_SUBNET is only set on nginx's environment block, so its presence means nginx is deployed
# This whole block only fills in USER_RULES_BLOCK
if [ -n "$LAN_SUBNET" ]; then

    # ADGUARD_LAN_IP overrides autodetection (e.g. CI, which is never on $LAN_SUBNET)
    #         Overwrite       Get the real host's IP on the LAN_SUBNET
    LAN_IP="${ADGUARD_LAN_IP:-$(ip -4 route show scope link | awk -v subnet="$LAN_SUBNET" '$1 == subnet { for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }')}"

    # If LAN_IP is empty, an error occurred
    if [ -z "$LAN_IP" ]; then
        echo -e "${RED}Error: couldn't detect this host's IP on $LAN_SUBNET.${NC}"
        echo "Set ADGUARD_LAN_IP=<ip> to override (e.g. this host isn't directly on that subnet, or you're in CI)."
        exit 1
    fi

    # ADGUARD_VPN_IP overrides autodetection (e.g. CI, or wg0 not up yet)
    #         Overwrite       Get this host's tunnel IP from wg0
    VPN_IP="${ADGUARD_VPN_IP:-$(ip -4 -o addr show dev wg0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)}"    # `|| true`: don't let set -e kill the script before the check below can

    # If VPN_IP is empty, an error occurred
    if [ -z "$VPN_IP" ]; then
        echo -e "${RED}Error: couldn't detect this host's WireGuard tunnel IP (wg0).${NC}"
        echo "Set ADGUARD_VPN_IP=<ip> to override (e.g. wg0 isn't up on this host yet, or you're in CI)."
        exit 1
    fi

    # Rebuild user_rules: from scratch every run, in 4 steps:
    # 1. Load whatever's already there
    # 2. Re-emit the nginx-managed hosts fresh, diffed against their old value for display
    # 3. Copy through every other rule unchanged. Nothing is lost or duplicated
    # 4. Serialize the result back into a user_rules: YAML block

    # One pair of rules (lan/vpn) per nginx-proxied service. The file names are the only place these exist
    SERVICE_HOSTS=()
    for f in "$SCRIPT_DIR/nginx/templates/conf.d/"*.conf.template; do
        name=$(basename "$f" .conf.template)
        [ "$name" = "default" ] && continue
        SERVICE_HOSTS+=("$name.home.arpa")
    done

    # Step 1: load the template's user_rules: list as plain strings (undoing AdGuard's quoting)
    tmpl_rules=()
    while IFS= read -r line; do
        rule="${line#*- }"
        if [[ "$rule" == \'*\' ]]; then
            rule="${rule#\'}"
            rule="${rule%\'}"
            rule="${rule//\'\'/\'}"
        fi
        tmpl_rules+=("$rule")
    done < <(user_rules_block < "$TEMPLATE_FILE" | tail -n +2)

    # Helpers for steps 2/3 below
    # A managed rule always looks like: ||<host>^$dnsrewrite=NOERROR;A;<ip>,client=<cidr>
    rule_domain() {
        local r="$1"
        [[ "$r" =~ ^\|\|([^^]+)\^\$dnsrewrite= ]] && printf '%s' "${BASH_REMATCH[1]}"
        return 0
    }
    rule_ip() {
        local r="$1"
        [[ "$r" =~ \$dnsrewrite=NOERROR\;A\;([^,]+), ]] && printf '%s' "${BASH_REMATCH[1]}"
        return 0
    }
    is_managed_host() {
        local d="$1" h
        for h in "${SERVICE_HOSTS[@]}"; do [ "$h" = "$d" ] && return 0; done
        return 1
    }
    old_rule_for() {
        local host="$1" cidr="$2" r
        for r in "${tmpl_rules[@]}"; do
            if [ "$(rule_domain "$r")" = "$host" ] && [[ "$r" == *",client=$cidr" ]]; then
                printf '%s' "$r"
                return 0
            fi
        done
        return 0
    }

    # Step 2: re-emit the nginx-managed rules fresh, diffed against their old value for display
    echo "DNS rewrites for *.home.arpa (managed by nginx, split by zone):"
    final_rules=()
    emit_rule() {
        local host="$1" zone="$2" cidr="$3" ip="$4" old_rule old_ip
        old_rule="$(old_rule_for "$host" "$cidr")"
        old_ip="$(rule_ip "$old_rule")"
        if [ -z "$old_ip" ]; then
            echo "  + $host  $zone -> $ip (new)"
        elif [ "$old_ip" = "$ip" ]; then
            echo "    $host  $zone -> $ip (unchanged)"
        else
            echo "  ~ $host  $zone -> $ip (was $old_ip)"
        fi
        final_rules+=("||$host^\$dnsrewrite=NOERROR;A;$ip,client=$cidr")
    }
    for h in "${SERVICE_HOSTS[@]}"; do
        emit_rule "$h" lan "$LAN_SUBNET" "$LAN_IP"
        emit_rule "$h" vpn "$VPN_SUBNET" "$VPN_IP"
    done

    # Step 3: copy through every other rule unchanged
    kept_any="false"
    for r in "${tmpl_rules[@]}"; do
        d="$(rule_domain "$r")"
        if [ -z "$d" ] || ! is_managed_host "$d"; then
            [ "$kept_any" = "false" ] && echo "Other existing custom rules, kept as-is:"
            kept_any="true"
            echo "    $r"
            final_rules+=("$r")
        fi
    done

    # Step 4: serialize final_rules back into a user_rules: YAML block, quoted like AdGuard would
    USER_RULES_BLOCK="user_rules:"$'\n'
    for r in "${final_rules[@]}"; do
        USER_RULES_BLOCK+="  - '$r'"$'\n'
    done

    # Ask for confirmation unless running non-interactively (CI sets both env vars)
    if [ -z "$ADGUARD_SETUP_USER" ] || [ -z "$ADGUARD_SETUP_PASSWORD" ]; then
        read -r -p "Apply these DNS rewrites? [y/N] " confirm_rewrites
        if [ "$confirm_rewrites" != "y" ] && [ "$confirm_rewrites" != "Y" ]; then
            echo "Aborted, nothing changed."
            exit 1
        fi
    fi
fi

# GENERATE CONFIG VIA THROWAWAY CONTAINER
# Unique per PID, so two runs at once don't collide on the container name
tmp_name="adguard-config-gen-$$"
# Runs on every exit path. Removes the throwaway container, and restarts adguard if this script stopped it
cleanup() {
    docker rm -f "$tmp_name" > /dev/null 2>&1 || true
    if [ "$ADGUARD_WAS_RUNNING" = "true" ]; then
        echo -e "${YELLOW}-> Restarting adguard...${NC}"
        docker compose -f "$COMPOSE_FILE" start adguard || echo -e "${RED}Error: failed to restart adguard. Start it manually with 'docker compose start adguard'.${NC}"
    fi
}
trap cleanup EXIT

echo -e "${YELLOW}-> Starting a throwaway AdGuard container to generate the config...${NC}"
# Runs a real AdGuard so its own binary produces the password hash, not a reimplementation
docker run -d --name "$tmp_name" "$IMAGE" > /dev/null

# Polling until the container is ready
ready="false"
for _ in $(seq 1 12); do
    if docker exec "$tmp_name" wget -qO /dev/null http://127.0.0.1:3000/ 2>/dev/null; then
        ready="true"
        break
    fi
    sleep 1
done
if [ "$ready" != "true" ]; then
    echo -e "${RED}Error: the throwaway container never became ready.${NC}"
    exit 1
fi

# Sets the admin account on the throwaway container, via AdGuard's own setup-wizard API
payload=$(jq -n --arg u "$admin_user" --arg p "$admin_password" \
    '{web: {ip: "0.0.0.0", port: 80}, dns: {ip: "0.0.0.0", port: 53}, username: $u, password: $p}')
response=$(docker exec "$tmp_name" wget -qO- \
    --header='Content-Type: application/json' \
    --post-data="$payload" \
    http://127.0.0.1:3000/control/install/configure)

if [ "$response" != "OK" ]; then
    echo -e "${RED}Error: the throwaway container's install API didn't confirm success (got: $response).${NC}"
    exit 1
fi

# The real adguard container only reads its config at startup
# It must be stopped for a regenerate to take effect
ADGUARD_WAS_RUNNING="false"
if [ "$FORCE" = "true" ]; then
    if ! adguard_id=$(docker compose -f "$COMPOSE_FILE" ps -q adguard); then
        echo -e "${RED}Error: 'docker compose ps' failed. Check .env is fully filled in.${NC}"
        exit 1
    fi
    if [ -n "$adguard_id" ]; then
        ADGUARD_WAS_RUNNING="true"
        echo -e "${YELLOW}-> Stopping the running adguard container so the new config takes effect...${NC}"
        docker compose -f "$COMPOSE_FILE" stop adguard
    fi
fi

# Create the confing and working (blocklists/query/log/stats) directories with your user
mkdir -p "$OUT_DIR" "$WORK_DIR"

# Read back the users block AdGuard itself wrote (with the real password hash)
users_live=$(docker exec "$tmp_name" cat /opt/adguardhome/conf/AdGuardHome.yaml | users_block)
if [ -z "$users_live" ]; then
    echo -e "${RED}Error: couldn't read the users: block back from the throwaway container.${NC}"
    exit 1
fi
# These 2 lines are all we need, the throwaway container itself is discarded on exit
name_line=$(printf '%s\n' "$users_live" | grep '^  - name:')
password_line=$(printf '%s\n' "$users_live" | grep '^    password:')

# The template has everything else (blocklists, filters...)
# Only account/password and the user_rules are computed dynamically and spliced in
# Substitution 1: swap the real name/password from above
AWK_PROGRAM='
/^users:/ { f = 1 }                              # entering the users: block
f && !/^users:/ && /^[^ ]/ { f = 0 }             # left it: next top-level key
f && /^  - name:/ { print ENVIRON["NAME_LINE"]; name_subs++; next }
f && /^    password:/ { print ENVIRON["PASSWORD_LINE"]; password_subs++; next }
'
if [ -n "$LAN_SUBNET" ]; then
    # Substitution 2: swap the whole user_rules: block for the one computed above
    AWK_PROGRAM="$AWK_PROGRAM"'
/^user_rules:/ { printf "%s", ENVIRON["USER_RULES_BLOCK"]; u = 1; next }
u && /^[^ ]/ { u = 0 }                           # left it: next top-level key
u { next }
'
fi

# Fails loudly if these substitutions stop matching anything
AWK_PROGRAM="$AWK_PROGRAM"'
{ print }
END {
    if (name_subs != 1 || password_subs != 1) {
        print "expected exactly 1 name/password substitution, got " name_subs "/" password_subs > "/dev/stderr"
        exit 1
    }
}
'

# Written to a temp file first: a failed --force regenerate must leave the live config alone,
OUT_TMP="$OUT_FILE.tmp"
if ! NAME_LINE="$name_line" PASSWORD_LINE="$password_line" USER_RULES_BLOCK="$USER_RULES_BLOCK" \
    awk "$AWK_PROGRAM" "$TEMPLATE_FILE" > "$OUT_TMP"; then
    echo -e "${RED}Error: couldn't substitute the admin name/password into $TEMPLATE_FILE. Its format may have changed.${NC}"
    rm -f "$OUT_TMP"
    exit 1
fi
cat "$OUT_TMP" > "$OUT_FILE"
rm -f "$OUT_TMP"

# Read/write for your user only
chmod 600 "$OUT_FILE"
echo -e "${GREEN}-> Generated $OUT_FILE from your tracked template, with a fresh password hash.${NC}"

# Restarting adguard (if this script stopped it) is handled by the cleanup trap above,

echo "   Upstream DNS and blocklists (see SERVICES.md) are still set from AdGuard's own web UI after it's up."
if [ -n "$LAN_SUBNET" ]; then
    echo "   DNS for *.home.arpa was set automatically above, for both LAN and VPN clients (nginx is in use)."
fi
echo "   Run ./services/snapshot-adguard-config.sh afterwards to track those changes in git (password redacted automatically)."
