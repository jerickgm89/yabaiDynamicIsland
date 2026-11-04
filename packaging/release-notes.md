> **English:** YabaiBar is a Dynamic Island around the MacBook notch that shows your [yabai](https://github.com/asmvik/yabai) spaces, what's playing and a Pomodoro. For now it only supports the 2021 MacBook Pro with M1 Pro or M1 Max, with a notch. Install with `brew install --cask jerickgm89/tap/yabaibar` or the DMG below; it needs yabai installed and running. The first time, macOS blocks it: System Settings › Privacy & Security › Open Anyway.

{{CHANGES}}

## Instalación

Con [Homebrew](https://brew.sh):

```bash
brew install --cask jerickgm89/tap/yabaibar
```

O descarga `YabaiBar-{{VERSION}}.dmg`, ábrelo y arrastra YabaiBar a Aplicaciones.

**La primera vez:** YabaiBar está firmada con un certificado propio y no está notarizada por Apple, así que macOS la bloquea.

1. Ábrela y cierra el aviso.
2. En Ajustes del Sistema › Privacidad y seguridad, pulsa «Abrir igualmente».
3. Al abrirse, la ventana «Primeros pasos» te dice qué falta.

Si prefieres la terminal: `xattr -dr com.apple.quarantine /Applications/YabaiBar.app`.

## Requisitos

- [yabai](https://github.com/asmvik/yabai) instalado y en marcha, configurado leyendo antes [su wiki](https://github.com/asmvik/yabai/wiki): `brew install asmvik/formulae/yabai` y `yabai --start-service`. YabaiBar no necesita la scripting addition ni desactivar SIP.
- macOS 14 o posterior (probado en macOS 27).

## Compatibilidad

- **Soportado:** MacBook Pro de 2021 con M1 Pro o M1 Max (14" y 16"), con notch. Probado en el de 16".
- **Aún no:** M2, M3, M4 y posteriores, porque el notch tiene otro ancho y la isla se descoloca; Macs sin notch; monitores externos; Intel. El soporte llegará en próximas versiones.

SHA-256 de `YabaiBar-{{VERSION}}.dmg`: `{{SHA256}}`
