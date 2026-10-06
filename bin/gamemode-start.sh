#!/usr/bin/env bash
# Executado pelo GameMode ao iniciar um jogo.
# Poe o jogo no monitor escolhido, desliga os demais e destrava energia. Cada
# ajuste depende de um recurso (platform_profile, NVIDIA, X11) e e pulado quando
# ele nao existe; as opcoes vem de ~/.config/gamemode-tweaks.conf, gerado pelo
# install.sh a partir do hardware detectado.
set -u

# Locale pt_BR faz o awk ler "59.94" como 59 e imprimir "59,00", que o xrandr
# rejeita. C garante ponto decimal na leitura e na escrita.
export LC_ALL=C

CONF="${HOME}/.config/gamemode-tweaks.conf"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

# Padroes neutros: sem configuracao, nada que dependa do hardware desta
# maquina e aplicado as cegas (sem monitor escolhido, nada de monitores).
: "${GAME_MONITOR:=}"
: "${SINGLE_MONITOR:=1}"
: "${GAME_REFRESH:=auto}"
: "${SET_PLATFORM_PROFILE:=1}"
: "${PERF_PROFILE:=performance}"
: "${SET_POWERMIZER:=1}"
: "${NOTIFY_VRAM:=1}"
: "${VRAM_WARN_PCT:=78}"
: "${PAUSE_SERVICES:=}"

# Raiz do ACPI no sysfs (so os testes trocam).
ACPI_DIR="${GH_ACPI_DIR:-/sys/firmware/acpi}"

# Quem grava o perfil como root, via "sudo -n" (regra no sudoers). O nome
# antigo, legion-profile, continua aceito para instalacoes anteriores.
if [ -z "${PROFILE_HELPER:-}" ]; then
    PROFILE_HELPER=/usr/local/bin/platform-profile
    [ -x "$PROFILE_HELPER" ] || [ ! -x /usr/local/bin/legion-profile ] \
        || PROFILE_HELPER=/usr/local/bin/legion-profile
fi

STATE="${XDG_RUNTIME_DIR:-/tmp}/gamemode-tweaks.state"

# O GameMode dispara start/end varias vezes durante o boot do Steam (processos
# curtos de inspecao). Se ja capturamos o estado original, preservamos aquele
# valor -- reler agora devolveria o valor JA modificado e perderiamos o original.
PREV_PROFILE=""; PREV_PM=""; RESTORE_CMD=""; APPLIED_MONITOR=""; PAUSED_SERVICES=""; PREV_HELPER=""
# shellcheck disable=SC1090
[ -r "$STATE" ] && . "$STATE"

save_state() {
    : > "$STATE"
    [ -n "$PREV_PROFILE" ]   && echo "PREV_PROFILE=$PREV_PROFILE"     >> "$STATE"
    [ -n "$PREV_PM" ]        && echo "PREV_PM=$PREV_PM"               >> "$STATE"
    [ -n "$RESTORE_CMD" ]    && printf 'RESTORE_CMD=%q\n' "$RESTORE_CMD" >> "$STATE"
    [ -n "$APPLIED_MONITOR" ] && echo "APPLIED_MONITOR=$APPLIED_MONITOR" >> "$STATE"
    [ -n "$PAUSED_SERVICES" ] && printf 'PAUSED_SERVICES=%q\n' "$PAUSED_SERVICES" >> "$STATE"
    [ -n "$PREV_HELPER" ]    && printf 'PREV_HELPER=%q\n' "$PREV_HELPER" >> "$STATE"
    return 0
}

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -a GameMode "$@"; }

# Monta o comando xrandr que reproduz o layout atual, para o end.sh desfazer.
capture_layout() {
    xrandr --query | awk '
    function flush(  s) {
        if (out == "") return
        if (geo != "") {
            split(geo, g, "+"); s = " --output " out " --mode " g[1] " --pos " g[2] "x" g[3]
            if (rate != "") s = s " --rate " rate
            if (prim) s = s " --primary"
        } else { s = " --output " out " --off" }
        cmd = cmd s; out = ""
    }
    / connected/ {
        flush()
        out = $1; prim = ($3 == "primary"); geo = ""; rate = ""
        for (i = 3; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+[-0-9]+\+[-0-9]+$/) { geo = $i; break }
        next
    }
    /^[ \t]+[0-9]+x[0-9]+/ {
        if (out == "" || geo == "") next
        for (i = 2; i <= NF; i++) if ($i ~ /\*/) { r = $i; gsub(/[*+]/, "", r); rate = r }
        next
    }
    END { flush(); if (cmd != "") print "xrandr" cmd }'
}

best_mode() { xrandr --query | awk -v m="$1" '$1==m&&/ connected/{f=1;next} /^[A-Za-z]/{f=0} f&&/^[ \t]+[0-9]+x[0-9]+/{print $1; exit}'; }
best_rate() {
    xrandr --query | awk -v m="$1" -v md="$2" '
    $1==m&&/ connected/{f=1;next} /^[A-Za-z]/{f=0}
    f&&$1==md{for(i=2;i<=NF;i++){r=$i;gsub(/[*+]/,"",r); if(r+0>b) b=r+0}}
    END{if(b>0) printf "%.2f", b}'
}

# --- Perfil de energia da plataforma (ACPI platform_profile) ---
# Os nomes variam por fabricante (performance, balanced-performance, quiet...):
# so aplica PERF_PROFILE se ele estiver entre os que o firmware oferece.
if [ "$SET_PLATFORM_PROFILE" = 1 ] && [ -r "$ACPI_DIR/platform_profile" ] \
   && grep -qw -- "$PERF_PROFILE" "$ACPI_DIR/platform_profile_choices" 2>/dev/null; then
    if [ -z "$PREV_PROFILE" ]; then
        PREV_PROFILE=$(cat "$ACPI_DIR/platform_profile" 2>/dev/null)
        PREV_HELPER="$PROFILE_HELPER"
    fi
    sudo -n "$PROFILE_HELPER" "$PERF_PROFILE" 2>/dev/null || { PREV_PROFILE=""; PREV_HELPER=""; }
fi

# --- PowerMizer (so NVIDIA): a secao [gpu] do GameMode procura a placa em
#     card0 e falha onde a NVIDIA e outro cardN (comum com iGPU ou MUX). Via
#     nvidia-settings funciona como usuario, sem root. 1 = max performance ---
if [ "$SET_POWERMIZER" = 1 ] && command -v nvidia-settings >/dev/null 2>&1; then
    if [ -z "$PREV_PM" ]; then
        PREV_PM=$(nvidia-settings -q '[gpu:0]/GPUPowerMizerMode' -t 2>/dev/null | head -1)
    fi
    nvidia-settings -a '[gpu:0]/GPUPowerMizerMode=1' >/dev/null 2>&1 || PREV_PM=""
fi

# --- Monitores: joga no GAME_MONITOR, desliga o resto ---
# So no X11 (o xrandr nao controla saidas no Wayland) e so com um monitor
# escolhido: sem GAME_MONITOR, o layout fica como esta.
if [ "$SINGLE_MONITOR" = 1 ] && [ -n "$GAME_MONITOR" ] && [ "$APPLIED_MONITOR" != "1" ] \
   && [ "${XDG_SESSION_TYPE:-x11}" != wayland ] \
   && xrandr --query 2>/dev/null | grep -q "^${GAME_MONITOR} connected"; then
    RESTORE_CMD=$(capture_layout)
    if [ -n "$RESTORE_CMD" ]; then
        mode=$(best_mode "$GAME_MONITOR")
        if [ "$GAME_REFRESH" = auto ]; then rate=$(best_rate "$GAME_MONITOR" "$mode"); else rate="$GAME_REFRESH"; fi

        args="--output $GAME_MONITOR --mode $mode --pos 0x0 --primary"
        [ -n "$rate" ] && args="$args --rate $rate"
        while read -r o; do
            [ "$o" = "$GAME_MONITOR" ] || args="$args --output $o --off"
        done < <(xrandr --query | awk '/ connected/{print $1}')

        # shellcheck disable=SC2086
        if xrandr $args 2>/dev/null; then
            APPLIED_MONITOR=1
        else
            eval "$RESTORE_CMD" 2>/dev/null
            RESTORE_CMD=""
            notify -u critical "GameMode" "Nao consegui trocar os monitores; layout mantido."
        fi
    fi
fi

# --- Servicos de usuario que atrapalham o jogo (ex.: um speedtest periodico
#     que satura o Wi-Fi). So para os que estao ativos e anota quais foram,
#     para o end.sh religar apenas esses ---
for svc in $PAUSE_SERVICES; do
    if systemctl --user is-active --quiet "$svc" \
       && systemctl --user stop "$svc" 2>/dev/null; then
        PAUSED_SERVICES="${PAUSED_SERVICES:+$PAUSED_SERVICES }$svc"
    fi
done

save_state

# --- Monitor de GPU/VRAM/disco preso ao PID do jogo (roda em background) ---
"${HOME}/.local/bin/gamemode-monitor.sh" start

# --- Relata a VRAM livre resultante ---
# Alerta quando a VRAM livre fica abaixo de VRAM_WARN_PCT % da total: uma
# porcentagem vale para placas de qualquer tamanho (78% ~ 3200 de 4096 MiB).
if [ "$NOTIFY_VRAM" = 1 ] && command -v nvidia-smi >/dev/null 2>&1; then
    sleep 1
    read -r free_mb total_mb < <(nvidia-smi --query-gpu=memory.free,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ',')
    prof=$(cat "$ACPI_DIR/platform_profile" 2>/dev/null || echo "-")
    res=$(xrandr --query 2>/dev/null | awk '/ connected primary/{for(i=3;i<=NF;i++) if($i ~ /^[0-9]+x[0-9]+\+/){split($i,a,"+");print a[1];exit}}')
    if [ -n "${free_mb:-}" ] && [ -n "${total_mb:-}" ] && [ "$total_mb" -gt 0 ] 2>/dev/null; then
        if [ $(( free_mb * 100 / total_mb )) -lt "$VRAM_WARN_PCT" ] 2>/dev/null; then
            notify -u critical "GameMode: VRAM livre baixa" \
                "${free_mb}/${total_mb} MiB livres | ${res:--} | perfil: ${prof}
Feche programas que usam a GPU (o navegador, por exemplo)."
        else
            notify "GameMode ativo" "${free_mb}/${total_mb} MiB livres | ${res:--} | perfil: ${prof}"
        fi
    fi
fi

exit 0
