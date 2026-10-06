# gamemode-hooks

*[English](README.en.md)*

Scripts que o [GameMode](https://github.com/FeralInteractive/gamemode) roda ao
abrir e fechar um jogo iniciado com `gamemoderun %command%`. O `gamemoderun` em
si é do sistema (`/usr/games/gamemoderun`); aqui ficam os ajustes extras e a
coleta de dados. Cada ajuste depende de um recurso e é pulado onde ele não
existe, e o instalador detecta o hardware para gerar a configuração.

## O que acontece quando o jogo abre e fecha

| Ao abrir (`gamemode-start.sh`) | Ao fechar (`gamemode-end.sh`) | Precisa de |
|---|---|---|
| perfil de energia da plataforma no modo de desempenho | volta ao perfil anterior | notebook com ACPI `platform_profile` |
| PowerMizer da NVIDIA em "máximo desempenho" | volta ao modo anterior | NVIDIA com `nvidia-settings` |
| só o monitor do jogo ligado, na maior taxa de atualização | restaura o layout exato de antes | X11 com `xrandr`, mais de um monitor |
| pausa os serviços de usuário escolhidos | religa só os que pausou | systemd de usuário |
| inicia a coleta do [monitor](https://github.com/rattones/monitor) no PID do jogo | encerra a coleta | `monitor` instalado |
| notificação com a VRAM livre, alerta abaixo de 78% | notificação de que tudo foi restaurado | `nvidia-smi` |

O estado anterior fica em `$XDG_RUNTIME_DIR/gamemode-tweaks.state`. Como o
GameMode dispara start/end várias vezes enquanto a Steam sobe, o start preserva
o estado já capturado, para o end restaurar o valor original e não um já
modificado.

O próprio GameMode, pelo `gamemode.ini`, ainda põe o governor da CPU em
`performance`, dá `renice` e prioridade de tempo real suave ao jogo e inibe o
protetor de tela.

## Instalar

```bash
sudo ./install.sh                 # detecta o hardware, pergunta o que for dúvida, instala
sudo ./install.sh --check         # só mostra o que detectou e o que mudaria
sudo ./install.sh --yes           # sem perguntas: aplica só o que é certo
sudo ./install.sh --reconfigure   # gera de novo a configuração
```

Precisa do `sudo` porque põe o seu usuário no grupo `gamemode` (`usermod`): o
polkit do GameMode no Ubuntu só deixa trocar o governor da CPU para quem está
nesse grupo, e sem isso o `gamemoded -t` falha com "Not authorized". O grupo
vale a partir do próximo login. Rodado direto como root, sem `sudo`, ele recusa:
os arquivos vão para a home de quem chamou o `sudo`, com essa pessoa como dona,
e a detecção de monitores e serviços roda como ela, na sessão gráfica dela.

O instalador detecta e vira pré-configuração:

| O que detecta | Como fica |
|---|---|
| `platform_profile` com o perfil `performance` | ligado, com `performance` |
| `platform_profile` com outros nomes (`quiet`, `balanced-performance`...) | **pergunta** qual usar, ou nenhum |
| sem `platform_profile` | desligado |
| NVIDIA com `nvidia-settings` | PowerMizer e alerta de VRAM ligados |
| NVIDIA sem `nvidia-settings` | só o alerta de VRAM |
| X11 com mais de um monitor | **pergunta** qual monitor usar no jogo, ou não mexer |
| um monitor só, Wayland ou sem `xrandr` | não mexe nos monitores |
| `monitor` instalado | coleta ligada |
| serviços de usuário rodando | **pergunta** quais pausar durante o jogo |

Com `--yes`, ou sem terminal, tudo o que seria pergunta fica desligado. Uma
configuração que já existe (`~/.config/gamemode-tweaks.conf`) não é trocada sem
você dizer: o instalador pergunta, e no modo `--yes` mantém a sua e grava a
detectada em `gamemode-tweaks.conf.detectado`. Todo arquivo trocado vira
`<arquivo>.bak-<data>` antes.

O auxiliar de perfil de energia o instalador só mostra, para você conferir
antes de rodar:

- copiar `system/platform-profile` para `/usr/local/bin/` (dono root);
- criar a regra `/etc/sudoers.d/platform-profile`, que libera só esse
  caminho sem senha (conferida com `visudo -c`).

Depois, `gamemoded -t` deve terminar em "All Tests Passed". No jogo (Steam →
Propriedades → Opções de inicialização): `gamemoderun %command%`.

## Arquivos

| Arquivo | Vai para | Papel |
|---|---|---|
| `bin/gamemode-start.sh` | `~/.local/bin/` | hook de início |
| `bin/gamemode-end.sh` | `~/.local/bin/` | hook de fim: desfaz o start |
| `bin/gamemode-monitor.sh` | `~/.local/bin/` | acha o PID do jogo pelo D-Bus do GameMode (`ListGames`, mais os filhos, escolhendo o de maior RSS, porque com Proton o jogo é filho dos wrappers da Steam) e roda `monitor all -f pid:N`; com `MONITOR_PERF=auto` acrescenta `-P` quando o `perf` está liberado |
| `bin/modo-jogo` | `~/.local/bin/` | liga, desliga ou mostra os mesmos ajustes à mão: `modo-jogo on\|off\|toggle\|status` |
| `config/gamemode.ini` | `~/.config/` | configuração do GameMode: governor, renice e os caminhos dos hooks (`@HOME@` vira a sua home) |
| (gerado) `gamemode-tweaks.conf` | `~/.config/` | as opções dos hooks, comentadas; vale no próximo jogo, sem reiniciar nada |
| `system/platform-profile` | `/usr/local/bin/` (root) | grava o perfil em `/sys/firmware/acpi/platform_profile`, aceitando só os nomes de `platform_profile_choices` |
| `system/sudoers-platform-profile` | `/etc/sudoers.d/platform-profile` | modelo da regra do sudo |
| `tests/` | — | testes do instalador e dos hooks contra hardware falso: `./tests/run-tests.sh` |

## Dependências

- `gamemode`, `busctl` (systemd), `notify-send`
- conforme o hardware: `xrandr` (X11), `nvidia-settings` e `nvidia-smi` (NVIDIA)
- [monitor](https://github.com/rattones/monitor) em `~/.local/bin/monitor`,
  para a coleta

## Notas

- A seção `[gpu]` do GameMode procura a GPU em `card0` e falha onde a NVIDIA é
  outro `cardN` (comum com iGPU ou MUX). Por isso o PowerMizer é ajustado pelo
  start com `nvidia-settings`.
- Instalações anteriores usavam `/usr/local/bin/legion-profile`; os hooks e o
  instalador continuam aceitando esse nome quando ele está liberado no sudoers.
- As travadas de ~3 s no Dota 2 que motivaram a coleta não eram destes ajustes:
  eram o TSC do CPU 0 atrasado pelo BIOS. Ver
  [ValveSoftware/Dota-2#3558](https://github.com/ValveSoftware/Dota-2/issues/3558).
