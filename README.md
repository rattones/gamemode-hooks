# gamemode-hooks

*[English](README.en.md)*

Scripts que o [GameMode](https://github.com/FeralInteractive/gamemode) roda ao
abrir e fechar um jogo iniciado com `gamemoderun %command%`: ajustes extras de
energia, GPU, monitores e serviços, e coleta de dados. O `gamemoderun` do
sistema (`/usr/games/gamemoderun`) continua sendo quem liga o GameMode; o deste
repositório, em `~/.local/bin`, vem antes no PATH e só acrescenta o `--help` e
a pergunta dos monitores ao abrir o jogo. Cada ajuste depende de um recurso e é
pulado onde ele não existe, e o instalador detecta o hardware para gerar a
configuração.

## O que acontece quando o jogo abre e fecha

| Ao abrir (`gamemode-start.sh`) | Ao fechar (`gamemode-end.sh`) | Precisa de |
|---|---|---|
| perfil de energia da plataforma no modo de desempenho | volta ao perfil anterior | notebook com ACPI `platform_profile` |
| PowerMizer da NVIDIA em "máximo desempenho" | volta ao modo anterior | NVIDIA com `nvidia-settings` |
| só o monitor do jogo ligado ou todos, conforme a resposta à pergunta do `gamemoderun`; os outros desligam (no X11, na maior taxa de atualização) | restaura o layout exato de antes | mais de um monitor; X11 com `xrandr` ou Wayland com `kscreen-doctor` (KDE), `gdctl` (GNOME 48+) ou `wlr-randr` (wlroots) |
| desliga a economia de energia da placa Wi-Fi (menos picos de latência online) | religa, se estava ligada | placa Wi-Fi com `iw` ou `iwconfig` |
| pausa os serviços de usuário escolhidos | religa só os que pausou | systemd de usuário |
| inicia a coleta do [monitor](https://github.com/rattones/monitor) no PID do jogo, mais o ping até o roteador a cada segundo | encerra a coleta | `monitor` instalado; `ping` e `ip` |
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
| mais de um monitor (X11, ou Wayland do KDE, GNOME 48+ ou wlroots) | **pergunta** qual é o monitor do jogo, ou não mexer |
| um monitor só, ou sem ferramenta de monitores (`xrandr`; no Wayland, `kscreen-doctor`, `gdctl` ou `wlr-randr`) | não mexe nos monitores |
| placa Wi-Fi e `iw` ou `iwconfig` | economia de energia do Wi-Fi desligada no jogo (com mais de uma placa, a conectada) |
| `monitor` instalado | coleta ligada |
| serviços de usuário rodando | **pergunta** quais pausar durante o jogo |
| MangoHud ausente | **pergunta** se instala (pelo `apt-get`, `dnf`, `pacman` ou `zypper`); instalado, mostra como usar: `gamemoderun mangohud %command%` |

Com `--yes`, ou sem terminal, tudo o que seria pergunta fica desligado. Uma
configuração que já existe (`~/.config/gamemode-tweaks.conf`) não é trocada sem
você dizer: o instalador pergunta, e no modo `--yes` mantém a sua e grava a
detectada em `gamemode-tweaks.conf.detectado`. Todo arquivo trocado vira
`<arquivo>.bak-<data>` antes.

Os auxiliares que rodam como root o instalador só mostra, para você conferir
antes de rodar:

- copiar `system/platform-profile` e `system/wifi-powersave` para
  `/usr/local/bin/` (dono root);
- criar as regras `/etc/sudoers.d/platform-profile` e
  `/etc/sudoers.d/wifi-powersave`, que liberam só esses caminhos sem senha
  (conferidas com `visudo -c`).

Depois, `gamemoded -t` deve terminar em "All Tests Passed". No jogo (Steam →
Propriedades → Opções de inicialização): `gamemoderun %command%`.

Para atualizar, basta rodar o `sudo ./install.sh` de novo: os scripts são
trocados e a sua configuração fica (as opções novas que faltarem nela valem com
o padrão). Num terminal que já estava aberto, rode `rehash` (zsh) ou `hash -r`
(bash) para o shell achar o `gamemoderun` de `~/.local/bin`.

### Um ou todos os monitores, na hora

Com um monitor do jogo escolhido, cada jogo aberto pelo `gamemoderun` começa
com uma pergunta em tela: **"Só o <monitor>"** ou **"Todos os monitores"**. Sem
resposta em 15 s (`ASK_TIMEOUT`), fica só o monitor do jogo. A pergunta usa o
`zenity` (ou o `kdialog` no KDE) e funciona no X11 e no Wayland; não aparece
quando já há um monitor só ligado, nem quando outro jogo já trocou os monitores.

Para não perguntar num jogo, fixe a resposta nas opções de inicialização dele:

```
GAMEMODE_SINGLE_MONITOR=0 gamemoderun %command%   # todos os monitores
GAMEMODE_SINGLE_MONITOR=1 gamemoderun %command%   # só o do jogo
```

Para nunca perguntar, `ASK_MONITOR=0` no `gamemode-tweaks.conf`.

A resposta vai no ambiente do jogo, em `GAMEMODE_SINGLE_MONITOR`. O hook não é
filho do jogo (quem o roda é o `gamemoded`), então ele procura a variável no
ambiente dos processos abertos pelo `gamemoderun`. No `modo-jogo`, que não
pergunta, vale o mesmo: `GAMEMODE_SINGLE_MONITOR=0 modo-jogo on`.

No Wayland a troca usa a ferramenta da área de trabalho: `kscreen-doctor`
(KDE Plasma), `gdctl` (GNOME 48 ou mais novo) ou `wlr-randr` (Sway e outros
wlroots). Lá só liga e desliga os monitores; a resolução e a taxa ficam como
estão. Cinnamon, XFCE e afins no Wayland não têm ferramenta, e os monitores
ficam como estão.

Para ver como iniciar os jogos, as opções por jogo e o que está ligado nesta
máquina: `gamemoderun --help` (ou `-h`).

## Configuração

As opções ficam em `~/.config/gamemode-tweaks.conf`, gerado pelo instalador e
comentado. Uma mudança vale no próximo jogo, sem reiniciar nada.

| Opção | Padrão | O que faz |
|---|---|---|
| `GAME_MONITOR` | (detectado) | monitor onde o jogo roda; vazio = não mexer nos monitores |
| `SINGLE_MONITOR` | `1` com monitor escolhido | deixa só o `GAME_MONITOR` ligado durante o jogo |
| `ASK_MONITOR` | `1` | pergunta ao abrir o jogo: só o `GAME_MONITOR` ou todos; `0` = não pergunta |
| `ASK_TIMEOUT` | `15` | segundos até a pergunta ficar no padrão (só o `GAME_MONITOR`) |
| `GAME_REFRESH` | `auto` | taxa no monitor do jogo (só X11): `auto` = a maior, ou um valor como `59.98` |
| `SET_PLATFORM_PROFILE` | (detectado) | troca o perfil de energia da plataforma durante o jogo |
| `PERF_PROFILE` | `performance` | perfil usado, um dos de `platform_profile_choices` |
| `PROFILE_HELPER` | (detectado) | quem grava o perfil como root, via `sudo -n` |
| `SET_POWERMIZER` | (detectado) | PowerMizer da NVIDIA em "máximo desempenho" |
| `NOTIFY_VRAM` / `VRAM_WARN_PCT` | (detectado) / `78` | alerta quando a VRAM livre fica abaixo dessa % da total |
| `SET_WIFI_POWERSAVE` / `WIFI_IFACE` | (detectado) | desliga a economia de energia dessa placa Wi-Fi durante o jogo |
| `PAUSE_SERVICES` | (vazio) | serviços de usuário pausados durante o jogo, separados por espaço |
| `RUN_MONITOR` / `MONITOR_BIN` | (detectado) | coleta com o [monitor](https://github.com/rattones/monitor) e onde ele está |
| `MONITOR_MIN_RSS_MB` / `MONITOR_WAIT_S` | `300` / `180` | o jogo é o processo de maior RSS; espera ele passar desse tamanho ou desse tempo |
| `MONITOR_ARGS` | `-q` | opções extras do monitor (ex.: `-q -i 1000`) |
| `MONITOR_PERF` | `auto` | `perf` junto (`monitor -P`): `auto` = quando liberado, `1` = sempre, `0` = nunca |
| `MONITOR_PING` | `auto` | ping a cada segundo durante a coleta: `auto` = o roteador da rota padrão, ou um IP/host; `0` = não grava |

## Classificar as travadas

Durante a coleta, o `gamemode-monitor.sh` grava também o ping até o roteador a
cada segundo, em `~/.monitor/log/<jogo>-<data>-ping.csv`, ao lado dos CSVs do
monitor. O `gamemode-travadas` cruza esse ping com a GPU e diz de onde veio
cada travada:

| GPU | Ping ao roteador | Causa |
|---|---|---|
| parou (caiu para menos de 30% do uso de antes, ou o monitor ficou sem amostra) | — | **PC** |
| seguiu | disparou (4× o normal e +50 ms, ou pacote perdido) | **Wi-Fi** (ou rede local) |
| seguiu | normal | **servidor** (ou a internet depois do roteador) |

```bash
gamemode-travadas                       # coleta mais recente: procura sozinho as travadas
gamemode-travadas 21:14:05 21:20:41     # classifica as horas em que você sentiu a travada
gamemode-travadas ~/.monitor/log/dota2-20261122-162057.csv
gamemode-travadas marcar                # durante o jogo: "travou agora"
```

Sozinho, ele só acha o que deixa rastro na máquina (GPU parada ou ping
disparado), e telas de carregamento ou menus também derrubam a GPU. Travada de
servidor não deixa rastro: precisa da hora. O jeito mais prático é pôr
`gamemode-travadas marcar` num atalho de teclado do sistema e apertá-lo quando
travar; as marcas ficam em `<jogo>-<data>-marcas.txt` e entram na análise sem
precisar digitar a hora. Coletas anteriores ao registro do ping são analisadas
só pela GPU.

## Desinstalar

```bash
sudo ./uninstall.sh                 # pergunta se apaga a configuração
sudo ./uninstall.sh --yes           # sem perguntas: apaga tudo
sudo ./uninstall.sh --check         # só mostra o que apagaria
sudo ./uninstall.sh --keep-config   # mantém o ~/.config/gamemode-tweaks.conf
sudo ./uninstall.sh --purge         # apaga também os backups .bak-*
```

Se um jogo (ou o `modo-jogo`) ainda estiver ativo, os ajustes são desfeitos
primeiro. Depois saem os scripts de `~/.local/bin` e a configuração; o
`gamemode.ini` que existia antes do instalador volta do backup (sem ele, o dos
hooks é apagado). Com `sudo`, também saem os `/usr/local/bin/platform-profile` e
`/usr/local/bin/wifi-powersave` e as regras do `/etc/sudoers.d/`; sem, os
comandos são mostrados. O
grupo `gamemode` e o próprio GameMode ficam, porque servem sem os hooks. É o
mesmo que `sudo ./install.sh --uninstall`.

## Arquivos

| Arquivo | Vai para | Papel |
|---|---|---|
| `bin/gamemode-start.sh` | `~/.local/bin/` | hook de início |
| `bin/gamemode-end.sh` | `~/.local/bin/` | hook de fim: desfaz o start |
| `bin/gamemode-monitor.sh` | `~/.local/bin/` | acha o PID do jogo pelo D-Bus do GameMode (`ListGames`, mais os filhos, escolhendo o de maior RSS, porque com Proton o jogo é filho dos wrappers da Steam) e roda `monitor all -f pid:N`; com `MONITOR_PERF=auto` acrescenta `-P` quando o `perf` está liberado; grava o ping até o roteador ao lado |
| `bin/gamemode-travadas` | `~/.local/bin/` | classifica as travadas de uma coleta (PC, Wi-Fi ou servidor) e marca "travou agora" durante o jogo |
| `bin/gamemoderun` | `~/.local/bin/` | embrulho do `gamemoderun` do sistema: pergunta em tela se o jogo usa um ou todos os monitores e repassa tudo para o `/usr/games/gamemoderun`; `gamemoderun --help` (ou `-h`) explica como iniciar os jogos, as opções por jogo e mostra a configuração desta máquina |
| `bin/gamemode-displays.sh` | `~/.local/bin/` | lê, troca e restaura os monitores com a ferramenta da sessão (`xrandr`, `kscreen-doctor`, `gdctl` ou `wlr-randr`); usado pelos hooks, pelo `gamemoderun` e pelo instalador |
| `bin/modo-jogo` | `~/.local/bin/` | liga, desliga ou mostra os mesmos ajustes à mão: `modo-jogo on\|off\|toggle\|status` |
| `uninstall.sh` | — | desinstala: atalho para `install.sh --uninstall` |
| `config/gamemode.ini` | `~/.config/` | configuração do GameMode: governor, renice e os caminhos dos hooks (`@HOME@` vira a sua home) |
| (gerado) `gamemode-tweaks.conf` | `~/.config/` | as opções dos hooks, comentadas; vale no próximo jogo, sem reiniciar nada |
| `system/platform-profile` | `/usr/local/bin/` (root) | grava o perfil em `/sys/firmware/acpi/platform_profile`, aceitando só os nomes de `platform_profile_choices` |
| `system/sudoers-platform-profile` | `/etc/sudoers.d/platform-profile` | modelo da regra do sudo |
| `system/wifi-powersave` | `/usr/local/bin/` (root) | liga, desliga ou consulta a economia de energia de uma placa Wi-Fi (`iw`, ou `iwconfig`), aceitando só interfaces que o kernel lista como Wi-Fi |
| `system/sudoers-wifi-powersave` | `/etc/sudoers.d/wifi-powersave` | modelo da regra do sudo |
| `tests/` | — | testes do instalador e dos hooks contra hardware falso: `./tests/run-tests.sh` |

## Dependências

- `gamemode`, `busctl` (systemd), `notify-send`
- conforme o hardware: `xrandr` (X11) ou, no Wayland, `kscreen-doctor` (KDE),
  `gdctl` (GNOME 48+) ou `wlr-randr` (wlroots); `nvidia-settings` e
  `nvidia-smi` (NVIDIA); `iw` ou `iwconfig` (Wi-Fi)
- `zenity` ou `kdialog`, para a pergunta dos monitores
- [monitor](https://github.com/rattones/monitor) em `~/.local/bin/monitor`,
  para a coleta
- opcional: [MangoHud](https://github.com/flightlessmango/MangoHud), para ver
  FPS, frametime, GPU e CPU no jogo (`gamemoderun mangohud %command%`)

## Notas

- A seção `[gpu]` do GameMode procura a GPU em `card0` e falha onde a NVIDIA é
  outro `cardN` (comum com iGPU ou MUX). Por isso o PowerMizer é ajustado pelo
  start com `nvidia-settings`.
- Instalações anteriores usavam `/usr/local/bin/legion-profile`; os hooks e o
  instalador continuam aceitando esse nome quando ele está liberado no sudoers.
- A economia de energia do Wi-Fi é desligada só na interface, até o fim do
  jogo. Se o Wi-Fi reconectar no meio dele, o NetworkManager aplica de novo a
  própria configuração (`wifi.powersave`) e a economia pode voltar.
- A Steam põe o próprio runtime (com um `zenity` antigo e as bibliotecas dela)
  no começo do PATH dos jogos. A pergunta dos monitores usa o `zenity` do
  sistema e roda sem o `LD_PRELOAD` e o `LD_LIBRARY_PATH` da Steam.
- A pergunta só aparece em jogos abertos pelo `gamemoderun` deste repositório.
  Um launcher que liga o GameMode por conta própria (sem chamar o
  `gamemoderun` do PATH) não passa por ela: ali vale o padrão, só o monitor do
  jogo, ou o `GAMEMODE_SINGLE_MONITOR` das opções do jogo.
- As travadas de ~3 s no Dota 2 que motivaram a coleta não eram destes ajustes:
  eram o TSC do CPU 0 atrasado pelo BIOS. Ver
  [ValveSoftware/Dota-2#3558](https://github.com/ValveSoftware/Dota-2/issues/3558).
