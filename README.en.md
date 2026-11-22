# gamemode-hooks

*[Português](README.md)*

Scripts that [GameMode](https://github.com/FeralInteractive/gamemode) runs when
a game started with `gamemoderun %command%` opens and closes: extra power, GPU,
monitor and service tweaks, plus data collection. The system `gamemoderun`
(`/usr/games/gamemoderun`) is still what turns GameMode on; the one in this
repository, in `~/.local/bin`, comes first in PATH and only adds `--help` and
the monitor question when the game opens. Each tweak depends on a feature and is
skipped where the feature is missing, and the installer detects the hardware to
generate the configuration.

## What happens when the game opens and closes

| On open (`gamemode-start.sh`) | On close (`gamemode-end.sh`) | Needs |
|---|---|---|
| platform power profile set to performance | back to the previous profile | laptop with ACPI `platform_profile` |
| NVIDIA PowerMizer set to "prefer maximum performance" | back to the previous mode | NVIDIA with `nvidia-settings` |
| only the game's monitor on, or all of them, following the answer to `gamemoderun`'s question; the others are turned off (on X11, at the highest refresh rate) | the exact previous layout restored | more than one monitor; X11 with `xrandr` or Wayland with `kscreen-doctor` (KDE), `gdctl` (GNOME 48+) or `wlr-randr` (wlroots) |
| turns off the Wi-Fi card's power saving (fewer latency spikes online) | turns it back on, if it was on | Wi-Fi card with `iw` or `iwconfig` |
| pauses the user services you chose | restarts only the ones it paused | systemd user session |
| starts [monitor](https://github.com/rattones/monitor) on the game's PID | stops the collection | `monitor` installed |
| notification with free VRAM, warning below 78% | notification that everything was restored | `nvidia-smi` |

The previous state is kept in `$XDG_RUNTIME_DIR/gamemode-tweaks.state`.
GameMode fires start/end several times while Steam starts up, so the start hook
keeps the state it already captured: the end hook then restores the original
value, not an already-modified one.

GameMode itself, through `gamemode.ini`, also sets the CPU governor to
`performance`, renices the game, gives it soft real-time priority and inhibits
the screensaver.

## Install

```bash
sudo ./install.sh                 # detect the hardware, ask what is unclear, install
sudo ./install.sh --check         # only show what was detected and what would change
sudo ./install.sh --yes           # no questions: apply only what is certain
sudo ./install.sh --reconfigure   # regenerate the configuration
```

It needs `sudo` because it adds your user to the `gamemode` group (`usermod`):
Ubuntu's polkit rule lets GameMode change the CPU governor only for members of
that group, and without it `gamemoded -t` fails with "Not authorized". The group
takes effect at your next login. Run directly as root, without `sudo`, it
refuses: files go to the home of whoever called `sudo`, owned by that user, and
the monitor and service detection runs as that user, in their graphical
session.

What the installer detects, and the preset it becomes:

| Detected | Preset |
|---|---|
| `platform_profile` offering `performance` | on, with `performance` |
| `platform_profile` with other names (`quiet`, `balanced-performance`...) | **asks** which one to use, or none |
| no `platform_profile` | off |
| NVIDIA with `nvidia-settings` | PowerMizer and VRAM warning on |
| NVIDIA without `nvidia-settings` | VRAM warning only |
| more than one monitor (X11, or Wayland on KDE, GNOME 48+ or wlroots) | **asks** which one is the game's monitor, or none |
| a single monitor, or no monitor tool (`xrandr`; on Wayland, `kscreen-doctor`, `gdctl` or `wlr-randr`) | monitors left alone |
| Wi-Fi card and `iw` or `iwconfig` | Wi-Fi power saving off during games (with several cards, the connected one) |
| `monitor` installed | collection on |
| running user services | **asks** which ones to pause while playing |

With `--yes`, or without a terminal, everything that would be a question stays
off. An existing configuration (`~/.config/gamemode-tweaks.conf`) is never
replaced unless you say so: the installer asks, and with `--yes` it keeps yours
and writes the detected one to `gamemode-tweaks.conf.detectado`. Every replaced
file is saved as `<file>.bak-<date>` first.

The helpers that run as root are only printed, for you to review before running:

- copy `system/platform-profile` and `system/wifi-powersave` to
  `/usr/local/bin/` (owned by root);
- create `/etc/sudoers.d/platform-profile` and `/etc/sudoers.d/wifi-powersave`,
  which allow only those exact paths without a password (checked with
  `visudo -c`).

Then `gamemoded -t` should end with "All Tests Passed". In the game (Steam →
Properties → Launch Options): `gamemoderun %command%`.

To update, just run `sudo ./install.sh` again: the scripts are replaced and your
configuration stays (new options missing from it use their defaults). In a
terminal that was already open, run `rehash` (zsh) or `hash -r` (bash) so the
shell finds the `gamemoderun` in `~/.local/bin`.

### One monitor or all of them, at launch

With a game monitor chosen, every game started through `gamemoderun` begins
with an on-screen question: **"So o <monitor>"** (only that one) or **"Todos os
monitores"** (all). With no answer in 15 s (`ASK_TIMEOUT`), only the game's
monitor stays on. The question uses `zenity` (or `kdialog` on KDE) and works on
X11 and Wayland; it is skipped when only one monitor is already on, or when
another game has already switched them.

To skip the question for one game, fix the answer in its launch options:

```
GAMEMODE_SINGLE_MONITOR=0 gamemoderun %command%   # all monitors
GAMEMODE_SINGLE_MONITOR=1 gamemoderun %command%   # only the game's
```

To never ask, set `ASK_MONITOR=0` in `gamemode-tweaks.conf`.

The answer goes into the game's environment as `GAMEMODE_SINGLE_MONITOR`. The
hook is not a child of the game (`gamemoded` runs it), so it looks for the
variable in the environment of the processes started by `gamemoderun`. The same
works for `modo-jogo`, which does not ask: `GAMEMODE_SINGLE_MONITOR=0 modo-jogo on`.

On Wayland the switch uses the desktop's own tool: `kscreen-doctor` (KDE
Plasma), `gdctl` (GNOME 48 or newer) or `wlr-randr` (Sway and other wlroots
compositors). There it only turns monitors on and off; resolution and refresh
rate stay as they are. Cinnamon, XFCE and similar on Wayland have no such tool,
and the monitors are left alone.

To see how to launch games, the per-game options and what is enabled on this
machine: `gamemoderun --help` (or `-h`).

## Configuration

The options live in `~/.config/gamemode-tweaks.conf`, generated by the installer
and commented. A change applies to the next game, with nothing to restart.

| Option | Default | What it does |
|---|---|---|
| `GAME_MONITOR` | (detected) | monitor the game runs on; empty = leave monitors alone |
| `SINGLE_MONITOR` | `1` when a monitor is chosen | keeps only `GAME_MONITOR` on during the game |
| `ASK_MONITOR` | `1` | asks when the game opens: only `GAME_MONITOR` or all; `0` = don't ask |
| `ASK_TIMEOUT` | `15` | seconds before the question falls back to the default (only `GAME_MONITOR`) |
| `GAME_REFRESH` | `auto` | refresh rate on the game's monitor (X11 only): `auto` = highest, or a value like `59.98` |
| `SET_PLATFORM_PROFILE` | (detected) | switches the platform power profile during the game |
| `PERF_PROFILE` | `performance` | profile used, one of `platform_profile_choices` |
| `PROFILE_HELPER` | (detected) | what writes the profile as root, via `sudo -n` |
| `SET_POWERMIZER` | (detected) | NVIDIA PowerMizer at "prefer maximum performance" |
| `NOTIFY_VRAM` / `VRAM_WARN_PCT` | (detected) / `78` | warns when free VRAM drops below this % of the total |
| `SET_WIFI_POWERSAVE` / `WIFI_IFACE` | (detected) | turns off power saving on this Wi-Fi card during the game |
| `PAUSE_SERVICES` | (empty) | user services paused during the game, space-separated |
| `RUN_MONITOR` / `MONITOR_BIN` | (detected) | collection with [monitor](https://github.com/rattones/monitor) and where it is |
| `MONITOR_MIN_RSS_MB` / `MONITOR_WAIT_S` | `300` / `180` | the game is the process with the largest RSS; waits until it passes this size or this time |
| `MONITOR_ARGS` | `-q` | extra monitor options (e.g. `-q -i 1000`) |
| `MONITOR_PERF` | `auto` | `perf` too (`monitor -P`): `auto` = when allowed, `1` = always, `0` = never |

## Uninstall

```bash
sudo ./uninstall.sh                 # asks whether to delete the configuration
sudo ./uninstall.sh --yes           # no questions: deletes everything
sudo ./uninstall.sh --check         # only shows what it would delete
sudo ./uninstall.sh --keep-config   # keeps ~/.config/gamemode-tweaks.conf
sudo ./uninstall.sh --purge         # also deletes the .bak-* backups
```

If a game (or `modo-jogo`) is still active, its tweaks are undone first. Then
the scripts in `~/.local/bin` and the configuration go away; the `gamemode.ini`
that existed before the installer comes back from its backup (without one, the
hooks' file is deleted). With `sudo`, `/usr/local/bin/platform-profile`,
`/usr/local/bin/wifi-powersave` and their `/etc/sudoers.d/` rules are removed
too; without it, the commands are shown. The `gamemode` group and GameMode itself stay, since they work
without the hooks. Same as `sudo ./install.sh --uninstall`.

## Files

| File | Goes to | Role |
|---|---|---|
| `bin/gamemode-start.sh` | `~/.local/bin/` | start hook |
| `bin/gamemode-end.sh` | `~/.local/bin/` | end hook: undoes the start |
| `bin/gamemode-monitor.sh` | `~/.local/bin/` | finds the game's PID through GameMode's D-Bus API (`ListGames` plus children, picking the largest RSS, since under Proton the game is a child of Steam's wrappers) and runs `monitor all -f pid:N`; with `MONITOR_PERF=auto` it adds `-P` when `perf` is allowed |
| `bin/gamemoderun` | `~/.local/bin/` | wrapper around the system `gamemoderun`: asks on screen whether the game uses one monitor or all of them and passes everything on to `/usr/games/gamemoderun`; `gamemoderun --help` (or `-h`) explains how to launch games and the per-game options, and shows this machine's settings |
| `bin/gamemode-displays.sh` | `~/.local/bin/` | reads, switches and restores monitors with the session's tool (`xrandr`, `kscreen-doctor`, `gdctl` or `wlr-randr`); used by the hooks, `gamemoderun` and the installer |
| `bin/modo-jogo` | `~/.local/bin/` | turns the same tweaks on and off by hand: `modo-jogo on\|off\|toggle\|status` |
| `uninstall.sh` | — | uninstalls: shortcut for `install.sh --uninstall` |
| `config/gamemode.ini` | `~/.config/` | GameMode configuration: governor, renice and the hook paths (`@HOME@` becomes your home) |
| (generated) `gamemode-tweaks.conf` | `~/.config/` | the hooks' options, commented; changes apply to the next game, no restart needed |
| `system/platform-profile` | `/usr/local/bin/` (root) | writes `/sys/firmware/acpi/platform_profile`, accepting only names from `platform_profile_choices` |
| `system/sudoers-platform-profile` | `/etc/sudoers.d/platform-profile` | sudo rule template |
| `system/wifi-powersave` | `/usr/local/bin/` (root) | turns a Wi-Fi card's power saving on or off, or reports it (`iw`, or `iwconfig`), accepting only interfaces the kernel lists as Wi-Fi |
| `system/sudoers-wifi-powersave` | `/etc/sudoers.d/wifi-powersave` | sudo rule template |
| `tests/` | — | installer and hook tests against fake hardware: `./tests/run-tests.sh` |

The scripts' messages and comments are in Portuguese.

## Dependencies

- `gamemode`, `busctl` (systemd), `notify-send`
- depending on the hardware: `xrandr` (X11) or, on Wayland, `kscreen-doctor`
  (KDE), `gdctl` (GNOME 48+) or `wlr-randr` (wlroots); `nvidia-settings` and
  `nvidia-smi` (NVIDIA); `iw` or `iwconfig` (Wi-Fi)
- `zenity` or `kdialog`, for the monitor question
- [monitor](https://github.com/rattones/monitor) at `~/.local/bin/monitor`, for
  the collection

## Notes

- GameMode's `[gpu]` section looks for the GPU at `card0` and fails where the
  NVIDIA card is another `cardN` (common with an iGPU or a MUX). That is why the
  start hook sets PowerMizer through `nvidia-settings`.
- Earlier installs used `/usr/local/bin/legion-profile`; the hooks and the
  installer still accept that name when sudo allows it.
- Wi-Fi power saving is turned off on the interface only, until the game ends.
  If the Wi-Fi reconnects mid-game, NetworkManager reapplies its own setting
  (`wifi.powersave`) and power saving may come back.
- Steam puts its own runtime (with an old `zenity` and its own libraries) at the
  front of the games' PATH. The monitor question uses the system `zenity` and
  runs without Steam's `LD_PRELOAD` and `LD_LIBRARY_PATH`.
- The question only shows up for games started through this repository's
  `gamemoderun`. A launcher that turns GameMode on by itself (without calling
  the `gamemoderun` in PATH) skips it: the default applies there, only the
  game's monitor, or the `GAMEMODE_SINGLE_MONITOR` from the game's options.
- The ~3 s Dota 2 freezes that motivated the data collection were not caused by
  these tweaks: CPU 0's TSC was left behind by the BIOS. See
  [ValveSoftware/Dota-2#3558](https://github.com/ValveSoftware/Dota-2/issues/3558).
