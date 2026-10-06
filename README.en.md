# gamemode-hooks

*[Português](README.md)*

Scripts that [GameMode](https://github.com/FeralInteractive/gamemode) runs when
a game started with `gamemoderun %command%` opens and closes. `gamemoderun`
itself comes with the system (`/usr/games/gamemoderun`); this repository holds
the extra tweaks and the data collection. Each tweak depends on a feature and is
skipped where the feature is missing, and the installer detects the hardware to
generate the configuration.

## What happens when the game opens and closes

| On open (`gamemode-start.sh`) | On close (`gamemode-end.sh`) | Needs |
|---|---|---|
| platform power profile set to performance | back to the previous profile | laptop with ACPI `platform_profile` |
| NVIDIA PowerMizer set to "prefer maximum performance" | back to the previous mode | NVIDIA with `nvidia-settings` |
| only the game's monitor on, at its highest refresh rate | the exact previous layout restored | X11 with `xrandr`, more than one monitor |
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
| X11 with more than one monitor | **asks** which monitor to keep for the game, or none |
| a single monitor, Wayland, or no `xrandr` | monitors left alone |
| `monitor` installed | collection on |
| running user services | **asks** which ones to pause while playing |

With `--yes`, or without a terminal, everything that would be a question stays
off. An existing configuration (`~/.config/gamemode-tweaks.conf`) is never
replaced unless you say so: the installer asks, and with `--yes` it keeps yours
and writes the detected one to `gamemode-tweaks.conf.detectado`. Every replaced
file is saved as `<file>.bak-<date>` first.

The power-profile helper is only printed, for you to review before running:

- copy `system/platform-profile` to `/usr/local/bin/` (owned by root);
- create `/etc/sudoers.d/platform-profile`, which allows only that exact path
  without a password (checked with `visudo -c`).

Then `gamemoded -t` should end with "All Tests Passed". In the game (Steam →
Properties → Launch Options): `gamemoderun %command%`.

## Files

| File | Goes to | Role |
|---|---|---|
| `bin/gamemode-start.sh` | `~/.local/bin/` | start hook |
| `bin/gamemode-end.sh` | `~/.local/bin/` | end hook: undoes the start |
| `bin/gamemode-monitor.sh` | `~/.local/bin/` | finds the game's PID through GameMode's D-Bus API (`ListGames` plus children, picking the largest RSS, since under Proton the game is a child of Steam's wrappers) and runs `monitor all -f pid:N`; with `MONITOR_PERF=auto` it adds `-P` when `perf` is allowed |
| `bin/modo-jogo` | `~/.local/bin/` | turns the same tweaks on and off by hand: `modo-jogo on\|off\|toggle\|status` |
| `config/gamemode.ini` | `~/.config/` | GameMode configuration: governor, renice and the hook paths (`@HOME@` becomes your home) |
| (generated) `gamemode-tweaks.conf` | `~/.config/` | the hooks' options, commented; changes apply to the next game, no restart needed |
| `system/platform-profile` | `/usr/local/bin/` (root) | writes `/sys/firmware/acpi/platform_profile`, accepting only names from `platform_profile_choices` |
| `system/sudoers-platform-profile` | `/etc/sudoers.d/platform-profile` | sudo rule template |
| `tests/` | — | installer and hook tests against fake hardware: `./tests/run-tests.sh` |

The scripts' messages and comments are in Portuguese.

## Dependencies

- `gamemode`, `busctl` (systemd), `notify-send`
- depending on the hardware: `xrandr` (X11), `nvidia-settings` and `nvidia-smi`
  (NVIDIA)
- [monitor](https://github.com/rattones/monitor) at `~/.local/bin/monitor`, for
  the collection

## Notes

- GameMode's `[gpu]` section looks for the GPU at `card0` and fails where the
  NVIDIA card is another `cardN` (common with an iGPU or a MUX). That is why the
  start hook sets PowerMizer through `nvidia-settings`.
- Earlier installs used `/usr/local/bin/legion-profile`; the hooks and the
  installer still accept that name when sudo allows it.
- The ~3 s Dota 2 freezes that motivated the data collection were not caused by
  these tweaks: CPU 0's TSC was left behind by the BIOS. See
  [ValveSoftware/Dota-2#3558](https://github.com/ValveSoftware/Dota-2/issues/3558).
