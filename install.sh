#!/usr/bin/env bash
#
# install.sh - instala os hooks do GameMode e gera a configuracao a partir do
# hardware desta maquina.
#
#   sudo ./install.sh                 # detecta, pergunta o que for duvida, instala
#   sudo ./install.sh --yes           # sem perguntas: so aplica o que e certo
#   sudo ./install.sh --check         # so mostra o que detectou e o que mudaria
#   sudo ./install.sh --reconfigure   # gera de novo o gamemode-tweaks.conf
#
# Roda com sudo porque poe o usuario no grupo gamemode (usermod), que o polkit
# do GameMode exige para trocar o governor da CPU. Os arquivos continuam sendo
# do usuario que chamou o sudo e vao para a home dele, nao para a do root.
#
# O que e detectado e vira pre-configuracao:
#   - perfil de energia da plataforma (ACPI platform_profile) e os nomes que o
#     firmware oferece
#   - placa NVIDIA (nvidia-smi, nvidia-settings): PowerMizer e alerta de VRAM
#   - sessao X11 ou Wayland e monitores conectados (xrandr)
#   - o monitor (github.com/rattones/monitor), para coletar dados do jogo
#
# O que e duvida vira pergunta: qual monitor usar no jogo quando ha mais de um,
# qual perfil de energia quando o firmware nao tem "performance", e quais
# servicos pausar durante o jogo. Com --yes (ou sem terminal), o que e duvida
# fica desligado.
#
# O auxiliar platform-profile e a regra do sudoers so sao mostrados: os comandos
# ficam para voce conferir e rodar. Arquivo que ja existe e e diferente vira
# <arquivo>.bak-<data> antes de ser trocado.

set -uo pipefail

SRC="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
# Raiz do ACPI no sysfs (so os testes trocam).
ACPI_DIR="${GH_ACPI_DIR:-/sys/firmware/acpi}"
HELPER=/usr/local/bin/platform-profile
LEGACY_HELPER=/usr/local/bin/legion-profile

ARGS=("$@")
CHECK=0; YES=0; RECONF=0
while (( $# )); do
  case "$1" in
    --check)       CHECK=1 ;;
    --yes|-y)      YES=1 ;;
    --reconfigure) RECONF=1 ;;
    -h|--help)     sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcao desconhecida: $1 (veja --help)" >&2; exit 2 ;;
  esac
  shift
done

# --- root, mas para o usuario que chamou o sudo -----------------------------------
# O usermod precisa de root; todo o resto e do usuario: a home dele, os arquivos
# com ele como dono, e as deteccoes que dependem da sessao dele (monitores,
# servicos, o que o sudo libera para ele) rodam como ele. GH_ALLOW_USER=1 deixa
# os testes rodarem sem root, tratando o proprio usuario como o alvo.
if (( EUID != 0 )) && [[ "${GH_ALLOW_USER:-}" != 1 ]]; then
  echo "rode com sudo: sudo $0 ${ARGS[*]}" >&2
  exit 1
fi
if (( EUID == 0 )); then
  TU="${SUDO_USER:-}"
  if [[ -z "$TU" || "$TU" == root ]]; then
    echo "rode com sudo a partir do seu usuario (sudo $0), nao direto como root:" >&2
    echo "os hooks sao instalados na home de quem chamou o sudo." >&2
    exit 1
  fi
else
  TU="$(id -un)"
fi
TUID="$(id -u "$TU")"
TGROUP="$(id -gn "$TU")"
THOME="$(getent passwd "$TU" | cut -d: -f6)"
[[ -d "$THOME" ]] || { echo "nao achei a home de $TU" >&2; exit 1; }
# Nos testes a home e a HOME falsa; com sudo de verdade, a do passwd.
(( EUID == 0 )) || THOME="$HOME"

BIN_DIR="$THOME/.local/bin"
CONF_DIR="$THOME/.config"
CONF="$CONF_DIR/gamemode-tweaks.conf"

# as_user CMD...: roda como o usuario alvo, com o ambiente da sessao dele (o sudo
# limpa DISPLAY e XDG_RUNTIME_DIR, e sem eles nem xrandr nem systemctl --user
# enxergam a sessao).
as_user() {
  local env=(HOME="$THOME" DISPLAY="${DISPLAY:-:0}" XDG_RUNTIME_DIR="/run/user/$TUID"
             PATH="$PATH") xa
  # Autorizacao do X: ~/.Xauthority (LightDM e outros) ou a do GDM.
  for xa in "${XAUTHORITY:-}" "$THOME/.Xauthority" "/run/user/$TUID/gdm/Xauthority"; do
    [[ -n "$xa" && -r "$xa" ]] && { env+=(XAUTHORITY="$xa"); break; }
  done
  if [[ "$(id -un)" == "$TU" ]]; then env "${env[@]}" "$@"
  else sudo -u "$TU" env "${env[@]}" "$@"; fi
}

# Tipo da sessao: o sudo tira o XDG_SESSION_TYPE do ambiente, entao pergunta ao
# logind pela sessao grafica do usuario.
session_type() {
  local s
  [[ -n "${XDG_SESSION_TYPE:-}" ]] && { echo "$XDG_SESSION_TYPE"; return; }
  s=$(loginctl show-user "$TU" -p Display --value 2>/dev/null)
  [[ -n "$s" ]] && s=$(loginctl show-session "$s" -p Type --value 2>/dev/null)
  echo "${s:-x11}"
}

# Pergunta so com alguem do outro lado: terminal no stdin, ou GH_INTERACTIVE=1
# (testes). --yes e --check nunca perguntam.
INTERACTIVE=0
if (( ! YES && ! CHECK )) && { [[ -t 0 ]] || [[ "${GH_INTERACTIVE:-}" == 1 ]]; }; then
  INTERACTIVE=1
fi

# ask "pergunta" padrao -> resposta (o padrao quando Enter ou sem terminal)
ask() {
  local q="$1" def="$2" a
  if (( ! INTERACTIVE )); then printf '%s\n' "$def"; return; fi
  printf '%s ' "$q" >&2
  IFS= read -r a || a=""
  printf '%s\n' "${a:-$def}"
}

note() { printf '  %s\n' "$*"; }

# O que o sudo libera sem senha para o usuario alvo (como root, o "sudo -l"
# simples responderia pelo root, que pode tudo).
user_can_sudo() {
  if (( EUID == 0 )); then sudo -n -l -U "$TU" "$1" >/dev/null 2>&1
  else sudo -n -l "$1" >/dev/null 2>&1; fi
}

# --- deteccao ----------------------------------------------------------------

echo "Detectando o hardware..."

# Perfil de energia: so com platform_profile; "performance" e o caso certo, e
# outro nome e duvida (cada fabricante usa os seus).
SET_PLATFORM_PROFILE=0; PERF_PROFILE=performance; PROFILE_HELPER=""
if [[ -r "$ACPI_DIR/platform_profile" && -r "$ACPI_DIR/platform_profile_choices" ]]; then
  read -ra CHOICES < "$ACPI_DIR/platform_profile_choices"
  note "perfil de energia: sim (atual: $(cat "$ACPI_DIR/platform_profile"); opcoes: ${CHOICES[*]})"
  if [[ " ${CHOICES[*]} " == *" performance "* ]]; then
    SET_PLATFORM_PROFILE=1
  else
    note "  o firmware nao tem \"performance\"; qual usar durante o jogo?"
    i=0; for c in "${CHOICES[@]}"; do i=$((i + 1)); note "    $i) $c"; done
    note "    0) nao mudar o perfil"
    (( INTERACTIVE )) || note "  (sem pergunta - --yes, --check ou sem terminal: nao muda o perfil)"
    r=$(ask "  escolha [0]:" 0)
    if [[ "$r" =~ ^[0-9]+$ ]] && (( r >= 1 && r <= ${#CHOICES[@]} )); then
      SET_PLATFORM_PROFILE=1; PERF_PROFILE="${CHOICES[r-1]}"
    fi
  fi
  # Quem grava o perfil como root. O nome antigo (legion-profile) segue valendo
  # numa maquina que ja tinha a regra no sudoers.
  if user_can_sudo "$HELPER"; then PROFILE_HELPER="$HELPER"
  elif user_can_sudo "$LEGACY_HELPER"; then PROFILE_HELPER="$LEGACY_HELPER"
  fi
else
  note "perfil de energia: nao (sem $ACPI_DIR/platform_profile)"
fi

# NVIDIA: o PowerMizer precisa do nvidia-settings; o alerta de VRAM, do nvidia-smi.
SET_POWERMIZER=0; NOTIFY_VRAM=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  NOTIFY_VRAM=1
  note "NVIDIA: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"
  if command -v nvidia-settings >/dev/null 2>&1 && nvidia-settings --version >/dev/null 2>&1; then
    SET_POWERMIZER=1
  else
    note "  sem nvidia-settings: o PowerMizer fica desligado (pacote nvidia-settings)"
  fi
else
  note "NVIDIA: nao"
fi

# Monitores: so X11 com xrandr; com um monitor so, nao ha o que trocar.
SINGLE_MONITOR=0; GAME_MONITOR=""
session="$(session_type)"
if [[ "$session" == wayland ]]; then
  note "sessao: Wayland - a troca de monitores (xrandr) fica desligada"
elif command -v xrandr >/dev/null 2>&1 && as_user xrandr --query >/dev/null 2>&1; then
  mapfile -t OUTS < <(as_user xrandr --query | awk '/ connected/{
    r = ""; for (i = 3; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { split($i, g, "+"); r = g[1]; break }
    print $1 "|" (r == "" ? "desligado" : r) }')
  note "sessao: X11, ${#OUTS[@]} monitor(es): $(printf '%s ' "${OUTS[@]%%|*}")"
  if (( ${#OUTS[@]} > 1 )); then
    note "  durante o jogo, deixar so um monitor ligado (libera VRAM e evita"
    note "  conflito de taxa de atualizacao)? qual?"
    i=0; for o in "${OUTS[@]}"; do i=$((i + 1)); note "    $i) ${o%%|*} (${o#*|})"; done
    note "    0) nao mexer nos monitores"
    (( INTERACTIVE )) || note "  (sem pergunta - --yes, --check ou sem terminal: nao mexe nos monitores)"
    r=$(ask "  escolha [0]:" 0)
    if [[ "$r" =~ ^[0-9]+$ ]] && (( r >= 1 && r <= ${#OUTS[@]} )); then
      SINGLE_MONITOR=1; GAME_MONITOR="${OUTS[r-1]%%|*}"
    fi
  fi
else
  note "sessao: sem xrandr - a troca de monitores fica desligada"
fi

# Coleta com o monitor: so se ele estiver instalado. A busca roda como o
# usuario (e quem vai executa-lo, pelo hook) e olha o ~/.local/bin dele e o PATH,
# o que cobre a instalacao padrao do monitor e a --system (/usr/local/bin).
RUN_MONITOR=0; MONITOR_BIN=""
MONITOR_BIN=$(as_user sh -c 'if [ -x "$HOME/.local/bin/monitor" ]; then echo "$HOME/.local/bin/monitor";
                             else command -v monitor; fi' 2>/dev/null)
if [[ -n "$MONITOR_BIN" ]] && mver=$(as_user "$MONITOR_BIN" --version 2>/dev/null) \
   && [[ "$mver" == monitor* ]]; then
  RUN_MONITOR=1
  note "monitor de dados: $mver em $MONITOR_BIN - coleta de dados ligada"
else
  MONITOR_BIN=""
  note "monitor de dados não instalado - coleta de dados desligada"
  note "para instalar, baixe o monitor em (https://github.com/rattones/monitor)"
fi

# Servicos a pausar: so a pessoa sabe quais atrapalham o jogo.
PAUSE_SERVICES=""
if (( INTERACTIVE )); then
  mapfile -t SVCS < <(as_user systemctl --user list-units --type=service --state=running --no-legend --plain 2>/dev/null \
                      | awk '{print $1}')
  if (( ${#SVCS[@]} )); then
    note "servicos de usuario rodando: ${SVCS[*]}"
    note "  algum atrapalha o jogo e deve pausar enquanto ele roda (ex.: um speedtest)?"
    r=$(ask "  nomes separados por espaco [nenhum]:" "")
    for s in $r; do
      [[ " ${SVCS[*]} " == *" $s "* || " ${SVCS[*]} " == *" $s.service "* ]] \
        && PAUSE_SERVICES="${PAUSE_SERVICES:+$PAUSE_SERVICES }$s" \
        || note "  ignorado (nao esta rodando): $s"
    done
  fi
fi

# --- configuracao gerada --------------------------------------------------------

write_conf() {
  cat <<EOF
# Ajustes que os hooks do GameMode aplicam nos jogos.
# Gerado por install.sh em $(date '+%Y-%m-%d %H:%M') a partir do hardware detectado.
# Mude os valores e o efeito vale no proximo jogo, sem reiniciar nada.

# Monitor onde o jogo roda: ele vira primario e os outros sao desligados (so
# X11). Vazio = nao mexer nos monitores. Nomes: xrandr --query | grep connected
GAME_MONITOR=$GAME_MONITOR
SINGLE_MONITOR=$SINGLE_MONITOR
# Taxa de atualizacao no monitor do jogo: "auto" usa a maior, ou fixe (ex.: 59.98).
GAME_REFRESH=auto

# Perfil de energia da plataforma durante o jogo (um de
# $ACPI_DIR/platform_profile_choices). Volta ao anterior no fim.
SET_PLATFORM_PROFILE=$SET_PLATFORM_PROFILE
PERF_PROFILE=$PERF_PROFILE
# Quem grava o perfil como root (via sudo -n); vazio = o padrao dos hooks.
PROFILE_HELPER=$PROFILE_HELPER

# NVIDIA: PowerMizer em "maximo desempenho" e alerta quando a VRAM livre fica
# abaixo de VRAM_WARN_PCT % da total.
SET_POWERMIZER=$SET_POWERMIZER
NOTIFY_VRAM=$NOTIFY_VRAM
VRAM_WARN_PCT=78

# Servicos de usuario (systemctl --user) pausados durante o jogo, separados por
# espaco, e religados no fim. Vazio = nenhum.
PAUSE_SERVICES="$PAUSE_SERVICES"

# Coleta com o monitor (github.com/rattones/monitor) presa ao PID do jogo.
# CSVs em ~/.monitor/log/<processo>-<data>*.csv
RUN_MONITOR=$RUN_MONITOR
# Onde esta o monitor; vazio = ~/.local/bin/monitor ou o do PATH.
MONITOR_BIN=$MONITOR_BIN
# O jogo e o processo de maior RSS entre os registrados no GameMode e seus
# filhos; espera ate ele passar deste tamanho (ou MONITOR_WAIT_S segundos).
MONITOR_MIN_RSS_MB=300
MONITOR_WAIT_S=180
# Opcoes extras do monitor (ex.: "-q -i 1000" para amostrar a cada 1 s).
MONITOR_ARGS="-q"
# perf junto (monitor -P): auto = so quando o perf esta liberado
# (sudo sysctl kernel.perf_event_paranoid=1, vale ate o reboot); 1 = sempre; 0 = nunca.
MONITOR_PERF=auto
EOF
}

# --- instalacao -------------------------------------------------------------------

for f in "$SRC"/bin/*; do
  bash -n "$f" || { echo "erro de sintaxe em $f - nada instalado" >&2; exit 1; }
done

# put <origem> <destino> <modo>: copia se mudou; guarda a versao anterior.
put() {
  local src="$1" dst="$2" mode="$3"
  if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then
    echo "igual:      $dst"; return 0
  fi
  if (( CHECK )); then
    [[ -e "$dst" ]] && echo "mudaria:    $dst" || echo "criaria:    $dst"
    return 0
  fi
  # Diretorios e arquivos com o usuario como dono, mesmo rodando como root.
  install -d -o "$TU" -g "$TGROUP" "$(dirname "$dst")"
  if [[ -e "$dst" ]]; then
    cp -p "$dst" "$dst.bak-$STAMP" && echo "backup:     $dst.bak-$STAMP"
  fi
  install -o "$TU" -g "$TGROUP" -m "$mode" "$src" "$dst" && echo "instalado:  $dst"
}

echo
for f in "$SRC"/bin/*; do
  put "$f" "$BIN_DIR/${f##*/}" 0755
done

tmp="$(mktemp)"
sed "s#@HOME@#${THOME}#g" "$SRC/config/gamemode.ini" > "$tmp"
put "$tmp" "$CONF_DIR/gamemode.ini" 0644

# A configuracao existente tem os ajustes da pessoa: so e trocada com
# --reconfigure ou se ela responder que sim.
write_conf > "$tmp"
if [[ -e "$CONF" ]] && (( ! RECONF )); then
  r=$(ask "ja existe $CONF. substituir pela configuracao detectada? [s/N]" n)
  if [[ "$r" == [sSyY]* ]]; then
    put "$tmp" "$CONF" 0644
  else
    if (( CHECK )); then
      echo "mantido:    $CONF  (--reconfigure troca pela detectada)"
    else
      install -o "$TU" -g "$TGROUP" -m 0644 "$tmp" "$CONF.detectado"
      echo "mantido:    $CONF  (a detectada ficou em $CONF.detectado)"
    fi
  fi
else
  put "$tmp" "$CONF" 0644
fi
rm -f "$tmp"

# --- grupo gamemode ---------------------------------------------------------------
# O polkit do GameMode no Ubuntu so deixa trocar o governor da CPU para quem esta
# no grupo gamemode; sem isso o "gamemoded -t" falha com "Not authorized". O
# grupo vem com o pacote gamemode.
echo
if ! getent group gamemode >/dev/null 2>&1; then
  echo "grupo gamemode: nao existe - instale o GameMode primeiro (sudo apt install gamemode)"
elif id -nG "$TU" | tr ' ' '\n' | grep -qx gamemode; then
  echo "grupo gamemode: $TU ja faz parte"
elif (( CHECK )); then
  echo "grupo gamemode: poria $TU no grupo (usermod -aG gamemode $TU)"
elif usermod -aG gamemode "$TU"; then
  echo "grupo gamemode: $TU adicionado - vale a partir do proximo login"
else
  echo "grupo gamemode: o usermod falhou; rode: sudo usermod -aG gamemode $TU" >&2
fi

# --- parte do sistema -------------------------------------------------------------

pending=()
if (( SET_PLATFORM_PROFILE )) && [[ -z "$PROFILE_HELPER" ]]; then
  pending+=("sudo install -o root -g root -m 0755 '$SRC/system/platform-profile' $HELPER")
  pending+=("sed \"s/@USER@/$TU/\" '$SRC/system/sudoers-platform-profile' | sudo tee /etc/sudoers.d/platform-profile >/dev/null")
  pending+=("sudo chmod 0440 /etc/sudoers.d/platform-profile && sudo visudo -cf /etc/sudoers.d/platform-profile")
fi

echo
if (( ${#pending[@]} )); then
  echo "Falta a parte do sistema (rode voce mesmo):"
  printf '  %s\n' "${pending[@]}"
else
  echo "Parte do sistema: nada pendente."
fi
[[ "$PROFILE_HELPER" == "$LEGACY_HELPER" ]] && \
  echo "(usando o $LEGACY_HELPER que ja existia; o $HELPER e a versao generica)"
echo
echo "No jogo (Steam > Propriedades > Opcoes de inicializacao): gamemoderun %command%"
echo "Teste do GameMode: gamemoded -t   (deve terminar em \"All Tests Passed\")"
