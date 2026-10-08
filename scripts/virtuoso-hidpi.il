;; Virtuoso IC6.1.7 UI scaling (installed as /usr/local/share/virtuoso-hidpi/hidpi.il).
;; Loaded at startup by /usr/local/bin/virtuoso via `-restore`.
;;
;; IC6.1.7 uses Qt 4.8.5 and pixel-sized UI fonts, so QT_SCALE_FACTOR and
;; Xft.dpi have no effect. The supported control is hiSetFont: it sets the
;; label (menus, forms), text (fields) and CIW fonts and saves them in
;; ~/.cadence/<user>/dfII/ui/virtuoso617.conf. Sizes are set absolutely from
;; the IC6.1.7 defaults (11 px), so repeated launches never compound.
;; Icons, toolbars and fixed-layout ("2D") forms are not scaled by Cadence.
let((scale px)
    scale = atof(or(getShellEnvVar("VIRTUOSO_SCALE") "1.0"))
    when(or(null(scale) scale < 0.5 scale > 4.0)
        scale = 1.0)
    px = round(11 * scale)
    foreach(fontType '(label text ciw)
        unless(car(errset(hiSetFont(fontType ?size px) t))
            printf("*WARNING* virtuoso-hidpi: hiSetFont(%L) failed\n" fontType)))
    printf("virtuoso-hidpi: UI font size %d px (VIRTUOSO_SCALE=%L)\n" px scale)
)
