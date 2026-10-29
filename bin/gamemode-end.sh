#!/usr/bin/env bash
# Executado pelo GameMode ao encerrar o jogo. Desfaz gamemode-start.sh.
set -u

# Mesmo motivo do start.sh: ponto decimal nos valores de --rate.
export LC_ALL=C

STATE="${XDG_RUNTIME_DIR:-/tmp}/gamemode-tweaks.state"
PREV_PROFILE=""; PREV_PM=""; RESTORE_CMD=""; APPLIED_MONITOR=""; PAUSED_SERVICES=""; PREV_HELPER=""
MON_BACKEND=""; MON_WAYLAND_DISPLAY=""
# shellcheck disable=SC1090
[ -r "$STATE" ] && . "$STATE"

# --- Encerra o monitor do jogo (fecha os CSVs) ---
"${HOME}/.local/bin/gamemode-monitor.sh" stop

# --- Perfil de energia: volta ao anterior com o mesmo auxiliar que o start
#     usou (estado gravado por versoes antigas nao tem PREV_HELPER) ---
if [ -n "$PREV_PROFILE" ]; then
    sudo -n "${PREV_HELPER:-/usr/local/bin/legion-profile}" "$PREV_PROFILE" 2>/dev/null
fi

# --- PowerMizer ---
if [ -n "$PREV_PM" ] && command -v nvidia-settings >/dev/null 2>&1; then
    nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=${PREV_PM}" >/dev/null 2>&1
fi

# --- Layout de monitores, exatamente como estava, com a mesma ferramenta que o
#     start usou (estado de versoes antigas nao tem MON_BACKEND: era o xrandr) ---
if [ "$APPLIED_MONITOR" = "1" ] && [ -n "$RESTORE_CMD" ]; then
    # shellcheck source=gamemode-displays.sh
    . "${HOME}/.local/bin/gamemode-displays.sh"
    MON_BACKEND="${MON_BACKEND:-xrandr}"
    [ -z "${WAYLAND_DISPLAY:-}" ] && [ -n "$MON_WAYLAND_DISPLAY" ] && export WAYLAND_DISPLAY="$MON_WAYLAND_DISPLAY"
    # Rede de seguranca: se o restore falhar, religa tudo no automatico
    eval "$RESTORE_CMD" >/dev/null 2>&1 || mon_fallback
fi

# --- Religa os servicos pausados pelo start.sh ---
for svc in $PAUSED_SERVICES; do
    systemctl --user start "$svc" 2>/dev/null
done

rm -f "$STATE"
command -v notify-send >/dev/null 2>&1 && notify-send -a GameMode "GameMode desativado" "Monitores e energia restaurados."

exit 0
