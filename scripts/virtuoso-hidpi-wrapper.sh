#!/bin/bash
# Installed as /usr/local/bin/virtuoso (ahead of $CDS/tools/dfII/bin on PATH).
# Applies the UI scale, then execs the unmodified Cadence `virtuoso`.
#
# IC6.1.7 bundles Qt 4.8.5 and sizes its UI fonts in pixels, so neither
# QT_SCALE_FACTOR (Qt >= 5.6 only) nor Xft.dpi changes anything. Scaling is
# done with Cadence's own hiSetFont, from a SKILL file passed via -restore.
# Only Virtuoso sessions are affected; Spectre/Calibre runs are not.
#
#   VIRTUOSO_SCALE=1.0 | 1.25 | 1.5 | 2.0   (default comes from the image ENV)
#   VIRTUOSO_SCALE=off                       leave Cadence's font settings alone

REAL_VIRTUOSO="${CDS:-/opt/cadence/IC617}/tools/dfII/bin/virtuoso"
HIDPI_SKILL="/usr/local/share/virtuoso-hidpi/hidpi.il"

if [[ ! -x "$REAL_VIRTUOSO" ]]; then
    echo "virtuoso wrapper: Cadence virtuoso not found at $REAL_VIRTUOSO" >&2
    exit 127
fi

scale="${VIRTUOSO_SCALE:-off}"
if [[ "$scale" == off ]]; then
    exec "$REAL_VIRTUOSO" "$@"
fi
if ! awk -v s="$scale" 'BEGIN { exit !(s ~ /^[0-9]+(\.[0-9]+)?$/ && s >= 0.5 && s <= 4) }'; then
    echo "virtuoso wrapper: invalid VIRTUOSO_SCALE='$scale' (use 1.0/1.25/1.5/2.0 or off); using 1.0" >&2
    scale=1.0
fi
export VIRTUOSO_SCALE="$scale"

# -restore takes a single file; if the caller passes their own, keep it.
# The last applied font size is saved by Cadence and still applies.
for arg in "$@"; do
    if [[ "$arg" == -restore ]]; then
        echo "virtuoso wrapper: -restore given, UI scale not re-applied (add load(\"$HIDPI_SKILL\") to your file)" >&2
        exec "$REAL_VIRTUOSO" "$@"
    fi
done

echo "virtuoso: UI scale ${scale} (Cadence UI fonts $(awk -v s="$scale" 'BEGIN { printf "%d", 11 * s + 0.5 }') px)" >&2
exec "$REAL_VIRTUOSO" -restore "$HIDPI_SKILL" "$@"
