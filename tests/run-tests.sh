#!/usr/bin/env bash
#
# run-tests.sh - testes do install.sh e dos hooks, contra hardware falso.
#
# Cada teste roda numa HOME temporaria, com o PATH apontando primeiro para
# tests/mocks/bin (xrandr, nvidia-smi, nvidia-settings, sudo, systemctl,
# notify-send falsos), um platform_profile falso via GH_ACPI_DIR e placas de
# rede falsas via GH_NET_DIR. Nada aqui
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
# netif DIR NOME tipo(wifi|eth) estado: cria uma interface de rede falsa
netif() { mkdir -p "$1/$2"; [[ "$3" == wifi ]] && mkdir -p "$1/$2/wireless"; echo "$4" > "$1/$2/operstate"; }
netif "$TMP/net1" eth0 eth up
netif "$TMP/net1" wlan0 wifi down
netif "$TMP/net1" wlan1 wifi up

# inst HOME [opcoes...] <<< respostas: roda o install.sh com hardware falso
inst() {
  local h="$1"; shift
  mkdir -p "$h"
  HOME="$h" PATH="$MOCKS:$PATH" XDG_SESSION_TYPE="${SESSION:-x11}" GH_ALLOW_USER=1 \
    XDG_CURRENT_DESKTOP="${DESK:-}" MOCK_WAYLAND="${WL:-}" \
    GH_ACPI_DIR="${ACPI:-$TMP/sem-acpi}" GH_INTERACTIVE="${INTER:-}" MOCK_LOG="$h.log" \
    GH_RUNTIME_DIR="$h/run" GH_NET_DIR="${NET:-$TMP/sem-net}" MOCK_SUDO_ALLOW="${MOCK_SUDO_ALLOW:-}" \
    "$ROOT/install.sh" "$@" 2>&1
}

# ===========================================================================
group "deteccao: notebook NVIDIA, X11, dois monitores, com performance"
# ===========================================================================
acpi "$TMP/acpi1" "low-power balanced performance" balanced
H="$TMP/h1"
# respostas: monitor 1 (DP-1); pausar lan.service
out=$(ACPI="$TMP/acpi1" NET="$TMP/net1" INTER=1 MOCK_SERVICES="lan.service pipewire.service" \
      MOCK_SUDO_ALLOW="/usr/local/bin/platform-profile /usr/local/bin/wifi-powersave" inst "$H" <<< $'1\nlan.service')
eqv "perfil: liga com performance"        "$(conf "$H" SET_PLATFORM_PROFILE)/$(conf "$H" PERF_PROFILE)" "1/performance"
eqv "perfil: usa o auxiliar liberado"     "$(conf "$H" PROFILE_HELPER)" "/usr/local/bin/platform-profile"
eqv "nvidia: powermizer e alerta"         "$(conf "$H" SET_POWERMIZER)/$(conf "$H" NOTIFY_VRAM)" "1/1"
eqv "monitores: escolhido o 1 (DP-1)"     "$(conf "$H" GAME_MONITOR)/$(conf "$H" SINGLE_MONITOR)" "DP-1/1"
eqv "servicos: pausa o escolhido"         "$(conf "$H" PAUSE_SERVICES)" '"lan.service"'
has "lista os monitores com resolucao"    "$out" "1) DP-1 (2560x1440)"
eqv "gamemode.ini com a home"             "$(grep -c "start = $H/.local/bin/gamemode-start.sh" "$H/.config/gamemode.ini")" "1"
eqv "instala os hooks"                    "$(ls "$H/.local/bin" | tr '\n' ' ')" "gamemode-displays.sh gamemode-end.sh gamemode-monitor.sh gamemode-start.sh gamemode-travadas gamemoderun modo-jogo "
lacks "auxiliar liberado: nada de sudoers" "$out" "sudoers.d/platform-profile"
eqv "wifi: liga na placa conectada"       "$(conf "$H" SET_WIFI_POWERSAVE)/$(conf "$H" WIFI_IFACE)" "1/wlan1"
lacks "wifi liberado: nada de sudoers"    "$out" "sudoers.d/wifi-powersave"

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
eqv "sem Wi-Fi: desligado"                "$(conf "$H" SET_WIFI_POWERSAVE)/$(conf "$H" WIFI_IFACE)" "0/"
lacks "sem Wi-Fi: sem sudoers do wifi"    "$out" "wifi-powersave"
H="$TMP/h2w"
out=$(NET="$TMP/net1" GH_SYSROOT="$TMP/sys2w" inst "$H" --yes)
eqv "wifi sem auxiliar --yes: nao mexe"   "$(conf "$H" SET_WIFI_POWERSAVE)/$(conf "$H" WIFI_IFACE)" "0/wlan1"
has "wifi sem auxiliar --yes: avisa"      "$out" "nao instala; o Wi-Fi fica como esta"
has "wifi sem auxiliar --yes: sugere"     "$out" "install.sh de novo"
lacks "wifi sem auxiliar --yes: sem comandos" "$out" "sudoers-wifi-powersave'"
eqv "wifi sem auxiliar --yes: nada instalado" "$(ls -A "$TMP/sys2w" 2>/dev/null)" ""

# ===========================================================================
group "Wi-Fi sem o auxiliar: pergunta se instala"
# ===========================================================================
# respostas: monitor 0; Wi-Fi s/n. GH_SYSROOT recebe /usr/local/bin e /etc/sudoers.d.
H="$TMP/h2s"; SYS="$TMP/sys2s"
out=$(NET="$TMP/net1" INTER=1 GH_SYSROOT="$SYS" inst "$H" <<< $'0\ns\nn')
has "wifi: pergunta se instala"           "$out" "instalar o auxiliar e desligar a economia do Wi-Fi durante o jogo?"
eqv "wifi 's': liga na configuracao"      "$(conf "$H" SET_WIFI_POWERSAVE)/$(conf "$H" WIFI_IFACE)" "1/wlan1"
eqv "wifi 's': instala o auxiliar"        "$(cmp -s "$ROOT/system/wifi-powersave" "$SYS/usr/local/bin/wifi-powersave" && echo igual)" "igual"
has "wifi 's': regra com o usuario"       "$(cat "$SYS/etc/sudoers.d/wifi-powersave" 2>/dev/null)" "$(id -un) ALL=(root) NOPASSWD: /usr/local/bin/wifi-powersave"
eqv "wifi 's': regra 0440"                "$(stat -c %a "$SYS/etc/sudoers.d/wifi-powersave" 2>/dev/null)" "440"
has "wifi 's': confere com visudo"        "$(cat "$H.log" 2>/dev/null)" "visudo -cqf"
has "wifi 's': nada pendente"             "$out" "Parte do sistema: nada pendente."
out=$(NET="$TMP/net1" INTER=1 GH_SYSROOT="$SYS" inst "$H" <<< $'0\ns\nn\nn')
has "wifi 's' de novo: igual"             "$out" "igual:      /usr/local/bin/wifi-powersave"
H="$TMP/h2n"
out=$(NET="$TMP/net1" INTER=1 GH_SYSROOT="$TMP/sys2n" inst "$H" <<< $'0\nn\nn')
eqv "wifi 'n': nao mexe"                  "$(conf "$H" SET_WIFI_POWERSAVE)" "0"
has "wifi 'n': avisa"                     "$out" "economia de energia do Wi-Fi fica como esta"
eqv "wifi 'n': nada instalado"            "$(ls -A "$TMP/sys2n" 2>/dev/null)" ""
H="$TMP/h2f"
out=$(NET="$TMP/net1" INTER=1 GH_SYSROOT="$TMP/sys2f" MOCK_VISUDO_FAIL=1 inst "$H" <<< $'0\ns\nn')
eqv "wifi visudo recusa: nao liga"        "$(conf "$H" SET_WIFI_POWERSAVE)" "0"
has "wifi visudo recusa: avisa"           "$out" "nao passou no visudo"
eqv "wifi visudo recusa: nada instalado"  "$(ls -A "$TMP/sys2f" 2>/dev/null)" ""
has "wifi visudo recusa: mostra comandos" "$out" "system/wifi-powersave' /usr/local/bin/wifi-powersave"

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
lacks "wayland sem ferramenta: sem pergunta" "$out" "monitor do jogo"
H="$TMP/h6k"
out=$(SESSION=wayland WL=kde DESK=KDE INTER=1 inst "$H" <<< $'1\n')
eqv "wayland KDE: escolhe o monitor"      "$(conf "$H" GAME_MONITOR)/$(conf "$H" SINGLE_MONITOR)" "DP-1/1"
has "wayland KDE: diz a ferramenta"       "$out" "(kscreen-doctor), 2 monitor(es)"
eqv "pergunta ao abrir: ligada"           "$(conf "$H" ASK_MONITOR)/$(conf "$H" ASK_TIMEOUT)" "1/15"
H="$TMP/h6g"
out=$(SESSION=wayland WL=gnome DESK=ubuntu:GNOME INTER=1 inst "$H" <<< $'2\n')
eqv "wayland GNOME: escolhe o monitor"    "$(conf "$H" GAME_MONITOR)" "eDP-1"
has "wayland GNOME: diz a ferramenta"     "$out" "(gdctl)"
H="$TMP/h6w"
out=$(SESSION=wayland WL=wlr DESK=sway INTER=1 inst "$H" <<< $'1\n')
eqv "wayland wlroots: escolhe o monitor"  "$(conf "$H" GAME_MONITOR)" "DP-1"
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
# MangoHud instalado (falso, no PATH): mostra como usar e nao oferece instalar.
mkdir -p "$TMP/mango"; printf '#!/bin/sh\nexit 0\n' > "$TMP/mango/mangohud"; chmod +x "$TMP/mango/mangohud"
out=$(HOME="$TMP/h18" PATH="$TMP/mango:$MOCKS:/usr/bin:/bin" XDG_SESSION_TYPE=x11 GH_ALLOW_USER=1 \
      GH_ACPI_DIR="$TMP/sem-acpi" GH_NET_DIR="$TMP/sem-net" "$ROOT/install.sh" --yes 2>&1)
has "mangohud instalado: mostra como usar" "$out" "com MangoHud: gamemoderun mangohud %command%"
lacks "mangohud instalado: sem sugestao"  "$out" "instalar o MangoHud"
# Ausente, com pergunta (depois da do monitor): "s" instala pelo gerenciador de pacotes (apt-get falso,
# que poe um mangohud falso em MOCK_MANGO_DIR); --yes nao instala.
mkdir -p "$TMP/mango2"
out=$(PATH="$MOCKS:$TMP/mango2:/usr/bin:/bin" MOCK_MANGO_DIR="$TMP/mango2" INTER=1 inst "$TMP/h20" <<< $'0\ns')
has "mangohud: pergunta se instala"       "$out" "instalar o MangoHud agora (apt-get install -y mangohud)?"
has "mangohud 's': instala"               "$(cat "$TMP/h20.log" 2>/dev/null)" "apt-get install -y mangohud"
has "mangohud 's': mostra como usar"      "$out" "com MangoHud: gamemoderun mangohud %command%"
rm -f "$TMP/mango2/mangohud"
out=$(PATH="$MOCKS:$TMP/mango2:/usr/bin:/bin" MOCK_MANGO_DIR="$TMP/mango2" INTER=1 inst "$TMP/h21" <<< $'0\nn')
lacks "mangohud 'n': nao instala"         "$(cat "$TMP/h21.log" 2>/dev/null)" "apt-get"
out=$(PATH="$MOCKS:$TMP/mango2:/usr/bin:/bin" MOCK_MANGO_DIR="$TMP/mango2" inst "$TMP/h22" --yes)
lacks "mangohud --yes: nao instala"       "$(cat "$TMP/h22.log" 2>/dev/null)" "apt-get"
has "mangohud --yes: mostra o comando"    "$out" "sudo apt-get install -y mangohud"
if ! PATH="$MOCKS:/usr/bin:/bin" command -v mangohud >/dev/null 2>&1; then
  out=$(HOME="$TMP/h19" PATH="$MOCKS:/usr/bin:/bin" XDG_SESSION_TYPE=x11 GH_ALLOW_USER=1 \
        GH_ACPI_DIR="$TMP/sem-acpi" GH_NET_DIR="$TMP/sem-net" "$ROOT/install.sh" --yes 2>&1)
  has "mangohud ausente: sugere instalar" "$out" "Sugestao: instale o MangoHud"
fi
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
    XDG_CURRENT_DESKTOP="${DESK:-}" MOCK_WAYLAND="${WL:-}" \
    GH_ACPI_DIR="${ACPI:-$TMP/sem-acpi}" GH_PROC_DIR="${PROC:-$TMP/sem-proc}" \
    MOCK_LOG="$h/log" MOCK_SUDO_ALLOW="${ALLOW:-}" MOCK_VRAM_FREE="${VFREE:-7000}" MOCK_SERVICES="${SVCS:-}" \
    GH_NET_DIR="${NET:-$TMP/net1}" MOCK_WIFI_PS="${WIFIPS:-on}" \
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
lacks "wifi sem auxiliar liberado: nao mexe" "$log" "wifi-powersave"

# Wi-Fi: desliga a economia so se estava ligada, e religa no fim.
WALLOW="/usr/local/bin/wifi-powersave"
: > "$H/log"; ALLOW="$WALLOW" runhook "$H" gamemode-start.sh
has "wifi: desliga a economia"            "$(cat "$H/log")" "sudo /usr/local/bin/wifi-powersave wlan1 off"
: > "$H/log"; ALLOW="$WALLOW" WIFIPS=off runhook "$H" gamemode-start.sh
lacks "wifi: start repetido nao reaplica" "$(cat "$H/log")" "wlan1 off"
: > "$H/log"; ALLOW="$WALLOW" runhook "$H" gamemode-end.sh
has "wifi: end religa a economia"         "$(cat "$H/log")" "sudo /usr/local/bin/wifi-powersave wlan1 on"
: > "$H/log"; ALLOW="$WALLOW" WIFIPS=off runhook "$H" gamemode-start.sh
lacks "wifi ja sem economia: nao desliga" "$(cat "$H/log")" "wlan1 off"
: > "$H/log"; ALLOW="$WALLOW" runhook "$H" gamemode-end.sh
lacks "wifi ja sem economia: end nao liga" "$(cat "$H/log")" "wlan1 on"
: > "$H/log"; ALLOW="$WALLOW" NET="$TMP/sem-net" runhook "$H" gamemode-start.sh
lacks "wifi: placa ausente, nao mexe"     "$(cat "$H/log")" "wifi-powersave"
runhook "$H" gamemode-end.sh

# Opcao por jogo: a variavel vem do ambiente do processo do gamemoderun.
# fakeproc DIR PID VAR=valor...: cria um /proc/PID/environ falso
fakeproc() { local d="$1/$2"; shift 2; mkdir -p "$d"; printf '%s\0' "$@" > "$d/environ"; }
fakeproc "$TMP/proc1" 100 "HOME=/x" "GAMEMODE_SINGLE_MONITOR=0"
fakeproc "$TMP/proc1" 200 "LD_PRELOAD=libgamemodeauto.so.0" "GAMEMODE_SINGLE_MONITOR=0"
fakeproc "$TMP/proc2" 100 "HOME=/x" "GAMEMODE_SINGLE_MONITOR=0"
H="$TMP/h1"; : > "$H/log"; rm -f "$H/run/gamemode-tweaks.state"
PROC="$TMP/proc1" runhook "$H" gamemode-start.sh
lacks "jogo com GAMEMODE_SINGLE_MONITOR=0: nao desliga" "$(cat "$H/log")" "--off"
runhook "$H" gamemode-end.sh
lacks "end sem troca: nao mexe nos monitores" "$(cat "$H/log")" "--output"
: > "$H/log"
PROC="$TMP/proc2" runhook "$H" gamemode-start.sh
has "variavel fora do gamemoderun: ignora" "$(cat "$H/log")" "--output eDP-1 --off"
runhook "$H" gamemode-end.sh; : > "$H/log"
HOME="$H" PATH="$MOCKS:$PATH" XDG_RUNTIME_DIR="$H/run" XDG_SESSION_TYPE=x11 \
  GH_ACPI_DIR="$TMP/sem-acpi" GH_PROC_DIR="$TMP/sem-proc" MOCK_LOG="$H/log" \
  GAMEMODE_SINGLE_MONITOR=0 "$H/.local/bin/gamemode-start.sh" >/dev/null 2>&1
lacks "modo-jogo com a variavel: nao desliga" "$(cat "$H/log")" "--off"
runhook "$H" gamemode-end.sh

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
group "hooks: monitores no Wayland"
# ===========================================================================
H="$TMP/h1"; rm -f "$H/run/gamemode-tweaks.state"
# wl DESKTOP FERRAMENTA "troca esperada" "volta esperada"
wl() {
  : > "$H/log"
  SESSION=wayland WL="$2" DESK="$1" runhook "$H" gamemode-start.sh
  has "$1: so o DP-1 ligado"              "$(cat "$H/log")" "$3"
  : > "$H/log"
  SESSION=wayland WL="$2" DESK="$1" runhook "$H" gamemode-end.sh
  has "$1: volta o layout"                "$(cat "$H/log")" "$4"
}
wl KDE kde "kscreen-doctor output.DP-1.enable output.DP-1.position.0,0 output.DP-1.priority.1 output.eDP-1.disable" \
  "kscreen-doctor output.DP-1.enable output.DP-1.mode.0 output.DP-1.position.0,0 output.DP-1.priority.1 output.eDP-1.enable output.eDP-1.mode.3 output.eDP-1.position.2560,0"
wl GNOME gnome "gdctl set --logical-monitor --primary --scale 1.0 --monitor DP-1" \
  "gdctl set --logical-monitor --primary --x 0 --y 0 --scale 1.0 --monitor DP-1 --mode 2560x1440@165.000 --logical-monitor --x 2560 --y 0 --scale 1.25 --monitor eDP-1 --mode 1920x1080@60.000"
wl sway wlr "wlr-randr --output DP-1 --on --pos 0,0 --output eDP-1 --off" \
  "wlr-randr --output DP-1 --on --mode 2560x1440@165.000000Hz --pos 0,0 --scale 1.000000 --output eDP-1 --on --mode 1920x1080@60.000000Hz --pos 2560,0 --scale 1.250000"
: > "$H/log"
SESSION=wayland DESK=X-Cinnamon runhook "$H" gamemode-start.sh
lacks "Wayland sem ferramenta: nao mexe"  "$(cat "$H/log")" "--off"
runhook "$H" gamemode-end.sh

# ===========================================================================
group "gamemoderun: --help e repasse ao do sistema"
# ===========================================================================
H="$TMP/h1"
GMR="$H/.local/bin/gamemoderun"
# um gamemoderun "do sistema" falso, depois deste no PATH
mkdir -p "$TMP/sysgames"
printf '#!/bin/sh\necho "real: $* [${GAMEMODE_SINGLE_MONITOR-}]"\n' > "$TMP/sysgames/gamemoderun"; chmod +x "$TMP/sysgames/gamemoderun"
out=$(HOME="$H" PATH="$H/.local/bin:$TMP/sysgames:$PATH" "$GMR" --help 2>&1)
has "--help: mostra o uso"                "$out" "gamemoderun %command%"
has "--help: opcao por jogo"              "$out" "GAMEMODE_SINGLE_MONITOR=0"
has "--help: le a configuracao"           "$out" "monitor unico     : ligado (DP-1)"
has "--help: servicos da configuracao"    "$out" "servicos pausados : lan.service"
has "--help: wifi da configuracao"        "$out" "Wi-Fi sem economia: ligado (wlan1)"
has "--help: acha o do sistema"           "$out" "$TMP/sysgames/gamemoderun"
eqv "-h igual a --help"                   "$(HOME="$H" PATH="$H/.local/bin:$TMP/sysgames:$PATH" "$GMR" -h 2>&1)" "$out"
out=$(HOME="$TMP/sem-home" PATH="$H/.local/bin:$TMP/sysgames:$PATH" "$GMR" 2>&1)
has "sem argumentos: mostra o uso"        "$out" "uso: gamemoderun"
has "sem configuracao: avisa"             "$out" "rode o install.sh"
# gmr [VAR=valor...] -- args: roda o gamemoderun como a Steam, com os mocks e uma sessao X11
gmr() {
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  mkdir -p "$TMP/gmr-run"; : > "$TMP/gmr.log"
  env -u GAMEMODE_SINGLE_MONITOR HOME="$H" PATH="$H/.local/bin:$MOCKS:$TMP/sysgames:$PATH" DISPLAY=:0 \
    XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=X-Cinnamon XDG_RUNTIME_DIR="$TMP/gmr-run" \
    MOCK_LOG="$TMP/gmr.log" "${envs[@]}" "$GMR" "$@" 2>&1
}
eqv "repassa tudo ao do sistema"          "$(gmr MOCK_DIALOG=single -- ./jogo --help -x)" "real: ./jogo --help -x [1]"
has "pergunta com o zenity"               "$(cat "$TMP/gmr.log")" "--extra-button=So o DP-1 --extra-button=Todos os monitores --timeout=15"
eqv "resposta: todos os monitores"        "$(gmr MOCK_DIALOG=all -- jogo)" "real: jogo [0]"
eqv "sem resposta: so o do jogo"          "$(gmr -- jogo)" "real: jogo [1]"
eqv "janela fechada: so o do jogo"        "$(gmr MOCK_DIALOG=close -- jogo)" "real: jogo [1]"
eqv "fixado no jogo: nao pergunta"        "$(gmr GAMEMODE_SINGLE_MONITOR=0 -- jogo)" "real: jogo [0]"
eqv "fixado no jogo: sem dialogo"         "$(cat "$TMP/gmr.log")" ""
gmr XDG_CURRENT_DESKTOP=KDE MOCK_DIALOG=all -- jogo >/dev/null
has "KDE: pergunta com o kdialog"         "$(cat "$TMP/gmr.log")" "kdialog --title GameMode --yes-label So o DP-1"
eqv "kdialog: resposta todos"             "$(gmr XDG_CURRENT_DESKTOP=KDE MOCK_DIALOG=all -- jogo)" "real: jogo [0]"
sed -i 's/^ASK_TIMEOUT=.*/ASK_TIMEOUT=1/' "$H/.config/gamemode-tweaks.conf"
eqv "kdialog sem resposta: so o do jogo"  "$(gmr XDG_CURRENT_DESKTOP=KDE -- jogo)" "real: jogo [1]"
sed -i 's/^ASK_TIMEOUT=.*/ASK_TIMEOUT=15/' "$H/.config/gamemode-tweaks.conf"
eqv "Wayland KDE: pergunta tambem"        "$(gmr XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-0 DISPLAY= XDG_CURRENT_DESKTOP=KDE MOCK_WAYLAND=kde MOCK_DIALOG=all -- jogo)" "real: jogo [0]"
eqv "Wayland sem ferramenta: nao pergunta" "$(gmr XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-0 MOCK_DIALOG=all -- jogo)" "real: jogo []"
eqv "sem tela: nao pergunta"              "$(gmr DISPLAY= MOCK_DIALOG=all -- jogo)" "real: jogo []"
echo "APPLIED_MONITOR=1" > "$TMP/gmr-run/gamemode-tweaks.state"
eqv "monitores ja trocados: nao pergunta" "$(gmr MOCK_DIALOG=all -- jogo)" "real: jogo []"
rm -f "$TMP/gmr-run/gamemode-tweaks.state"
sed -i 's/^ASK_MONITOR=.*/ASK_MONITOR=0/' "$H/.config/gamemode-tweaks.conf"
eqv "ASK_MONITOR=0: nao pergunta"         "$(gmr MOCK_DIALOG=all -- jogo)" "real: jogo []"
sed -i 's/^ASK_MONITOR=.*/ASK_MONITOR=1/' "$H/.config/gamemode-tweaks.conf"
# Runtime da Steam antes no PATH: usa o zenity do sistema (o mock), nao o dela.
mkdir -p "$TMP/steam-runtime/bin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/steam-runtime/bin/zenity"; chmod +x "$TMP/steam-runtime/bin/zenity"
eqv "pula o zenity do runtime da Steam"   "$(env PATH="$TMP/steam-runtime/bin:$H/.local/bin:$MOCKS:$TMP/sysgames:$PATH" \
  HOME="$H" DISPLAY=:0 XDG_SESSION_TYPE=x11 XDG_RUNTIME_DIR="$TMP/gmr-run" MOCK_DIALOG=all "$GMR" jogo 2>&1)" "real: jogo [0]"

# ===========================================================================
group "gamemoderun cleanlog: apaga as coletas antigas"
# ===========================================================================
H="$TMP/h1"; GMR="$H/.local/bin/gamemoderun"; CL="$TMP/cl"
# sessao NOME AAAAMMDD-HHMMSS sufixos...: os arquivos de uma coleta falsa em $CL
sessao() { local s="$1-$2" x; shift 2; for x in "$@"; do echo dados > "$CL/$s$x"; done; }
# coletas: 20/11, 21/11 (passou da meia-noite), 22/11, 23/11 (outro jogo) e 24/11,
# mais arquivos que nao sao coleta
prep() {
  rm -rf "$CL" "$TMP/cl-run"; mkdir -p "$CL" "$TMP/cl-run"
  sessao dota2 20261120-210000 .csv -sys.csv -threads.csv .log
  sessao dota2 20261121-231500 .csv -ping.csv -marcas.txt .log
  touch -d '2026-11-22 01:00' "$CL/dota2-20261121-231500.csv" "$CL/dota2-20261121-231500-ping.csv"
  sessao dota2 20261122-080000 .csv .log
  sessao outro-jogo 20261123-120000 .csv
  sessao dota2 20261124-090000 .csv -threads.csv
  echo nota > "$CL/notas.txt"
  mkdir "$CL/pasta-20261101-000000.d"
  echo alvo > "$TMP/cl-alvo"; ln -s "$TMP/cl-alvo" "$CL/link-20261101-000000.csv"
}
# cl args...: roda o gamemoderun cleanlog com hoje = 24/11/2026
cl() {
  env -u XDG_CONFIG_HOME HOME="$H" PATH="$H/.local/bin:$TMP/sysgames:$PATH" XDG_RUNTIME_DIR="$TMP/cl-run" \
    GH_TODAY=20261124 MONITOR_LOG_DIR="${CLD:-$CL}" "$GMR" cleanlog "$@" 2>&1
}
nfiles() { find "$CL" -maxdepth 1 -name "*$1*" | wc -l; }

prep; out=$(cl 2 --check); rc=$?
eqv "--check: sai com 0"                  "$rc" "0"
has "--check: diz o que apagaria"         "$out" "apagaria 2 sessoes (8 arquivos"
has "--check: lista a sessao"             "$out" "dota2-20261120-210000"
eqv "--check: nao apaga nada"             "$(ls "$CL" | wc -l)" "16"
out=$(cl 2); rc=$?
eqv "cleanlog 2: sai com 0"               "$rc" "0"
has "cleanlog 2: total"                   "$out" "apagadas 2 sessoes (8 arquivos"
has "cleanlog 2: data do corte"           "$out" "anteriores a 22/11/2026"
eqv "cleanlog 2: apaga o dia 20"          "$(nfiles 20261120-)" "0"
eqv "cleanlog 2: apaga a sessao inteira que passou da meia-noite" "$(nfiles 20261121-)" "0"
eqv "cleanlog 2: mantem o dia 22"         "$(nfiles 20261122-)" "2"
eqv "cleanlog 2: mantem 23 e 24"          "$(nfiles 20261123-)/$(nfiles 20261124-)" "1/2"
eqv "fora do padrao: fica"                "$(cat "$CL/notas.txt")" "nota"
eqv "subdiretorio: fica"                  "$([[ -d "$CL/pasta-20261101-000000.d" ]] && echo sim)" "sim"
eqv "link: fica, e o alvo tambem"         "$([[ -L "$CL/link-20261101-000000.csv" && -f "$TMP/cl-alvo" ]] && echo sim)" "sim"
lacks "nao chama o gamemoderun do sistema" "$out" "real:"
out=$(cl 2); rc=$?
has "de novo: nada a apagar"              "$out" "nada a apagar"
eqv "de novo: sai com 0"                  "$rc" "0"

prep; cl 0 >/dev/null
eqv "cleanlog 0: so fica o dia de hoje"   "$(nfiles 2026112[0-3]-)/$(nfiles 20261124-)" "0/2"

prep; echo "$CL/dota2-20261120-210000.csv" > "$TMP/cl-run/gamemode-monitor.current"
out=$(cl 2)
eqv "coleta em andamento: fica"           "$(nfiles 20261120-)" "4"
eqv "coleta em andamento: o resto sai"    "$(nfiles 20261121-)" "0"

prep
for a in "" "-1" "abc" "2x" "2 3" "--check" "2 --forca"; do
  # shellcheck disable=SC2086
  out=$(cl $a); rc=$?
  eqv "argumento [${a}]: sai com 2"        "$rc" "2"
  has "argumento [${a}]: mostra o uso"     "$out" "uso: gamemoderun cleanlog <dias> [--check]"
done
eqv "argumento invalido: nao apaga nada"  "$(ls "$CL" | wc -l)" "16"

out=$(CLD="$TMP/cl-nao-existe" cl 2); rc=$?
eqv "sem diretorio: sai com 0"            "$rc" "0"
has "sem diretorio: nada a apagar"        "$out" "nada a apagar"

# MONITOR_LOG_DIR so na configuracao: usa o diretorio dela
prep; HC="$TMP/h-cl"; mkdir -p "$HC/.config"
printf 'RUN_MONITOR=1\nMONITOR_LOG_DIR="%s"\n' "$CL" > "$HC/.config/gamemode-tweaks.conf"
out=$(env -u MONITOR_LOG_DIR -u XDG_CONFIG_HOME HOME="$HC" XDG_RUNTIME_DIR="$TMP/cl-run" GH_TODAY=20261124 "$GMR" cleanlog 2 2>&1)
eqv "diretorio da configuracao"           "$(nfiles 20261120-)/$(nfiles 20261122-)" "0/2"
eqv "sem configuracao: ~/.monitor/log"    "$(env -u MONITOR_LOG_DIR -u XDG_CONFIG_HOME HOME="$TMP/cl-home" GH_TODAY=20261124 "$GMR" cleanlog 2 --check 2>&1)" \
  "nada a apagar: nenhuma coleta anterior a 22/11/2026 em $TMP/cl-home/.monitor/log"

has "--help: mostra o cleanlog"           "$(HOME="$H" PATH="$H/.local/bin:$TMP/sysgames:$PATH" "$GMR" --help 2>&1)" "gamemoderun cleanlog <dias> [--check]"
eqv "jogo com nome parecido: repassa"     "$(gmr DISPLAY= -- cleanlogx 2)" "real: cleanlogx 2 []"

# ===========================================================================
group "monitor: ping e classificacao das travadas"
# ===========================================================================
H="$TMP/h1"; MON="$H/.local/bin/gamemode-monitor.sh"; TRV="$H/.local/bin/gamemode-travadas"
out=$(printf '%s\n' 'PING 192.168.0.1 (192.168.0.1) 56(84) bytes of data.' \
  '[1795379470.966021] 64 bytes from 192.168.0.1: icmp_seq=1 ttl=64 time=9.47 ms' \
  '[1795379471.959652] no answer yet for icmp_seq=2' | HOME="$H" "$MON" __ping_csv 192.168.0.1)
has "ping: cabecalho do CSV"              "$out" "timestamp,target,rtt_ms,lost"
has "ping: resposta com rtt e ms"         "$out" ".966,192.168.0.1,9.47,0"
has "ping: perdido marcado"               "$out" ".959,192.168.0.1,,1"
eqv "ping: ignora o resto"                "$(printf '%s\n' "$out" | wc -l)" "3"

# Coleta falsa de 10:00:00 a 10:02:00: GPU em 60% (amostra a cada 0,5 s) e ping
# de 3 ms. 10:00:30 a GPU cai (PC); 10:01:00 o ping dispara com a GPU normal
# (Wi-Fi); 10:01:40 nada muda (servidor).
L="$TMP/log1"; mkdir -p "$L"; C="$L/jogo-20261122-100000.csv"
awk 'BEGIN { print "timestamp,gpu_index,gpu_name,gpu_util_pct"
  for (t = 0; t < 120; t += 0.5) printf "2026-11-22T10:%02d:%06.3f,0,GPU,%d\n", t / 60, t % 60, (t >= 30 && t < 32) ? 2 : 60 }' > "$C"
awk 'BEGIN { print "timestamp,target,rtt_ms,lost"
  for (t = 0; t < 120; t++) printf "2026-11-22T10:%02d:%02d.100,gw,%s\n", t / 60, t % 60,
    t == 61 ? ",1" : (t >= 60 && t < 63) ? "300,0" : "3,0" }' > "${C%.csv}-ping.csv"
trv() { HOME="$H" MONITOR_LOG_DIR="$L" XDG_RUNTIME_DIR="$TMP/trv-run" PATH="$MOCKS:$PATH" "$TRV" "$@" 2>&1; }
out=$(trv)
has "detecta: usa a coleta mais recente"  "$out" "coleta: $C"
has "detecta: GPU parou -> PC"            "$out" "10:00:30  detectada PC"
has "detecta: ping disparou -> Wi-Fi"     "$out" "10:01:00  detectada Wi-Fi"
has "detecta: perdas no ping"             "$out" "1 perdido(s)"
has "detecta: total"                      "$out" "total: PC 1, Wi-Fi 1, servidor 0"
out=$(trv "$C" 10:01:42 10:00:33)
has "hora dada sem sinal -> servidor"     "$out" "10:01:42  dada      servidor"
has "hora dada na queda da GPU -> PC"     "$out" "10:00:33  dada      PC"
mkdir -p "$TMP/trv-run"
out=$(trv marcar); eqv "marcar sem coleta: recusa" "$?" "1"
echo "$C" > "$TMP/trv-run/gamemode-monitor.current"
trv marcar >/dev/null
eqv "marcar: grava ao lado da coleta"     "$(wc -l < "${C%.csv}-marcas.txt")" "1"
echo "2026-11-22T10:01:04.000" > "${C%.csv}-marcas.txt"
has "marca no pico de ping -> Wi-Fi"      "$(trv)" "10:01:04  marcada   Wi-Fi"
rm "${C%.csv}-ping.csv"
out=$(trv 10:01:42)
has "sem ping: avisa"                     "$out" "so a GPU conta"
has "sem ping: nao chuta servidor"        "$out" "sem ping"
eqv "argumento invalido"                  "$(trv xyz >/dev/null; echo $?)" "2"

# ===========================================================================
group "desinstalacao"
# ===========================================================================
# uninst HOME [opcoes...]: roda o uninstall.sh com hardware falso
uninst() {
  local h="$1"; shift
  HOME="$h" PATH="$MOCKS:$PATH" XDG_SESSION_TYPE=x11 GH_ALLOW_USER=1 GH_ACPI_DIR="$TMP/sem-acpi" \
    GH_INTERACTIVE="${INTER:-}" MOCK_LOG="$h.log" GH_RUNTIME_DIR="$h/run" \
    "$ROOT/uninstall.sh" "$@" 2>&1
}
H="$TMP/u1"
mkdir -p "$H/.config"; echo "[general]" > "$H/.config/gamemode.ini"   # o de antes do install
inst "$H" --yes >/dev/null 2>&1 < /dev/null
inst "$H" --yes >/dev/null 2>&1 < /dev/null                          # sem mudanca: sem backup novo
mkdir -p "$H/run"; echo "PAUSED_SERVICES=lan.service" > "$H/run/gamemode-tweaks.state"
out=$(uninst "$H" --check)
has "--check: diz o que apagaria"         "$out" "apagaria:   $H/.local/bin/gamemoderun"
eqv "--check: nao apaga nada"             "$(ls "$H/.local/bin" | wc -l)" "7"
eqv "--check: nao desfaz o jogo ativo"    "$([[ -e "$H/run/gamemode-tweaks.state" ]] && echo sim)" "sim"
out=$(uninst "$H" --yes)
eqv "apaga os scripts"                    "$(ls "$H/.local/bin" | wc -l)" "0"
eqv "devolve o gamemode.ini de antes"     "$(cat "$H/.config/gamemode.ini")" "[general]"
eqv "apaga a configuracao"                "$([[ -e "$H/.config/gamemode-tweaks.conf" ]] && echo sim)" ""
eqv "desfaz o jogo ativo"                 "$([[ -e "$H/run/gamemode-tweaks.state" ]] && echo sim)" ""
has "religa o servico pausado"            "$(cat "$H.log")" "start lan.service"
has "lembra do rehash"                    "$out" "rehash"

H="$TMP/u2"
inst "$H" --yes >/dev/null 2>&1 < /dev/null
echo "x" > "$H/.local/bin/modo-jogo.bak-1"
out=$(uninst "$H" --yes --keep-config)
eqv "--keep-config: mantem a configuracao" "$([[ -e "$H/.config/gamemode-tweaks.conf" ]] && echo sim)" "sim"
eqv "sem gamemode.ini de antes: apaga"    "$([[ -e "$H/.config/gamemode.ini" ]] && echo sim)" ""
has "mantem os backups sem --purge"       "$out" "1 backup(s)"
uninst "$H" --yes --purge >/dev/null
eqv "--purge: apaga os backups"           "$(ls -A "$H/.local/bin")" ""

H="$TMP/u3"
inst "$H" --yes >/dev/null 2>&1 < /dev/null
INTER=1 uninst "$H" <<< "n" >/dev/null
eqv "pergunta: 'n' mantem a configuracao" "$([[ -e "$H/.config/gamemode-tweaks.conf" ]] && echo sim)" "sim"

H="$TMP/u4"; mkdir -p "$H/.config"
printf '[general]\nrenice=5\n' > "$H/.config/gamemode.ini"
out=$(uninst "$H" --yes)
has "gamemode.ini que nao e dos hooks: mantem" "$out" "nao chama os hooks"

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

# ===========================================================================
group "system/wifi-powersave"
# ===========================================================================
out=$(sh "$ROOT/system/wifi-powersave" wlan0 turbo 2>&1); eqv "recusa acao invalida" "$?" "2"
has "mostra o uso"                        "$out" "uso:"
sh "$ROOT/system/wifi-powersave" ../../etc off >/dev/null 2>&1; eqv "recusa caminho no nome" "$?" "2"
sh "$ROOT/system/wifi-powersave" -x off >/dev/null 2>&1;         eqv "recusa nome com hifen inicial" "$?" "2"
sh "$ROOT/system/wifi-powersave" lo off >/dev/null 2>&1;         eqv "recusa interface que nao e Wi-Fi" "$?" "1"

printf '\n\033[1m%d ok, %d falha(s)\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
