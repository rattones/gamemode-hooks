# Plano: 005, comando gamemoderun cleanlog N para apagar coletas antigas

Tarefa: [#5](https://github.com/rattones/gamemode-hooks/issues/5). Decisões: [decisoes/005.md](../decisoes/005.md). Situação: **aprovado em 24/11/2026**.

## Objetivo

1. Ter um comando no terminal que apague as coletas antigas do monitor e mantenha só as dos últimos N dias: `gamemoderun cleanlog 2`.
2. Motivo: as coletas em `~/.monitor/log/` só crescem, de 16 a 59 MB por dia de jogo, e hoje é preciso apagar à mão.

## Fatos levantados (24/11/2026)

Conferido com `ls`, `du` e `date -r` em `~/.monitor/log/`, e lendo `bin/gamemoderun`, `bin/gamemode-monitor.sh` e `bin/gamemode-travadas`.

**Onde ficam os logs.** O `gamemode-monitor.sh` grava cada sessão em `$MONITOR_LOG_DIR` (padrão `~/.monitor/log`). O nome é `<jogo>-AAAAMMDD-HHMMSS` mais um sufixo:

| Arquivo | Quem grava |
|---|---|
| `<sessão>.csv`, `-sys.csv`, `-disk.csv`, `-procs.csv`, `-threads.csv` | o monitor |
| `<sessão>.log` | a saída do monitor (hoje sempre vazia) |
| `<sessão>-ping.csv` | o ping ao roteador (desde a #2) |
| `<sessão>-marcas.txt` | `gamemode-travadas marcar` |

**O que existe hoje:** 407 MB em 152 arquivos, 24 sessões do `dota2`, nenhum arquivo fora do padrão.

| Dia da sessão | Arquivos | Tamanho |
|---|---|---|
| 11/11 | 6 | 16 MB |
| 12/11 | 6 | 32 MB |
| 13/11 | 6 | 39 MB |
| 14/11 | 6 | 38 MB |
| 15/11 | 6 | 20 MB |
| 16/11 | 12 | 35 MB |
| 17/11 | 12 | 35 MB |
| 18/11 | 30 | 46 MB |
| 22/11 | 19 | 43 MB |
| 23/11 | 28 | 59 MB |
| 24/11 | 21 | 50 MB |

O `-threads.csv` é o maior: de 14 a 35 MB por sessão.

Com `cleanlog 2` em 24/11, que mantém 22, 23 e 24/11, seriam apagados **84 arquivos (261 MB)** e ficariam 68 (152 MB).

**A data não pode vir do mtime.** A sessão `dota2-20261113-231110` passou da meia-noite: os CSVs têm mtime de 14/11 e o `.log`, de 13/11. Pelo mtime, um corte em 14/11 apagaria o `.log` e deixaria os CSVs da mesma sessão. A data de início no nome é a mesma para todos os arquivos da sessão.

**A sessão em andamento é conhecida.** Durante a coleta, o `gamemode-monitor.sh` grava o CSV atual em `$XDG_RUNTIME_DIR/gamemode-monitor.current` e o apaga no fim (linhas 115 e 157). O `gamemode-travadas` já usa esse arquivo.

**Situação do `gamemoderun`.** O primeiro argumento é sempre o comando do jogo, e só `-h`/`--help`/vazio são tratados antes de chamar o do sistema. Não existe programa `cleanlog` no PATH desta máquina. O GameMode estava inativo (`gamemoded -s`) e não havia coleta em andamento.

**Conclusão:** o comando resolve o problema e é simples, desde que apague **por sessão, pela data do nome**, só arquivos com o padrão de coleta, e nunca a sessão em andamento. Como é um comando manual, não há opção de configuração para desligar: quem não o roda não é afetado.

## Passos

### 1. Subcomando `cleanlog` (`bin/gamemoderun`)

- No `case` do início, antes de `real_gamemoderun`: `cleanlog) shift; cleanlog "$@"; exit $? ;;`. Funciona mesmo sem o GameMode instalado.
- Função `cleanlog DIAS [--check]`:
  - `DIAS` é obrigatório e precisa ser um inteiro ≥ 0 (`^[0-9]+$`). Ausente, negativo, `2x` ou um argumento a mais: mostra o uso no stderr, sai com 2 e não apaga nada.
  - Diretório: `MONITOR_LOG_DIR` do ambiente, senão o do `gamemode-tweaks.conf` (o monitor lê a configuração), senão `~/.monitor/log`. Diretório inexistente: avisa "nada a apagar" e sai com 0.
  - Corte: `hoje − DIAS`, como AAAAMMDD (`date -d "$hoje -$DIAS days" +%Y%m%d`). Uma sessão é apagada se o dia no nome for **menor** que o corte.
  - Arquivos: só os do primeiro nível do diretório, regulares (não links), com nome `*-AAAAMMDD-HHMMSS.*` ou `*-AAAAMMDD-HHMMSS-<sufixo>.*`. Subdiretórios e outros arquivos ficam.
  - Pula a sessão do `$XDG_RUNTIME_DIR/gamemode-monitor.current`, se o arquivo existir.
  - Saída: as sessões apagadas (uma por linha) e um total: `apagadas 14 sessoes (84 arquivos, 261 MB) anteriores a 22/11/2026`. Sem nada para apagar: `nada a apagar: nenhuma coleta anterior a 22/11/2026`.
  - `--check`: mesma saída com "apagaria", sem apagar.
- `GH_TODAY=AAAAMMDD` (só nos testes) fixa o dia de hoje, como os outros `GH_*`.
- `usage()`: linha `gamemoderun cleanlog <dias> [--check]` no topo e uma seção `COLETAS` com o exemplo.

### 2. Testes (`tests/run-tests.sh`)

Grupo novo `gamemoderun cleanlog`, com um diretório de coletas falso (`MONITOR_LOG_DIR`) e `GH_TODAY=20261124`:

- `cleanlog 2`: apaga as sessões de 20 e 21/11, mantém 22, 23 e 24/11.
- Sessão que passou da meia-noite (nome 21/11, arquivo de 22/11): sai inteira.
- Todos os sufixos da sessão saem juntos (`.csv`, `-threads.csv`, `-ping.csv`, `.log`, `-marcas.txt`).
- `cleanlog 0`: mantém só o dia de hoje.
- Sessão em andamento (`gamemode-monitor.current` aponta para uma de 20/11): fica.
- Arquivo fora do padrão, subdiretório e link simbólico com nome de coleta: ficam.
- `--check`: lista e não apaga.
- Sem argumento, `-1`, `abc`, `2x`, `2 3`: código 2, mensagem de uso, nada apagado.
- Diretório inexistente: código 0, "nada a apagar".
- `MONITOR_LOG_DIR` no `gamemode-tweaks.conf`: usa esse diretório.
- Não chama o gamemoderun do sistema (o falso de `$TMP/sysgames` não é executado).
- **Regressão:** `--help`, a pergunta dos monitores e o repasse (`gmr ... -- ./jogo --help -x`) continuam iguais. Um jogo chamado `cleanlogx` é repassado.

### 3. Validação e documentação

- Depois do merge e de `sudo ./install.sh`: `gamemoderun cleanlog 2 --check` no sistema real deve listar as sessões até 21/11. Rodar o `cleanlog 2` de verdade só se você quiser.
- `README.md` e `README.en.md`: uma seção curta "Apagar coletas antigas", com o exemplo, e a menção na tabela de arquivos (`bin/gamemoderun`).
- `CHANGELOG.md` (novo): `## [Não lançado]` → Adicionado: `005: gamemoderun cleanlog <dias> apaga as coletas antigas (#5).`

## Arquivos afetados

| Arquivo | Mudança |
|---|---|
| `bin/gamemoderun` | subcomando `cleanlog`, função `cleanlog`, `GH_TODAY`, uso e `--help` |
| `tests/run-tests.sh` | grupo `gamemoderun cleanlog` |
| `README.md`, `README.en.md` | seção "Apagar coletas antigas" |
| `CHANGELOG.md` (**novo**) | entrada da 005 |

O `install.sh` não muda: ele já instala o `bin/gamemoderun`, e o `--uninstall` já o apaga.

## Fora do escopo

- Limpeza automática ao fechar o jogo (por exemplo, uma opção `LOG_KEEP_DAYS` no `gamemode-tweaks.conf` usada pelo `gamemode-end.sh`): fica para outra issue, se você quiser.
- Limite por tamanho total do diretório.
- Backups `.bak-*` do instalador: já têm o `install.sh --purge`.
- Compactar as coletas antigas em vez de apagar.
