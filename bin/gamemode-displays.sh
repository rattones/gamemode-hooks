#!/usr/bin/env bash
# gamemode-displays.sh - monitores no X11 e no Wayland, para os hooks, o
# gamemoderun e o install.sh. E carregado com "."; sozinho nao faz nada.
#
# Cada sessao tem a sua ferramenta: xrandr (X11), kscreen-doctor (KDE Plasma),
# gdctl (GNOME 48+) e wlr-randr (Sway e outros wlroots). Cinnamon, XFCE e
# afins no Wayland nao tem nenhuma: sem ferramenta, os monitores ficam como estao.
#
# Todas viram o mesmo formato (mon_state), uma linha por monitor conectado:
#   nome|ligado(1/0)|modo|taxa|x|y|primario(1/0)|extra
# extra: o id do modo (kscreen-doctor), "grupo,escala,rotacao" (gdctl) ou a
# escala (wlr-randr).

# mon_backend: a ferramenta desta sessao; vazio quando nenhuma funciona.
mon_backend() {
    local s="${XDG_SESSION_TYPE:-}" d b
    [ -z "$s" ] && [ -n "${WAYLAND_DISPLAY:-}" ] && s=wayland
    if [ "$s" != wayland ]; then
        command -v xrandr >/dev/null 2>&1 && xrandr --query >/dev/null 2>&1 && echo xrandr
        return 0
    fi
    d="${XDG_CURRENT_DESKTOP:-}"; d="${d,,}"
    case "$d" in
        *kde*)   set -- kscreen-doctor gdctl wlr-randr ;;
        *gnome*) set -- gdctl kscreen-doctor wlr-randr ;;
        *)       set -- wlr-randr kscreen-doctor gdctl ;;
    esac
    for b; do
        command -v "$b" >/dev/null 2>&1 || continue
        [ -n "$("_mon_state_${b//-/_}" 2>/dev/null)" ] && { echo "$b"; return 0; }
    done
    return 0
}

mon_state() {
    : "${MON_BACKEND:=$(mon_backend)}"
    [ -n "$MON_BACKEND" ] && "_mon_state_${MON_BACKEND//-/_}"
}

# mon_list: "nome|resolucao" (ou "nome|desligado") dos monitores conectados
mon_list() { mon_state | awk -F'|' '{print $1 "|" ($2 == 1 && $3 != "" ? $3 : "desligado")}'; }

# mon_connected NOME
mon_connected() { mon_state | awk -F'|' -v m="$1" '$1 == m {f = 1} END {exit !f}'; }

# mon_capture: o comando que devolve o layout atual (para o end.sh desfazer)
mon_capture() {
    : "${MON_BACKEND:=$(mon_backend)}"
    mon_state | awk -F'|' -v b="$MON_BACKEND" '
    b == "xrandr" {
        if ($2 == 1) {
            s = s " --output " $1 " --mode " $3 " --pos " $5 "x" $6
            if ($4 != "") s = s " --rate " $4
            if ($7 == 1) s = s " --primary"
        } else s = s " --output " $1 " --off"
    }
    b == "kscreen-doctor" {
        if ($2 == 1) {
            s = s " output." $1 ".enable"
            if ($8 != "") s = s " output." $1 ".mode." $8
            s = s " output." $1 ".position." $5 "," $6
            if ($7 == 1) s = s " output." $1 ".priority.1"
        } else s = s " output." $1 ".disable"
    }
    b == "wlr-randr" {
        if ($2 == 1) {
            s = s " --output " $1 " --on"
            if ($3 != "") s = s " --mode " $3 (($4 != "") ? "@" $4 "Hz" : "")
            s = s " --pos " $5 "," $6
            if ($8 != "") s = s " --scale " $8
        } else s = s " --output " $1 " --off"
    }
    # gdctl set descreve o layout inteiro: um --logical-monitor por grupo, com
    # os monitores dele; quem fica de fora e desligado.
    b == "gdctl" && $2 == 1 {
        split($8, e, ","); g = e[1]
        if (!(g in lm)) {
            lm[g] = " --logical-monitor" ($7 == 1 ? " --primary" : "") " --x " $5 " --y " $6
            if (e[2] != "") lm[g] = lm[g] " --scale " e[2]
            if (e[3] != "" && e[3] != "normal") lm[g] = lm[g] " --transform " e[3]
            order[++n] = g
        }
        lm[g] = lm[g] " --monitor " $1 ($3 != "" ? " --mode " $3 "@" $4 : "")
    }
    END {
        if (b == "gdctl") for (i = 1; i <= n; i++) s = s lm[order[i]]
        if (s == "") exit
        print (b == "gdctl" ? "gdctl set" : b) s
    }'
}

# mon_apply MONITOR TAXA: so MONITOR ligado, como primario; os outros desligados.
# A taxa (auto ou um valor) so vale no X11: no Wayland o modo fica como esta.
mon_apply() {
    local gm="$1" refresh="${2:-auto}" mode rate args o
    : "${MON_BACKEND:=$(mon_backend)}"
    case "$MON_BACKEND" in
        xrandr)
            mode=$(_mon_best_mode "$gm")
            if [ "$refresh" = auto ]; then rate=$(_mon_best_rate "$gm" "$mode"); else rate="$refresh"; fi
            args="--output $gm --mode $mode --pos 0x0 --primary"
            [ -n "$rate" ] && args="$args --rate $rate"
            for o in $(mon_state | cut -d'|' -f1); do
                [ "$o" = "$gm" ] || args="$args --output $o --off"
            done
            # shellcheck disable=SC2086
            xrandr $args 2>/dev/null ;;
        kscreen-doctor)
            args="output.$gm.enable output.$gm.position.0,0 output.$gm.priority.1"
            for o in $(mon_state | cut -d'|' -f1); do
                [ "$o" = "$gm" ] || args="$args output.$o.disable"
            done
            # shellcheck disable=SC2086
            kscreen-doctor $args >/dev/null 2>&1 ;;
        wlr-randr)
            args="--output $gm --on --pos 0,0"
            for o in $(mon_state | cut -d'|' -f1); do
                [ "$o" = "$gm" ] || args="$args --output $o --off"
            done
            # shellcheck disable=SC2086
            wlr-randr $args 2>/dev/null ;;
        gdctl)
            # So o monitor do jogo no layout; a escala dele e mantida.
            args=$(mon_state | awk -F'|' -v m="$gm" '$1 == m {split($8, e, ","); if (e[2] != "") print "--scale " e[2]}')
            # shellcheck disable=SC2086
            gdctl set --logical-monitor --primary $args --monitor "$gm" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# mon_fallback: rede de seguranca quando o comando de restauracao falha:
# religa tudo no automatico.
mon_fallback() {
    local o args=""
    : "${MON_BACKEND:=$(mon_backend)}"
    for o in $(mon_state | cut -d'|' -f1); do
        case "$MON_BACKEND" in
            xrandr)         xrandr --output "$o" --auto 2>/dev/null ;;
            kscreen-doctor) args="$args output.$o.enable" ;;
            wlr-randr)      args="$args --output $o --on" ;;
        esac
    done
    # shellcheck disable=SC2086
    case "$MON_BACKEND" in
        kscreen-doctor) [ -n "$args" ] && kscreen-doctor $args >/dev/null 2>&1 ;;
        wlr-randr)      [ -n "$args" ] && wlr-randr $args 2>/dev/null ;;
    esac
    return 0
}

# --- leitura de cada ferramenta ----------------------------------------------

_mon_state_xrandr() {
    xrandr --query 2>/dev/null | awk '
    function flush() { if (out != "") print out "|" (geo != "") "|" mode "|" rate "|" x "|" y "|" prim "|"; out = "" }
    / connected/ {
        flush()
        out = $1; prim = ($3 == "primary"); geo = ""; mode = ""; rate = ""; x = ""; y = ""
        for (i = 3; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+[-0-9]+\+[-0-9]+$/) {
            geo = $i; split(geo, g, "+"); mode = g[1]; x = g[2]; y = g[3]; break
        }
        next
    }
    /^[ \t]+[0-9]+x[0-9]+/ {
        if (out == "" || geo == "") next
        for (i = 2; i <= NF; i++) if ($i ~ /\*/) { r = $i; gsub(/[*+]/, "", r); rate = r }
        next
    }
    /^[^ \t]/ { flush() }
    END { flush() }'
}

_mon_mode_lines() { xrandr --query | awk -v m="$1" '$1==m&&/ connected/{f=1;next} /^[A-Za-z]/{f=0} f&&/^[ \t]+[0-9]+x[0-9]+/'; }
_mon_best_mode() { _mon_mode_lines "$1" | awk '{print $1; exit}'; }
_mon_best_rate() {
    _mon_mode_lines "$1" | awk -v md="$2" '
    $1==md{for(i=2;i<=NF;i++){r=$i;gsub(/[*+]/,"",r); if(r+0>b) b=r+0}}
    END{if(b>0) printf "%.2f", b}'
}

# kscreen-doctor -o: Plasma 5 numa linha por saida, Plasma 6 em varias; com
# cores ANSI. O modo atual e o marcado com "*" ("1:2560x1440@165*!").
_mon_state_kscreen_doctor() {
    kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
    function flush() { if (name != "" && conn) print name "|" en "|" mode "|" rate "|" x "|" y "|" prim "|" mid; name = "" }
    $1 == "Output:" { flush(); name = $3; en = 0; conn = 0; prim = 0; mode = ""; rate = ""; x = ""; y = ""; mid = "" }
    {
        for (i = ($1 == "Output:" ? 4 : 1); i <= NF; i++) {
            t = $i
            if (t == "enabled") en = 1
            else if (t == "connected") conn = 1
            else if (t == "primary" || (t == "priority" && $(i + 1) == "1")) prim = 1
            else if (t ~ /^[0-9]+:[0-9]+x[0-9]+@/ && t ~ /\*/) {
                split(t, a, ":"); mid = a[1]; m = a[2]; gsub(/[*!]/, "", m)
                split(m, b, "@"); mode = b[1]; rate = b[2]
            }
            else if (t == "Geometry:") { split($(i + 1), p, ","); x = p[1]; y = p[2] }
        }
    }
    END { flush() }'
}

# gdctl show: arvore com "Monitors:" (cada um com o "Current mode") e
# "Logical monitors:" (posicao, escala, rotacao, primario e os monitores de
# cada grupo). Monitor fora de todo grupo esta desligado.
_mon_state_gdctl() {
    gdctl show 2>/dev/null | sed 's/[│├└─]//g; s/^[[:space:]]*//' | awk '
    /^Monitors:$/ { sec = "m"; next }
    /^Logical monitors:$/ { sec = "l"; next }
    /^[A-Z][a-z]+:$/ { sec = ""; next }
    sec == "m" && /^Monitor / { cur = $2; names[++n] = cur; want = ""; next }
    sec == "m" && /^Current mode/ {
        if (match($0, /[0-9]+x[0-9]+@[0-9.]+/)) cm[cur] = substr($0, RSTART, RLENGTH); else want = cur
        next
    }
    sec == "m" && want != "" && /^[0-9]+x[0-9]+@/ { cm[want] = $1; want = ""; next }
    sec == "l" && /^Logical monitor/ { lm++; inmon = 0; next }
    sec == "l" && /^Position:/ { gsub(/[(),]/, " "); lx[lm] = $2; ly[lm] = $3; next }
    sec == "l" && /^Scale:/ { ls[lm] = $2; next }
    sec == "l" && /^Transform:/ { lt[lm] = $2; next }
    sec == "l" && /^Primary:/ { lp[lm] = ($2 == "yes"); next }
    sec == "l" && /^Monitors:/ { inmon = 1; next }
    sec == "l" && inmon && /^[A-Za-z ]+:/ { inmon = 0 }
    sec == "l" && inmon && NF { of[$1] = lm }
    END {
        for (i = 1; i <= n; i++) {
            m = names[i]; g = of[m]; split(cm[m], md, "@")
            print m "|" (g != "") "|" md[1] "|" md[2] "|" lx[g] "|" ly[g] "|" (g != "" && lp[g] ? 1 : 0) "|" \
                  (g != "" ? g "," ls[g] "," lt[g] : "")
        }
    }'
}

# wlr-randr: um bloco por saida, com "Enabled:", o modo "(current)",
# "Position:" e "Scale:". O wlroots nao tem monitor primario.
_mon_state_wlr_randr() {
    wlr-randr 2>/dev/null | awk '
    function flush() { if (name != "") print name "|" en "|" mode "|" rate "|" x "|" y "|0|" sc; name = "" }
    /^[^ \t]/ { flush(); name = $1; en = 0; mode = ""; rate = ""; x = ""; y = ""; sc = ""; next }
    /^[ \t]+Enabled:/ { en = ($2 == "yes"); next }
    /^[ \t]+[0-9]+x[0-9]+ px,/ && /current/ { mode = $1; rate = $3; next }
    /^[ \t]+Position:/ { split($2, p, ","); x = p[1]; y = p[2]; next }
    /^[ \t]+Scale:/ { sc = $2; next }
    END { flush() }'
}
