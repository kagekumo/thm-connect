#!/bin/bash
# Conectar TryHackMe dentro del namespace thm.
# Uso: bash ./thm-connect.sh; thm.ovpn debe estar junto al script.

set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Cambiar una sola vez si se utiliza este script en otro equipo.
readonly WAN_IF="eno1"
readonly NS="thm"
readonly HOST_IF="veth-host"
readonly NS_IF="veth-thm"
readonly SUBNET="10.200.1.0/24"
readonly HOST_ADDR="10.200.1.1/24"
readonly NS_ADDR="10.200.1.2/24"
readonly GATEWAY="10.200.1.1"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
trap 'printf "Error: ha fallado el paso de la línea %s. Revisa el mensaje anterior.\n" "$LINENO" >&2' ERR
trap 'exit 130' INT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
readonly CONFIG="$SCRIPT_DIR/thm.ovpn"

[[ -f "$CONFIG" && -r "$CONFIG" ]] || die "falta thm.ovpn o no se puede leer en $SCRIPT_DIR."
for cmd in ip iptables sysctl openvpn flock stat readlink grep; do
    command -v "$cmd" >/dev/null || die "falta el comando $cmd."
done

if (( EUID != 0 )); then
    command -v sudo >/dev/null || die "falta sudo."
    exec sudo -- /bin/bash "$SCRIPT_PATH"
fi

# Un directorio de root evita que otro usuario sustituya el archivo del bloqueo.
readonly LOCK_DIR="/run/thm-connect"
[[ ! -L "$LOCK_DIR" ]] || die "la ruta de bloqueo es un enlace simbólico."
if [[ ! -e "$LOCK_DIR" ]]; then
    mkdir -m 700 -- "$LOCK_DIR"
fi
[[ -d "$LOCK_DIR" && "$(stat -c %u "$LOCK_DIR")" == 0 ]] || die "directorio de bloqueo no válido."
chmod 700 -- "$LOCK_DIR"
[[ ! -L "$LOCK_DIR/session.lock" ]] || die "el archivo de bloqueo es un enlace simbólico."
if [[ -e "$LOCK_DIR/session.lock" ]]; then
    [[ -f "$LOCK_DIR/session.lock" && "$(stat -c %u "$LOCK_DIR/session.lock")" == 0 ]] || die "archivo de bloqueo no válido."
fi
exec 9<>"$LOCK_DIR/session.lock"
flock -n 9 || die "ya hay otra ejecución de este script activa."

ip link show dev "$WAN_IF" >/dev/null || die "no existe la interfaz $WAN_IF."
# Estas consultas deben funcionar antes de modificar la red.
ip netns list >/dev/null
iptables -w 5 -t nat -S POSTROUTING >/dev/null
iptables -w 5 -t filter -S FORWARD >/dev/null

namespaces="$(ip netns list)"
if ! grep -qE "^${NS}([[:space:]]|$)" <<< "$namespaces"; then
    ip netns add "$NS"
fi

# Detectar también una VPN iniciada con la versión anterior del script.
pids="$(ip netns pids "$NS")"
for pid in $pids; do
    if exe="$(readlink "/proc/$pid/exe")"; then
        [[ "${exe##*/}" != openvpn ]] || die "ya hay OpenVPN ejecutándose dentro de $NS."
    fi
done

host_exists=false
peer_exists=false
ip link show dev "$HOST_IF" >/dev/null 2>&1 && host_exists=true
ip -n "$NS" link show dev "$NS_IF" >/dev/null 2>&1 && peer_exists=true

if ! "$host_exists" && ! "$peer_exists"; then
    if ip link show dev "$NS_IF" >/dev/null 2>&1; then
        die "el nombre $NS_IF ya está ocupado en el equipo."
    fi
    ip link add "$HOST_IF" type veth peer name "$NS_IF"
    ip link set "$NS_IF" netns "$NS"
elif "$host_exists" && ! "$peer_exists"; then
    # Recuperar una ejecución interrumpida antes de mover el extremo al namespace.
    ip link show dev "$NS_IF" >/dev/null || die "existe $HOST_IF, pero falta su pareja $NS_IF."
    host_line="$(ip -d -o link show dev "$HOST_IF")"
    peer_line="$(ip -d -o link show dev "$NS_IF")"
    [[ "$host_line" == *" veth "* && "$peer_line" == *" veth "* ]] || die "las interfaces existentes no son veth."
    [[ "$host_line" =~ ^([0-9]+):[^@]+@if([0-9]+): ]] || die "no se puede identificar $HOST_IF."
    host_index="${BASH_REMATCH[1]}"; peer_index="${BASH_REMATCH[2]}"
    [[ "$peer_line" =~ ^([0-9]+):[^@]+@if([0-9]+): ]] || die "no se puede identificar $NS_IF."
    [[ "${BASH_REMATCH[1]}" == "$peer_index" && "${BASH_REMATCH[2]}" == "$host_index" ]] || die "las interfaces no forman la pareja esperada."
    ip link set "$NS_IF" netns "$NS"
elif ! "$host_exists" && "$peer_exists"; then
    die "existe $NS_IF en $NS, pero falta $HOST_IF."
fi

# No modificar una interfaz ajena que coincida en nombre.
host_line="$(ip -d -o link show dev "$HOST_IF")"
peer_line="$(ip -n "$NS" -d -o link show dev "$NS_IF")"
[[ "$host_line" == *" veth "* && "$peer_line" == *" veth "* ]] || die "las interfaces existentes no son veth."
[[ "$host_line" =~ ^([0-9]+):[^@]+@if([0-9]+): ]] || die "no se puede identificar $HOST_IF."
host_index="${BASH_REMATCH[1]}"; peer_index="${BASH_REMATCH[2]}"
[[ "$peer_line" =~ ^([0-9]+):[^@]+@if([0-9]+): ]] || die "no se puede identificar $NS_IF."
[[ "${BASH_REMATCH[1]}" == "$peer_index" && "${BASH_REMATCH[2]}" == "$host_index" ]] || die "las interfaces no forman la pareja esperada."

ensure_address() {
    local scope="$1" iface="$2" expected="$3" output
    local -a ipcmd=(ip)
    [[ -z "$scope" ]] || ipcmd+=(-n "$scope")
    output="$("${ipcmd[@]}" -o -4 addr show dev "$iface")"
    if grep -Fq " inet $expected " <<< "$output"; then return; fi
    [[ -z "$output" ]] || die "la interfaz ya tiene una dirección IPv4 diferente de $expected."
    "${ipcmd[@]}" addr add "$expected" dev "$iface"
}

routes="$(ip -4 route show exact "$SUBNET")"
while IFS= read -r route; do
    [[ -z "$route" || " $route " == *" dev $HOST_IF "* ]] || die "la red $SUBNET ya se utiliza en otra interfaz."
done <<< "$routes"

ensure_address "" "$HOST_IF" "$HOST_ADDR"
ensure_address "$NS" "$NS_IF" "$NS_ADDR"
ip link set "$HOST_IF" up
ip -n "$NS" link set "$NS_IF" up
ip -n "$NS" link set lo up

default_route="$(ip -n "$NS" -4 route show default)"
if [[ -z "$default_route" ]]; then
    ip -n "$NS" route add default via "$GATEWAY" dev "$NS_IF"
else
    # ip puede añadir espacios, métricas o el protocolo a una ruta válida.
    read -r -a route_fields <<< "$default_route"
    if [[ "$default_route" == *$'\n'* ||
          "${route_fields[0]:-}" != default ||
          "${route_fields[1]:-}" != via || "${route_fields[2]:-}" != "$GATEWAY" ||
          "${route_fields[3]:-}" != dev || "${route_fields[4]:-}" != "$NS_IF" ]]; then
        die "el namespace ya tiene una ruta por defecto distinta; no se ha reemplazado."
    fi
fi

# Contar y retirar únicamente coincidencias exactas de una regla conocida.
rule_count() {
    local table="$1" chain="$2" listing line expected count=0
    shift 2
    expected="-A $chain $*"
    listing="$(iptables -w 5 -t "$table" -S "$chain")" || return
    while IFS= read -r line; do
        line="${line/--state ESTABLISHED,RELATED/--state RELATED,ESTABLISHED}"
        if [[ "$line" == "$expected" ]]; then count=$((count + 1)); fi
    done <<< "$listing"
    printf '%s\n' "$count"
}

ensure_rule() {
    local table="$1" chain="$2" count
    shift 2
    count="$(rule_count "$table" "$chain" "$@")"
    if (( count == 0 )); then
        iptables -w 5 -t "$table" -A "$chain" "$@"
    else
        while (( count > 1 )); do
            iptables -w 5 -t "$table" -D "$chain" "$@"
            count=$((count - 1))
        done
    fi
}

remove_old_rule() {
    local count
    count="$(rule_count filter FORWARD "$@")"
    while (( count > 0 )); do
        iptables -w 5 -t filter -D FORWARD "$@"
        count=$((count - 1))
    done
}

ensure_rule nat POSTROUTING -s "$SUBNET" -o "$WAN_IF" -j MASQUERADE
# Limitar el reenvío a la red del namespace, manteniendo las respuestas establecidas.
ensure_rule filter FORWARD -d "$SUBNET" -i "$WAN_IF" -o "$HOST_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
ensure_rule filter FORWARD -s "$SUBNET" -i "$HOST_IF" -o "$WAN_IF" -j ACCEPT
# Migrar las dos reglas más amplias de la versión anterior, sin borrar otras reglas.
remove_old_rule -i "$WAN_IF" -o "$HOST_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
remove_old_rule -i "$HOST_IF" -o "$WAN_IF" -j ACCEPT

if [[ "$(sysctl -n net.ipv4.ip_forward)" != 1 ]]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

printf '[✓] Namespace listo. Conectando VPN...\n'
# Mantener el bloqueo mientras OpenVPN esté activo. Ctrl+C detiene la conexión.
ip netns exec "$NS" openvpn --cd "$SCRIPT_DIR" --config "$CONFIG"
