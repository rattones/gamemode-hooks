#!/usr/bin/env bash
# Roda o ~/.local/bin/monitor preso ao jogo que ativou o GameMode.
# Chamado por gamemode-start.sh (start) e gamemode-end.sh (stop).
#
#   gamemode-monitor.sh start   # descobre o PID do jogo e coleta ate ele sair
#   gamemode-monitor.sh stop    # encerra a coleta (o monitor fecha os CSVs)
#
# O GameMode nao passa o PID para os scripts custom, entao ele vem do D-Bus
# (ListGames). Com "gamemoderun %command%" o LD_PRELOAD registra tambem os
# wrappers da Steam (reaper, pressure-vessel...), e no Proton o jogo e filho
# deles. Por isso olhamos os registrados E os descendentes, e escolhemos o de
# maior RSS: os wrappers ocupam poucos MiB, o jogo ocupa centenas.
set -u
export LC_ALL=C

CONF="${HOME}/.config/gamemode-tweaks.conf"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

: "${RUN_MONITOR:=1}"
: "${MONITOR_MIN_RSS_MB:=300}"
: "${MONITOR_WAIT_S:=180}"
: "${MONITOR_ARGS:=-q}"
: "${MONITOR_PERF:=auto}"

# Onde esta o monitor: o da configuracao (o install.sh grava o que achou), o de
# ~/.local/bin (instalacao padrao) ou o do PATH (instalacao --system).
if [ -z "${MONITOR_BIN:-}" ] || [ ! -x "$MONITOR_BIN" ]; then
    MONITOR_BIN="${HOME}/.local/bin/monitor"
    [ -x "$MONITOR_BIN" ] || MONITOR_BIN="$(command -v monitor 2>/dev/null || true)"
fi
LOG_DIR="${MONITOR_LOG_DIR:-$HOME/.monitor/log}"
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/gamemode-monitor.pid"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -a GameMode "$@"; }

registered_pids() {
    busctl --user call com.feralinteractive.GameMode /com/feralinteractive/GameMode \
        com.feralinteractive.GameMode ListGames 2>/dev/null \
        | grep -oE '[0-9]+ "' | tr -d ' "'
}

# Imprime "pid rss_kib comm" do maior processo entre os registrados e seus descendentes.
biggest_game_proc() {
    local roots
    roots=$(registered_pids | paste -sd,)
    [ -n "$roots" ] || return 1
    ps -eo pid=,ppid=,rss=,comm= | awk -v roots="$roots" '
    {
        pid[NR] = $1; ppid[$1] = $2; rss[$1] = $3
        c = $4; for (i = 5; i <= NF; i++) c = c " " $i; comm[$1] = c
    }
    END {
        n = split(roots, r, ","); for (i = 1; i <= n; i++) root[r[i]] = 1
        for (k in pid) {
            p = pid[k]; q = p
            # sobe a arvore ate achar um registrado (ou o init)
            for (d = 0; d < 64 && q > 1; d++) { if (q in root) break; q = ppid[q] }
            if (!(q in root)) continue
            if (rss[p] > best) { best = rss[p]; bp = p }
        }
        if (bp != "") print bp, best, comm[bp]
    }'
}

stop_monitor() {
    [ -r "$PIDFILE" ] || return 0
    local wpid
    wpid=$(cat "$PIDFILE" 2>/dev/null)
    # So mata se o PID ainda e deste script (o PID pode ter sido reusado).
    if [ -n "$wpid" ] && grep -q gamemode-monitor "/proc/$wpid/cmdline" 2>/dev/null; then
        kill -TERM "$wpid" 2>/dev/null
    fi
    return 0
}

watch() {
    local mon_pid="" game_pid="" found line rss_kib comm name out

    on_term() {
        [ -n "$mon_pid" ] && kill -TERM "$mon_pid" 2>/dev/null && wait "$mon_pid" 2>/dev/null
        rm -f "$PIDFILE"
        exit 0
    }
    trap on_term TERM INT

    # Espera o jogo "crescer": no inicio so os wrappers estao registrados.
    local deadline=$(( SECONDS + MONITOR_WAIT_S ))
    found=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        line=$(biggest_game_proc)
        if [ -z "$line" ] && [ "$SECONDS" -gt 15 ]; then
            # Nenhum jogo registrado: foi o "modo-jogo on" manual ou um
            # start/end curto do boot da Steam. Nada a monitorar.
            rm -f "$PIDFILE"; exit 0
        fi
        if [ -n "$line" ]; then
            found="$line"
            rss_kib=${line#* }; rss_kib=${rss_kib%% *}
            [ "$rss_kib" -ge $(( MONITOR_MIN_RSS_MB * 1024 )) ] && break
        fi
        sleep 2 & wait $!
    done
    [ -n "$found" ] || { rm -f "$PIDFILE"; exit 0; }

    game_pid=${found%% *}
    comm=${found#* }; comm=${comm#* }
    name=$(printf '%s' "$comm" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')
    mkdir -p "$LOG_DIR"
    out="$LOG_DIR/${name:-jogo}-$(date +%Y%m%d-%H%M%S).csv"

    # -P (perf) so quando ele pode rodar: o sysctl que o libera nao sobrevive
    # ao reboot, e um -P recusado derrubaria a coleta inteira do jogo.
    local perf_arg=""
    if [ "$MONITOR_PERF" = 1 ] || { [ "$MONITOR_PERF" = auto ] && command -v perf >/dev/null 2>&1 \
         && [ "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 4)" -le 1 ]; }; then
        perf_arg="-P"
    fi

    # shellcheck disable=SC2086
    "$MONITOR_BIN" all -f "pid:$game_pid" -o "$out" $MONITOR_ARGS $perf_arg \
        > "${out%.csv}.log" 2>&1 &
    mon_pid=$!
    notify "Monitor ligado" "$comm (PID $game_pid)
${out}"

    # Coleta enquanto o jogo e o monitor estiverem vivos.
    while kill -0 "$game_pid" 2>/dev/null && kill -0 "$mon_pid" 2>/dev/null; do
        sleep 2 & wait $!
    done
    on_term
}

case "${1:-}" in
    start)
        [ "$RUN_MONITOR" = 1 ] || exit 0
        [ -x "$MONITOR_BIN" ] || exit 0
        # Um monitor por jogo: o start dispara varias vezes no boot da Steam.
        if [ -r "$PIDFILE" ] && grep -q gamemode-monitor "/proc/$(cat "$PIDFILE")/cmdline" 2>/dev/null; then
            exit 0
        fi
        # Desacoplado: o GameMode espera o script custom terminar (com timeout).
        setsid -f "$0" __watch </dev/null >/dev/null 2>&1
        ;;
    __watch)
        # Dois starts quase juntos: so o primeiro a pegar o lock segue.
        exec 9>"${PIDFILE}.lock"
        flock -n 9 || exit 0
        echo $$ > "$PIDFILE"
        watch
        ;;
    stop)
        stop_monitor
        ;;
    *)
        echo "uso: ${0##*/} start|stop" >&2; exit 2 ;;
esac
exit 0
