#!/usr/bin/env bash
# Executado pelo GameMode ao iniciar um jogo.
# Poe o jogo no monitor escolhido, desliga os demais e destrava energia. Cada
# ajuste depende de um recurso (platform_profile, NVIDIA, a ferramenta de
# monitores da sessao: xrandr ou, no Wayland, kscreen-doctor/gdctl/wlr-randr) e e pulado quando
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
: "${SET_WIFI_POWERSAVE:=1}"
: "${WIFI_IFACE:=}"
: "${WIFI_HELPER:=/usr/local/bin/wifi-powersave}"

# Raiz do ACPI no sysfs e do /proc (so os testes trocam).
ACPI_DIR="${GH_ACPI_DIR:-/sys/firmware/acpi}"
PROC_DIR="${GH_PROC_DIR:-/proc}"
NET_DIR="${GH_NET_DIR:-/sys/class/net}"

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
MON_BACKEND=""; MON_WAYLAND_DISPLAY=""; WIFI_PS_IFACE=""; WIFI_PS_HELPER=""
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
    [ -n "$MON_BACKEND" ]    && echo "MON_BACKEND=$MON_BACKEND"       >> "$STATE"
    [ -n "$MON_WAYLAND_DISPLAY" ] && printf 'MON_WAYLAND_DISPLAY=%q\n' "$MON_WAYLAND_DISPLAY" >> "$STATE"
    [ -n "$WIFI_PS_IFACE" ]  && printf 'WIFI_PS_IFACE=%q\n' "$WIFI_PS_IFACE" >> "$STATE"
    [ -n "$WIFI_PS_HELPER" ] && printf 'WIFI_PS_HELPER=%q\n' "$WIFI_PS_HELPER" >> "$STATE"
    return 0
}

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -a GameMode "$@"; }

# Valor de uma variavel posta nas opcoes de inicializacao do jogo
# ("VAR=x gamemoderun %command%"). O hook e filho do gamemoded, nao do jogo,
# entao ela e lida do ambiente dos processos do usuario carregados pelo
# gamemoderun (LD_PRELOAD com libgamemodeauto). O D-Bus (ListGames) nao serve
# aqui: o gamemoded so responde depois que este script termina. No
# "modo-jogo on" a variavel vem do proprio ambiente.
game_env() {
    local f v
    if [ -n "${!1:-}" ]; then printf '%s' "${!1}"; return; fi
    for f in "$PROC_DIR"/[0-9]*/environ; do
        [ -O "$f" ] || continue
        grep -qzas '^LD_PRELOAD=.*libgamemodeauto' "$f" || continue
        v=$(grep -zas "^$1=" "$f" | head -zn1 | tr -d '\0')
        if [ -n "$v" ]; then printf '%s' "${v#*=}"; return; fi
    done
}

# Monitores no X11 e no Wayland (mon_backend, mon_capture, mon_apply...).
# shellcheck source=gamemode-displays.sh
. "${HOME}/.local/bin/gamemode-displays.sh"

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

# --- Opcao por jogo: o gamemoderun pergunta, ao abrir o jogo, se ele roda so no
#     GAME_MONITOR ou em todos, e passa a resposta em GAMEMODE_SINGLE_MONITOR
#     (que tambem pode vir fixa nas opcoes de inicializacao do jogo) ---
if [ "$SINGLE_MONITOR" = 1 ] && [ -n "$GAME_MONITOR" ] && [ "$APPLIED_MONITOR" != "1" ]; then
    override=$(game_env GAMEMODE_SINGLE_MONITOR)
    [ -n "$override" ] && SINGLE_MONITOR="$override"
fi

# --- Monitores: joga no GAME_MONITOR, desliga o resto ---
# Com a ferramenta da sessao (xrandr no X11; kscreen-doctor, gdctl ou wlr-randr
# no Wayland) e so com um monitor escolhido: sem GAME_MONITOR, ou sem
# ferramenta, o layout fica como esta. Nada muda sem antes ter como desfazer.
if [ "$SINGLE_MONITOR" = 1 ] && [ -n "$GAME_MONITOR" ] && [ "$APPLIED_MONITOR" != "1" ]; then
    # O gamemoded pode ter nascido sem as variaveis da sessao grafica: vem do jogo.
    for v in XDG_SESSION_TYPE XDG_CURRENT_DESKTOP WAYLAND_DISPLAY; do
        if [ -z "${!v:-}" ]; then
            val=$(game_env "$v")
            [ -n "$val" ] && export "$v=$val"
        fi
    done
    MON_BACKEND=$(mon_backend)
    if [ -n "$MON_BACKEND" ] && mon_connected "$GAME_MONITOR"; then
        RESTORE_CMD=$(mon_capture)
        if [ -n "$RESTORE_CMD" ]; then
            if mon_apply "$GAME_MONITOR" "$GAME_REFRESH"; then
                APPLIED_MONITOR=1
                MON_WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
            else
                eval "$RESTORE_CMD" >/dev/null 2>&1
                RESTORE_CMD=""
                notify -u critical "GameMode" "Nao consegui trocar os monitores; layout mantido."
            fi
        fi
    fi
    [ "$APPLIED_MONITOR" = 1 ] || MON_BACKEND=""
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

# --- Economia de energia do Wi-Fi: a placa cochila entre os beacons do roteador
#     e segura pacotes, o que da picos de latencia no jogo online. Desliga via auxiliar root (sudo -n) e anota a
#     interface so quando estava ligada, para o end.sh religar so nesse caso.
#     Se o Wi-Fi reconectar no meio do jogo, o NetworkManager pode religa-la ---
if [ "$SET_WIFI_POWERSAVE" = 1 ] && [ -z "$WIFI_PS_IFACE" ] && [ -n "$WIFI_IFACE" ] \
   && [ -e "$NET_DIR/$WIFI_IFACE" ]; then
    if [ "$(sudo -n "$WIFI_HELPER" "$WIFI_IFACE" get 2>/dev/null)" = on ] \
       && sudo -n "$WIFI_HELPER" "$WIFI_IFACE" off 2>/dev/null; then
        WIFI_PS_IFACE="$WIFI_IFACE"; WIFI_PS_HELPER="$WIFI_HELPER"
    fi
fi

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
    # Resolucao do primario (no wlroots, que nao tem primario, a do primeiro ligado).
    res=$(mon_state 2>/dev/null | awk -F'|' '$2 == 1 && $7 == 1 {print $3; f = 1; exit}
                                             $2 == 1 && r == "" {r = $3} END {if (!f) print r}')
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
