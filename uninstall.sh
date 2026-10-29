#!/usr/bin/env bash
#
# uninstall.sh - desinstala os hooks do GameMode (atalho para install.sh --uninstall).
#
#   sudo ./uninstall.sh                 # pergunta se apaga a configuracao
#   sudo ./uninstall.sh --yes           # sem perguntas: apaga tudo
#   sudo ./uninstall.sh --check         # so mostra o que apagaria
#   sudo ./uninstall.sh --keep-config   # mantem o ~/.config/gamemode-tweaks.conf
#   sudo ./uninstall.sh --purge         # apaga tambem os backups .bak-*
#
# Desliga os ajustes de um jogo ainda ativo, apaga os scripts de ~/.local/bin,
# devolve o gamemode.ini que existia antes do install (ou apaga o dos hooks) e,
# com sudo, tira o /usr/local/bin/platform-profile e a regra do sudoers. O grupo
# gamemode e o proprio GameMode ficam.

case "${1:-}" in
  -h|--help) sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
exec "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/install.sh" --uninstall "$@"
