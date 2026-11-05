> **English:** YabaiBar is a Dynamic Island around the MacBook notch that shows your [yabai](https://github.com/asmvik/yabai) spaces, what's playing and a Pomodoro. It works on any MacBook with a notch (MacBook Pro from 2021, MacBook Air from 2022): it measures the notch on your screen. Install with `brew install --cask jerickgm89/tap/yabaibar` or the DMG below; it needs yabai installed and running. The first time, macOS blocks it: System Settings › Privacy & Security › Open Anyway.

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

- **Soportado:** cualquier MacBook con notch, MacBook Pro desde 2021 y MacBook Air desde 2022. La isla mide el notch de tu pantalla con cualquier escala. Probado en el MacBook Pro de 16" con M1 Pro; en los demás, «Primeros pasos» dice qué modelo y qué notch detectó.
- **Aún no:** monitores externos, Macs sin notch y la tapa cerrada (la isla se dibuja sobre un notch de reserva), el MacBook Pro OLED con Dynamic Island e Intel.

Si algo se ve descolocado en tu Mac, abre un [issue](https://github.com/jerickgm89/yabaiDynamicIsland/issues) con lo que copia «Primeros pasos» › «Copiar datos».

SHA-256 de `YabaiBar-{{VERSION}}.dmg`: `{{SHA256}}`
