#!/usr/bin/env bash
#
# run-tests.sh - testes do install.sh e dos hooks, contra hardware falso.
#
# Cada teste roda numa HOME temporaria, com o PATH apontando primeiro para
# tests/mocks/bin (xrandr, nvidia-smi, nvidia-settings, sudo, systemctl,
# notify-send falsos) e um platform_profile falso via GH_ACPI_DIR. Nada aqui
# toca a configuracao real, o sysfs ou o sudo de verdade.
#
# Uso: ./tests/run-tests.sh [-v]

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MOCKS="$ROOT/tests/mocks/bin"
VERBOSE=0; [[ "${1:-}" == -v ]] && VERBOSE=1

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no() {
  FAIL=$((FAIL + 1)); printf '  \033[31mFALHA\033[0m %s\n         %s\n' "$1" "$2"
  (( VERBOSE )) && [[ -n "${3:-}" ]] && printf '%s\n' "$3" | sed 's/^/         | /'
  return 0
}
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || no "$1" "esperava conter [$3]" "$2"; }
lacks(){ [[ "$2" != *"$3"* ]] && ok "$1" || no "$1" "nao esperava [$3]" "$2"; }
conf() { grep -E "^$2=" "$1/.config/gamemode-tweaks.conf" 2>/dev/null | head -1 | cut -d= -f2-; }
eqv()  { [[ "$2" == "$3" ]] && ok "$1" || no "$1" "esperava [$3], veio [$2]"; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# acpi DIR "escolhas" "atual": cria um platform_profile falso
acpi() { mkdir -p "$1"; echo "$2" > "$1/platform_profile_choices"; echo "$3" > "$1/platform_profile"; }

# inst HOME [opcoes...] <<< respostas: roda o install.sh com hardware falso
inst() {
  local h="$1"; shift
  mkdir -p "$h"
  HOME="$h" PATH="$MOCKS:$PATH" XDG_SESSION_TYPE="${SESSION:-x11}" GH_ALLOW_USER=1 \
    GH_ACPI_DIR="${ACPI:-$TMP/sem-acpi}" GH_INTERACTIVE="${INTER:-}" MOCK_LOG="$h.log" \
    "$ROOT/install.sh" "$@" 2>&1
}

# ===========================================================================
group "deteccao: notebook NVIDIA, X11, dois monitores, com performance"
# ===========================================================================
acpi "$TMP/acpi1" "low-power balanced performance" balanced
H="$TMP/h1"
# respostas: monitor 1 (DP-1); pausar lan.service
out=$(ACPI="$TMP/acpi1" INTER=1 MOCK_SERVICES="lan.service pipewire.service" \
      MOCK_SUDO_ALLOW="/usr/local/bin/platform-profile" inst "$H" <<< $'1\nlan.service')
eqv "perfil: liga com performance"        "$(conf "$H" SET_PLATFORM_PROFILE)/$(conf "$H" PERF_PROFILE)" "1/performance"
eqv "perfil: usa o auxiliar liberado"     "$(conf "$H" PROFILE_HELPER)" "/usr/local/bin/platform-profile"
eqv "nvidia: powermizer e alerta"         "$(conf "$H" SET_POWERMIZER)/$(conf "$H" NOTIFY_VRAM)" "1/1"
eqv "monitores: escolhido o 1 (DP-1)"     "$(conf "$H" GAME_MONITOR)/$(conf "$H" SINGLE_MONITOR)" "DP-1/1"
eqv "servicos: pausa o escolhido"         "$(conf "$H" PAUSE_SERVICES)" '"lan.service"'
has "lista os monitores com resolucao"    "$out" "1) DP-1 (2560x1440)"
eqv "gamemode.ini com a home"             "$(grep -c "start = $H/.local/bin/gamemode-start.sh" "$H/.config/gamemode.ini")" "1"
eqv "instala os hooks"                    "$(ls "$H/.local/bin" | tr '\n' ' ')" "gamemode-end.sh gamemode-monitor.sh gamemode-start.sh modo-jogo "
lacks "auxiliar liberado: nada de sudoers" "$out" "sudoers.d/platform-profile"

# ===========================================================================
group "--yes: o que e duvida fica desligado"
# ===========================================================================
H="$TMP/h2"
out=$(ACPI="$TMP/acpi1" MOCK_SERVICES="lan.service" inst "$H" --yes)
eqv "monitores: nao mexe"                 "$(conf "$H" GAME_MONITOR)/$(conf "$H" SINGLE_MONITOR)" "/0"
eqv "servicos: nenhum"                    "$(conf "$H" PAUSE_SERVICES)" '""'
eqv "perfil com performance: aplica"      "$(conf "$H" SET_PLATFORM_PROFILE)" "1"
has "sem auxiliar: mostra o sudoers"      "$out" "sudoers.d/platform-profile"
has "sem auxiliar: mostra a copia"        "$out" "/usr/local/bin/platform-profile"

# ===========================================================================
group "perfil sem 'performance' (outro fabricante)"
# ===========================================================================
acpi "$TMP/acpi2" "quiet balanced balanced-performance" balanced
H="$TMP/h3"
ACPI="$TMP/acpi2" inst "$H" --yes >/dev/null 2>&1 < /dev/null
eqv "--yes: nao muda o perfil"            "$(conf "$H" SET_PLATFORM_PROFILE)" "0"
H="$TMP/h4"
ACPI="$TMP/acpi2" INTER=1 inst "$H" <<< $'3\n0\n' >/dev/null
eqv "pergunta e usa a escolha"            "$(conf "$H" SET_PLATFORM_PROFILE)/$(conf "$H" PERF_PROFILE)" "1/balanced-performance"
H="$TMP/h5"
out=$(ACPI="$TMP/acpi2" inst "$H" --yes)
eqv "--yes com essas opcoes: desligado"   "$(conf "$H" SET_PLATFORM_PROFILE)" "0"

# ===========================================================================
group "sem NVIDIA, sem platform_profile, Wayland"
# ===========================================================================
H="$TMP/h6"
out=$(SESSION=wayland MOCK_NVIDIA=none inst "$H" --yes)
eqv "nvidia ausente: tudo desligado"      "$(conf "$H" SET_POWERMIZER)/$(conf "$H" NOTIFY_VRAM)" "0/0"
eqv "sem platform_profile: desligado"     "$(conf "$H" SET_PLATFORM_PROFILE)" "0"
eqv "wayland: nao mexe nos monitores"     "$(conf "$H" SINGLE_MONITOR)" "0"
has "wayland: explica"                    "$out" "Wayland"
H="$TMP/h7"
MOCK_NVSETTINGS=none inst "$H" --yes >/dev/null 2>&1
eqv "sem nvidia-settings: so o alerta"    "$(conf "$H" SET_POWERMIZER)/$(conf "$H" NOTIFY_VRAM)" "0/1"

# ===========================================================================
group "configuracao existente"
# ===========================================================================
H="$TMP/h8"; mkdir -p "$H/.config"; echo "GAME_MONITOR=MEU-1" > "$H/.config/gamemode-tweaks.conf"
out=$(inst "$H" --yes)
eqv "sem --reconfigure: mantem a da pessoa" "$(conf "$H" GAME_MONITOR)" "MEU-1"
eqv "guarda a detectada ao lado"          "$([[ -s "$H/.config/gamemode-tweaks.conf.detectado" ]] && echo sim)" "sim"
out=$(inst "$H" --yes --reconfigure)
eqv "--reconfigure: troca"                "$(conf "$H" GAME_MONITOR)" ""
eqv "--reconfigure: faz backup"           "$(ls "$H/.config" | grep -c 'gamemode-tweaks.conf.bak-')" "1"
H="$TMP/h9"
out=$(inst "$H" --check)
eqv "--check nao grava nada"              "$(ls -A "$H" | wc -l)" "0"
has "--check diz o que criaria"           "$out" "criaria:"

# ===========================================================================
group "monitor de dados"
# ===========================================================================
# Instalado na home: um monitor falso que responde --version como o de verdade.
H="$TMP/h15"; mkdir -p "$H/.local/bin"
printf '#!/bin/sh\necho "monitor 3.7"\n' > "$H/.local/bin/monitor"; chmod +x "$H/.local/bin/monitor"
out=$(inst "$H" --yes)
eqv "instalado: coleta ligada"            "$(conf "$H" RUN_MONITOR)" "1"
eqv "instalado: grava onde esta"          "$(conf "$H" MONITOR_BIN)" "$H/.local/bin/monitor"
has "instalado: mostra a versao"          "$out" "monitor de dados: monitor 3.7 em $H/.local/bin/monitor"
# Ausente: sem ~/.local/bin no PATH, para nao achar o monitor real de quem testa.
H="$TMP/h16"; mkdir -p "$H"
out=$(HOME="$H" PATH="$MOCKS:/usr/bin:/bin" XDG_SESSION_TYPE=x11 GH_ALLOW_USER=1 \
      GH_ACPI_DIR="$TMP/sem-acpi" "$ROOT/install.sh" --yes 2>&1)
eqv "ausente: coleta desligada"           "$(conf "$H" RUN_MONITOR)" "0"
has "ausente: mensagem"                   "$out" "monitor de dados não instalado - coleta de dados desligada"
has "ausente: onde baixar"                "$out" "para instalar, baixe o monitor em (https://github.com/rattones/monitor)"
# Um "monitor" que nao e este (outro programa com o mesmo nome) nao conta.
H="$TMP/h17"; mkdir -p "$H/.local/bin"
printf '#!/bin/sh\necho "outro programa"\n' > "$H/.local/bin/monitor"; chmod +x "$H/.local/bin/monitor"
inst "$H" --yes >/dev/null
eqv "outro programa chamado monitor: ignora" "$(conf "$H" RUN_MONITOR)" "0"

# ===========================================================================
group "sudo e grupo gamemode"
# ===========================================================================
if (( EUID != 0 )); then
  out=$(HOME="$TMP/h10" PATH="$MOCKS:$PATH" "$ROOT/install.sh" --yes 2>&1); rc=$?
  eqv "sem sudo: recusa"                  "$rc" "1"
  has "sem sudo: diz como rodar"          "$out" "rode com sudo: sudo $ROOT/install.sh --yes"
fi
H="$TMP/h11"
out=$(inst "$H" --yes)
has "fora do grupo: adiciona"             "$(cat "$H.log" 2>/dev/null)" "usermod -aG gamemode $(id -un)"
has "fora do grupo: avisa do login"       "$out" "vale a partir do proximo login"
H="$TMP/h12"
out=$(MOCK_GROUPS="users gamemode" inst "$H" --yes)
lacks "ja no grupo: nao chama usermod"    "$(cat "$H.log" 2>/dev/null)" "usermod"
has "ja no grupo: diz"                    "$out" "ja faz parte"
H="$TMP/h13"
out=$(inst "$H" --check)
lacks "--check: nao chama usermod"        "$(cat "$H.log" 2>/dev/null)" "usermod"
has "--check: diz o que faria"            "$out" "poria $(id -un) no grupo"
H="$TMP/h14"
out=$(MOCK_GAMEMODE_GROUP=none inst "$H" --yes)
lacks "sem o grupo: nao chama usermod"    "$(cat "$H.log" 2>/dev/null)" "usermod"
has "sem o grupo: manda instalar"         "$out" "sudo apt install gamemode"

# ===========================================================================
group "hooks: start e end com a configuracao gerada"
# ===========================================================================
# runhook HOME script: roda um hook com os mocks e devolve o log das chamadas
runhook() {
  local h="$1" s="$2"
  HOME="$h" PATH="$MOCKS:$PATH" XDG_RUNTIME_DIR="$h/run" XDG_SESSION_TYPE="${SESSION:-x11}" \
    GH_ACPI_DIR="${ACPI:-$TMP/sem-acpi}" MOCK_LOG="$h/log" MOCK_SUDO_ALLOW="${ALLOW:-}" \
    MOCK_VRAM_FREE="${VFREE:-7000}" MOCK_SERVICES="${SVCS:-}" \
    "$h/.local/bin/$s" >/dev/null 2>&1
}
H="$TMP/h1"; mkdir -p "$H/run"; : > "$H/log"
sed -i 's/^RUN_MONITOR=.*/RUN_MONITOR=0/' "$H/.config/gamemode-tweaks.conf"
ACPI="$TMP/acpi1" ALLOW=/usr/local/bin/platform-profile SVCS=lan.service VFREE=1000 runhook "$H" gamemode-start.sh
log=$(cat "$H/log")
has "start: aplica o perfil"              "$log" "sudo /usr/local/bin/platform-profile performance"
has "start: powermizer no maximo"         "$log" "GPUPowerMizerMode=1"
has "start: so o DP-1 ligado"             "$log" "--output DP-1 --mode 2560x1440 --pos 0x0 --primary --rate 165.00 --output eDP-1 --off"
has "start: pausa o servico"              "$log" "systemctl stop lan.service"
has "start: alerta de VRAM em %"          "$log" "VRAM livre baixa"
: > "$H/log"
ACPI="$TMP/acpi1" ALLOW=/usr/local/bin/platform-profile SVCS=lan.service runhook "$H" gamemode-end.sh
log=$(cat "$H/log")
has "end: volta o perfil anterior"        "$log" "sudo /usr/local/bin/platform-profile balanced"
has "end: religa o servico"               "$log" "systemctl start lan.service"
has "end: restaura os dois monitores"     "$log" "--output eDP-1 --mode 1920x1080 --pos 2560x0"

H="$TMP/h4"; mkdir -p "$H/run"; : > "$H/log"
sed -i 's/^RUN_MONITOR=.*/RUN_MONITOR=0/' "$H/.config/gamemode-tweaks.conf"
ACPI="$TMP/acpi1" ALLOW=/usr/local/bin/platform-profile runhook "$H" gamemode-start.sh
lacks "perfil que o firmware nao tem: nao aplica" "$(cat "$H/log")" "platform-profile balanced-performance"
VFREE=7900 ACPI="$TMP/acpi2" runhook "$H" gamemode-end.sh
: > "$H/log"; rm -f "$H/run/gamemode-tweaks.state"
VFREE=7900 runhook "$H" gamemode-start.sh
lacks "VRAM folgada: sem alerta"          "$(cat "$H/log")" "VRAM livre baixa"
lacks "sem monitor escolhido: nao mexe"   "$(cat "$H/log")" "--off"

# ===========================================================================
group "system/platform-profile"
# ===========================================================================
out=$(sh "$ROOT/system/platform-profile" turbo 2>&1); rc=$?
if [[ -r /sys/firmware/acpi/platform_profile_choices ]]; then
  eqv "recusa perfil que nao existe"      "$rc" "2"
  has "lista os validos"                  "$out" "uso:"
else
  eqv "sem platform_profile: recusa"      "$rc" "1"
fi

printf '\n\033[1m%d ok, %d falha(s)\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
