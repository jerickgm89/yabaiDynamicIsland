# YabaiBar

> **English summary.** YabaiBar is a native macOS app that turns the MacBook notch into a Dynamic Island showing your [yabai](https://github.com/asmvik/yabai) spaces with their app icons, what's playing (TIDAL or any Now Playing app), battery alerts and a Pomodoro. Install it with `brew install --cask jerickgm89/tap/yabaibar` or the DMG from [Releases](https://github.com/jerickgm89/yabaiDynamicIsland/releases). It needs yabai installed and running. **It works on any MacBook with a notch** (MacBook Pro from 2021, MacBook Air from 2022): it measures the notch on your screen, at any display scaling. It has been tested on the 16" M1 Pro; external displays and Macs without a notch are coming next. It isn't notarized: the first time, go to System Settings › Privacy & Security › Open Anyway. The rest of this README is in Spanish.

Una isla alrededor del notch del Mac que muestra los espacios de [yabai](https://github.com/asmvik/yabai), con los íconos de sus apps, y resalta el activo. Es una app nativa de macOS escrita en Swift 6 con SwiftUI y AppKit.

La isla vive por encima de la barra de menús, nace del notch como la Dynamic Island y está en todos los escritorios. Para ver qué apps tienes en cada escritorio, ábrela de tres formas: pasa el puntero por encima, desliza 3 o 4 dedos hacia abajo en el trackpad o pulsa un atajo de teclado (⌥I), desde cualquier app. Desde sus tarjetas saltas a cualquier escritorio y, debajo, ves y controlas la música que suena (TIDAL o cualquier app del "Ahora suena" de macOS). También avisa del cargador y de la batería baja, y puede mantener el Mac despierto. Trae un Pomodoro. Una ventana de ajustes te deja cambiar la velocidad de la animación, el atajo, cuándo se abre y se oculta, qué música muestra, qué actividades y los tiempos del Pomodoro.

Su diseño se inspira en [Atoll](https://github.com/Ebullioscopic/Atoll) (ver [Agradecimientos](#agradecimientos)).

<p align="center">
  <img src="assets/isla-cerrada.png" width="640" alt="La isla cerrada: el espacio 3 activo con su app a la izquierda del notch y los espacios 1, 2 y 4 a la derecha">
</p>

<p align="center">
  <img src="assets/isla-abierta.png" width="820" alt="La isla abierta: una tarjeta por espacio con su número, sus apps y su atajo, con el puntero sobre la tarjeta 1">
</p>

## Qué hace

**Cerrada (siempre visible)**

- A la izquierda del notch, el espacio activo: su número en el color del espacio y los íconos de sus apps (hasta 3, y "+n" si hay más).
- A la derecha, los espacios inactivos. Los que tienen ventanas llevan un punto de su color; los vacíos se ven apagados.
- Las dos alas miden lo mismo, para que la isla quede centrada en el notch.
- Cada espacio tiene su color, de una paleta inspirada en el tema liquid-glass.
- Si hay música, unas barras al final del ala derecha se mueven mientras suena y se quedan quietas en pausa.
- Al cambiar de canción, durante 3 s la isla enseña la carátula a la izquierda y el título y el artista a la derecha.

**Al cambiar de escritorio**

- En cuanto empieza el cambio (con ⌥N o al iniciar el gesto del trackpad), las alas se recogen hacia el notch y la isla se desvanece.
- Al llegar al escritorio nuevo, las alas vuelven a salir con el contenido actualizado.
- La velocidad de las alas se cambia en los ajustes.
- Con "Reducir movimiento" activado, el contenido solo se funde.

**Abierta (al pasar el puntero)**

- Al entrar el puntero, la isla crece un poco y el trackpad vibra.
- Si el puntero se queda encima, la isla se abre hacia abajo y muestra una tarjeta por espacio, con su número, sus apps y su atajo de teclado.
- Al pasar sobre una tarjeta, esta se ilumina; al hacer clic, macOS cambia a ese escritorio con su animación nativa.
- El clic derecho, o cualquier clic fuera de las tarjetas, abre el menú: el error de yabai si lo hay, Refrescar, Iniciar al arrancar, Ajustes… y Salir.

**Música (con la isla abierta)**

- Debajo de las tarjetas, lo que suena: la carátula, el título, el artista con el ícono de la app y el progreso.
- Los botones anterior, reproducir o pausar y siguiente controlan la app que suena. Un clic en la carátula abre esa app.
- Con el puntero sobre la franja, desliza dos dedos hacia la izquierda para pasar a la siguiente canción, o hacia la derecha para volver a la anterior.
- Funciona con TIDAL y con cualquier app que publique en el "Ahora suena" de macOS (Música, Spotify, el navegador…). En Ajustes puedes limitarlo a TIDAL.
- Lo lee [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), que va dentro de la app. Desde macOS 15.4 es la única forma de leer "Ahora suena" desde fuera de Apple, así que una actualización de macOS podría romperlo.

**Actividades**

- Al enchufar o desenchufar el cargador, la isla cerrada enseña 3 s el rayo y el porcentaje. Con poca batería (20 % y 10 %) avisa en naranja y en rojo.
- En la isla abierta, arriba a la derecha, un sol mantiene el Mac despierto: ni la pantalla ni el sistema se duermen hasta que lo apagues. Mientras está activo, un sol pequeño en la isla cerrada lo recuerda.

**Pomodoro**

- Un temporizador en la esquina izquierda de la isla abierta: un clic empieza un foco. Desde cualquier app, ⌥P lo empieza, lo pausa o lo reanuda, y la isla cerrada dice cómo quedó.
- Mientras corre, una franja entre las tarjetas y la música enseña la fase ("Foco · 2 de 4 · hoy 3/8"), la barra de progreso y la cuenta atrás, con ⏯ (pausar o reanudar), ⏭ (saltar fase) y ⏹ (terminar).
- Foco y descansos con un descanso largo cada pocos focos, y presets Clásico (25/5/15), Largo (50/10/30) y Corto (15/3/10), o tus propios tiempos.
- En la isla cerrada, un anillo al final del ala derecha se va llenando con la fase: rojo en el foco, verde en el descanso, gris en pausa.
- Al cambiar de fase, la isla cerrada avisa 4 s ("Descanso · 5 min"), y antes del final, "Quedan 30 s".
- Avisa sin alarmas, con sonidos propios sintetizados en código:
  - 30 s antes del final, una nota de kalimba; si suena música, el volumen baja poco a poco y se queda bajo hasta el final.
  - Al terminar, la música vuelve a tu volumen y suena un cuenco tibetano (fin del foco) o dos notas que suben (fin del descanso).
  - Si tocas el volumen mientras está bajado, se queda como lo dejes.
- Sigue funcionando aunque el Mac duerma o reinicies YabaiBar. También se maneja desde el menú.

**Abierta desde cualquier app**

- Desliza 3 o 4 dedos hacia abajo en el trackpad, o pulsa el atajo (⌥I por defecto), y la isla se abre al momento, aunque el puntero esté lejos. El mismo gesto, o el atajo, la cierra.
- Abierta así, se oculta sola a los 3 s si no llevas el puntero hasta ella, y también se cierra con Esc o con un clic en otra app. Si llevas el puntero a la isla, desde ahí se comporta como con el hover.
- Hacia arriba y a los lados no se usan, porque son de Mission Control y del cambio de escritorio (ver [Abrir la isla desde cualquier app](#abrir-la-isla-desde-cualquier-app)).
- El gesto se lee con MultitouchSupport, un framework privado de Apple, porque macOS no ofrece una API pública para gestos de 3 o 4 dedos. Una actualización de macOS podría romperlo; el atajo seguiría funcionando.
- Mientras YabaiBar está abierta, las combinaciones de sus atajos ya no llegan a las demás apps. Con ⌥I y ⌥P, por ejemplo, ya no se escriben "ˆ" ni "π".

**Ajustes**

- "Ajustes…", en el menú de la isla, abre una ventana para cambiar la velocidad de las alas, cómo se abre la isla, si se oculta sola y qué música muestra (ver [Ajustes](#ajustes)).

**Casos especiales**

- Si yabai no responde, la isla muestra "YB ⚠︎" y el menú explica el motivo.
- En un espacio a pantalla completa nativa, la isla se recoge al tamaño del notch.
- Las ventanas minimizadas y las de apps ocultas con ⌘H no cuentan.

## Requisitos

- **Un MacBook con notch:** un MacBook Pro desde 2021 o un MacBook Air desde 2022 (ver [Compatibilidad y hoja de ruta](#compatibilidad-y-hoja-de-ruta)).
- macOS 14 o posterior. Probado en macOS 27.
- [yabai](https://github.com/asmvik/yabai) instalado y en marcha. Instálalo y configúralo leyendo antes [su wiki](https://github.com/asmvik/yabai/wiki):

  ```bash
  brew install asmvik/formulae/yabai
  yabai --start-service
  ```

  YabaiBar solo hace consultas a yabai y añade sus señales, así que **no hace falta la scripting addition** ni desactivar SIP.
- Para el gesto de 3 o 4 dedos, un trackpad. Se ha probado con el integrado del MacBook Pro; el atajo de teclado funciona sin él.

## Instalación

**Con [Homebrew](https://brew.sh):**

```bash
brew install --cask jerickgm89/tap/yabaibar
```

Para actualizarla, `brew upgrade --cask yabaibar`. Para quitarla con sus ajustes, `brew uninstall --zap --cask yabaibar`.

**Con el DMG:** descarga `YabaiBar-<versión>.dmg` de [Releases](https://github.com/jerickgm89/yabaiDynamicIsland/releases), ábrelo y arrastra YabaiBar a Aplicaciones.

**La primera vez.** YabaiBar está firmada con un certificado propio y no está notarizada por Apple, así que macOS la bloquea al abrirla:

1. Ábrela y cierra el aviso.
2. Ve a Ajustes del Sistema › Privacidad y seguridad y pulsa «Abrir igualmente». El botón aparece durante una hora después del aviso.
3. Si prefieres la terminal: `xattr -dr com.apple.quarantine /Applications/YabaiBar.app`.

Solo hay que hacerlo una vez. Las actualizaciones van firmadas con el mismo certificado, así que conservan el permiso de Accesibilidad.

**Primeros pasos.** Al abrirse por primera vez, YabaiBar muestra una ventana que comprueba lo que necesita y dice cómo arreglar lo que falte:

- qué Mac es y cuánto mide su notch, con un botón para copiar esos datos si tienes que abrir un issue;
- si yabai está instalado y en marcha;
- las señales de yabai, que YabaiBar añade sola;
- los atajos «Ir al escritorio N» de Mission Control y el permiso de Accesibilidad, para cambiar de escritorio con un clic;
- Iniciar al arrancar.

Vuelve a abrirla con un clic en la isla › «Primeros pasos…».

## Compatibilidad y hoja de ruta

La isla mide el notch en tu pantalla, así que se ajusta a cada modelo y a la escala que elijas en Ajustes › Pantallas. El ancho del notch en puntos cambia con la escala: en el MacBook Pro de 16" mide 220 pt con «Más espacio» y unos 185 con la escala por defecto.

| | Estado |
| --- | --- |
| MacBook Pro desde 2021: M1 Pro y M1 Max, M2 Pro y M2 Max, M3, M4 y M5 (con sus Pro y Max), de 14" y 16" | Soportado. Probado en el de 16" con M1 Pro |
| MacBook Air desde 2022: M2, M3, M4 y M5, de 13" y 15" | Soportado, sin probar |
| MacBook Pro OLED con Dynamic Island (finales de 2026) | Aún no: no tiene notch y macOS ya pone ahí su propia isla |
| Monitores externos, Macs sin notch y la tapa cerrada | Aún no: la isla se dibuja sobre un notch de reserva |
| Macs con Intel | No se publica |
| macOS 14 a 26 | Sin probar |

«Primeros pasos» dice qué Mac detectó y cuánto mide su notch. Si algo se ve descolocado en el tuyo, abre un [issue](https://github.com/jerickgm89/yabaiDynamicIsland/issues) y pega lo que copia el botón «Copiar datos». Lo próximo:

- monitores externos y Macs sin notch, con un notch decorativo y una isla en cada pantalla;
- pruebas en macOS 14 a 26;
- firma con Developer ID y notarización, para quitar el paso de «Abrir igualmente»;
- entrar en el Homebrew oficial.

## Configuración

### Refresco en tiempo real

La isla se actualiza sola al cambiar de escritorio y al abrir, cerrar, ocultar o activar apps. Para enterarse de lo que solo sabe yabai (crear, cerrar o minimizar ventanas, y los cambios de espacios y pantallas), YabaiBar añade al arrancar unas señales a yabai con `yabai -m signal --add`, sin tocar tu `yabairc`. Si yabai se reinicia, las vuelve a añadir. Se pueden apagar en Ajustes › General › Señales automáticas.

Todas usan la etiqueta `yb_*` y avisan con una notificación Darwin (`notifyutil -p com.jerickdev.yabaibar.refresh`), que llega a la instancia de YabaiBar que esté abierta y, si no hay ninguna, no hace nada. Para verlas:

```bash
yabai -m signal --list
```

Si prefieres tenerlas en tu `yabairc`, apaga el ajuste (YabaiBar las quita de yabai), añade esto y reinicia yabai con `yabai --restart-service`:

```sh
# >>> YabaiBar >>>
YB_ACTION='notifyutil -p com.jerickdev.yabaibar.refresh'
yabai -m signal --add event=window_created label=yb_window_created action="$YB_ACTION"
yabai -m signal --add event=window_destroyed label=yb_window_destroyed action="$YB_ACTION"
yabai -m signal --add event=window_minimized label=yb_window_minimized action="$YB_ACTION"
yabai -m signal --add event=window_deminimized label=yb_window_deminimized action="$YB_ACTION"
yabai -m signal --add event=space_created label=yb_space_created action="$YB_ACTION"
yabai -m signal --add event=space_destroyed label=yb_space_destroyed action="$YB_ACTION"
yabai -m signal --add event=display_added label=yb_display_added action="$YB_ACTION"
yabai -m signal --add event=display_removed label=yb_display_removed action="$YB_ACTION"
yabai -m signal --add event=display_changed label=yb_display_changed action="$YB_ACTION"
# <<< YabaiBar <<<
```

Si usas skhd para mover ventanas entre espacios, puedes añadir el mismo aviso al final de esos atajos, para que la isla se entere al momento:

```sh
shift + alt - 1 : yabai -m window --space 1; notifyutil -p com.jerickdev.yabaibar.refresh
```

### Cambiar de escritorio con clic

Al pulsar una tarjeta, YabaiBar pulsa por ti el atajo "Ir al escritorio N" de Mission Control, así que el cambio usa la animación nativa de macOS. Para que funcione:

1. Activa los atajos en Ajustes del Sistema › Teclado › Atajos de teclado › Mission Control. Las tarjetas de los escritorios sin atajo muestran "Sin atajo".
2. Da permiso de Accesibilidad a YabaiBar. El primer clic muestra el aviso de macOS; después, actívala en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad.

«Primeros pasos» comprueba las dos cosas. Si el permiso está marcado pero el clic no cambia de escritorio, la firma de la app cambió (por ejemplo, porque la compilaste tú): quita YabaiBar de la lista con "−" y vuelve a pulsar una tarjeta para que la pida de nuevo.

### Abrir la isla desde cualquier app

El gesto y el atajo funcionan nada más abrir la app, sin permisos.

- **Gesto:** desliza 3 o 4 dedos hacia abajo en el trackpad. Para que no choque con macOS, deja libre ese movimiento:
  - En Ajustes del Sistema › Trackpad › Más gestos, App Exposé tiene que estar desactivado, porque usa el mismo movimiento hacia abajo. Mission Control (hacia arriba) y el cambio de escritorio (a los lados) no molestan.
  - En Ajustes del Sistema › Accesibilidad › Control del puntero, no actives "Arrastrar con tres dedos": con 3 dedos hacia abajo arrastrarías lo que haya bajo el puntero.
- **Atajo:** ⌥I por defecto. Cámbialo en Ajustes si choca con otra app, o si usas ⌥I para escribir el circunflejo (ˆ). Si macOS no acepta la combinación, la ventana de ajustes lo dice.

### Ajustes

Haz clic en la isla y elige "Ajustes…". La ventana tiene tres pestañas, General, Música y Pomodoro. Los cambios se aplican al momento y se guardan para la próxima vez.

<p align="center">
  <img src="assets/ajustes.png" width="470" alt="La ventana de ajustes: velocidad de las alas en Normal, atajo ⌥I, Ocultar sola activado y al cabo de 3 s">
</p>

| Ajuste | Qué hace | Por defecto |
| --- | --- | --- |
| Señales automáticas | YabaiBar añade a yabai las señales que refrescan la isla (ver [Refresco en tiempo real](#refresco-en-tiempo-real)) | Activado |
| Velocidad de las alas | Lo que tardan las alas en recogerse y volver a salir al cambiar de escritorio: Lenta, Normal, Rápida o Sin animación | Normal |
| Al pasar el puntero | Si está apagado, la isla solo se abre con el atajo o el gesto | Activado |
| Atajo | La combinación que abre y cierra la isla desde cualquier app. Pulsa el botón y luego la combinación nueva; Esc cancela y ⌫ lo quita | ⌥I |
| Ocultar sola | Abierta con el atajo o el gesto, la isla se cierra sola si no llevas el puntero hasta ella | Activado |
| Al cabo de | Los segundos que espera antes de ocultarse, de 1 a 10 | 3 s |
| Mostrar lo que suena | La franja de música de la isla abierta. Apagada, el adaptador de música no se ejecuta | Activado |
| De | Cualquier app o solo TIDAL | Cualquier app |
| Barras en la isla cerrada | Las barras al final del ala derecha mientras hay música | Activado |
| Avisar al cambiar de canción | La carátula y el título durante 3 s en la isla cerrada | Activado |
| Batería y cargador | Los avisos al enchufar o desenchufar el cargador y con poca batería | Activado |
| Botón de mantener despierto | El sol de la isla abierta. Al apagarlo, el Mac deja de mantenerse despierto | Activado |
| Mostrar el Pomodoro | El temporizador y su franja en la isla abierta. Al apagarlo se termina la sesión | Activado |
| Atajo del Pomodoro | La combinación que lo empieza, pausa o reanuda desde cualquier app. Se graba como el de la isla | ⌥P |
| Anillo en la isla cerrada | El anillo de progreso al final del ala derecha mientras hay sesión | Activado |
| Preset y tiempos | Foco (5–90 min), descanso corto (1–30), descanso largo (5–60) y cada cuántos focos toca el largo (2–8) | Clásico: 25/5/15, cada 4 |
| Empezar solos | Si los descansos y el foco empiezan solos al terminar la fase anterior | Descansos sí, foco no |
| Avisar antes de terminar | Segundos antes del final de cada fase: no, 10, 15, 30 o 60 | 30 s |
| Objetivo del día | Cuántos pomodoros quieres hacer hoy (1–16) | 8 |
| Sonidos | La kalimba del aviso, y el cuenco o las dos notas al terminar cada fase | Activado |
| Bajar la música en el aviso | Si suena música, el volumen baja desde el aviso hasta el final de la fase | Activado, al 35 % |

## Desarrollo

### Compilar desde el código

Hace falta Xcode con Swift 6 y [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). El proyecto se genera a partir de `project.yml`; el `.xcodeproj` no se versiona. Para compilar la versión Release, instalarla en `/Applications` y abrirla:

```bash
git clone https://github.com/jerickgm89/yabaiDynamicIsland.git
cd yabaiDynamicIsland
xcodegen generate
xcodebuild -project YabaiBar.xcodeproj -scheme YabaiBar -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/YabaiBar.app /Applications/YabaiBar.app
open /Applications/YabaiBar.app
```

Si `xcodebuild` dice que necesita Xcode y no las Command Line Tools, apunta `xcode-select` a Xcode con `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. Si prefieres trabajar en Xcode, abre `YabaiBar.xcodeproj` después de `xcodegen generate`. Después de cambiar `project.yml` o de añadir archivos, vuelve a ejecutar `xcodegen generate`.

**Firma (opcional, recomendada).** El permiso de Accesibilidad queda ligado a la firma de la app. Con la firma ad-hoc, la firma cambia en cada compilación y macOS deja de reconocer el permiso. Para evitarlo, crea un certificado autofirmado:

1. Abre Acceso a Llaveros y ve a Asistente de certificados › Crear un certificado.
2. Llámalo **YabaiBar Dev**, con tipo de identidad "Raíz autofirmada" y tipo de certificado "Firma de código".
3. Ábrelo y, en Confiar, marca "Firma de código" como "Confiar siempre".

Después añade `CODE_SIGN_IDENTITY="YabaiBar Dev"` al final del comando `xcodebuild`. Sin esa opción, la app se firma ad-hoc. Una copia compilada así tiene otra firma que la de los releases: si cambias de una a otra, tendrás que volver a dar el permiso de Accesibilidad.

### Publicar una versión

`scripts/release.sh` compila la Release firmada, comprueba la firma, que sea solo arm64 y que no lleve lo de DEBUG, hace el DMG, lo sube a GitHub Releases con las notas de `CHANGELOG.md` y actualiza el cask de [jerickgm89/homebrew-tap](https://github.com/jerickgm89/homebrew-tap):

```bash
scripts/release.sh 3.0.0 --dry-run   # todo menos publicar: el DMG y las notas quedan en build/release
scripts/release.sh 3.0.0             # pide confirmación antes del commit, el tag, el push y el release
```

Antes hay que añadir la sección de la versión a `CHANGELOG.md`. Todas las versiones se firman con el certificado autofirmado **YabaiBar Release** (o el de `SIGN_IDENTITY`), creado como el de arriba y válido 10 años. Guarda una copia (`.p12`, con su clave privada) en un sitio seguro: si se pierde o caduca, cada usuario tendrá que volver a aprobar la app y a darle Accesibilidad.

### Tests, logs y refresco

```bash
# Tests
xcodebuild -project YabaiBar.xcodeproj -scheme YabaiBar -destination 'platform=macOS' -derivedDataPath build test

# Logs de los últimos 2 minutos
/usr/bin/log show --last 2m --predicate 'subsystem == "com.jerickdev.yabaibar"' --info

# Forzar un refresco
notifyutil -p com.jerickdev.yabaibar.refresh
```

En la build Debug, la URL `yabaibar://snapshot` (o `yabaibar://snapshot?abierta`, `?aviso` para el aviso de canción nueva o `?aviso-pomodoro`) guarda una imagen de la isla en `~/Library/Caches/com.jerickdev.yabaibar/bar.png`, y `yabaibar://snapshot?bienvenida`, una de «Primeros pasos» en `welcome.png`.

**Estructura**

- `YabaiBar/`: el código de la app.
  - `YabaiClient` ejecuta yabai fuera del hilo principal y decodifica el JSON.
  - `SpaceGrouper` agrupa ventanas por espacio.
  - `SpacesStore` publica el estado.
  - `YabaiSignals` añade y quita las señales de yabai.
  - `SetupChecklist` decide qué dice cada requisito y `WelcomeWindow` muestra «Primeros pasos».
  - `NotchGeometry` e `IslandLayout` calculan la geometría.
  - `IslandView` dibuja la isla e `IslandController` la coloca y la anima.
  - `TrackpadMonitor` (con `FingerSwipeDetector`) y `GlobalHotKey` la abren desde cualquier app.
  - `AppSettings` guarda los ajustes y `SettingsWindow` los muestra.
  - `MediaRemoteAdapter` ejecuta el adaptador de música, `NowPlayingParser` entiende lo que manda y `NowPlayingStore` lo publica para la isla.
  - `BatteryMonitor` y `KeepAwake` se encargan de las actividades del sistema.
  - `PomodoroTimer` es la lógica del Pomodoro y `PomodoroStore` lo pone en marcha.
  - `CueSynth` sintetiza los sonidos, `VolumeDucker` baja y sube el volumen y `PomodoroCue` decide qué hacer en cada aviso.
- `Vendor/mediaremote-adapter/`: el código de mediaremote-adapter, sin cambios y con su licencia. Lo compila el target `MediaRemoteAdapter` de `project.yml`.
- `YabaiBarTests/`: tests con Swift Testing y fixtures JSON reales de yabai. Se ejecutan dentro de la app, que también consulta el yabai real.
- `scripts/release.sh` y `packaging/`: el script de publicación, la plantilla de las notas y la del cask de Homebrew.
- `CHANGELOG.md`: los cambios de cada versión.
- `assets/`: las capturas de este README.

## Agradecimientos

**[Atoll](https://github.com/Ebullioscopic/Atoll)**, de Hariharan Mudaliar ([@Ebullioscopic](https://github.com/Ebullioscopic)) y su comunidad. Atoll nos ayudó muchísimo con el diseño de la isla. De él aprendimos cómo colocar la ventana sobre el notch y en todos los escritorios, la forma de la isla y sus radios, el crecimiento con hover, la vibración del trackpad y las curvas de las animaciones al abrirse y cerrarse. Sin su trabajo, YabaiBar no se vería ni se movería así. ¡Gracias!

Atoll se publica con licencia GPL-3.0 y deriva de [boring.notch](https://github.com/TheBoredTeam/boring.notch), así que también va nuestro agradecimiento a TheBoredTeam. YabaiBar toma de ellos ideas, medidas y curvas de animación, pero no copia su código: toda la implementación está escrita desde cero.

**[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)**, de Jonas van den Berg y sus colaboradores, que permite leer y controlar "Ahora suena" desde macOS 15.4. Va incluido en `Vendor/` con su licencia BSD-3-Clause.

**[yabai](https://github.com/asmvik/yabai)**, que hace posible todo lo demás.

## Licencia

YabaiBar se publica con licencia [MIT](LICENSE): puedes usarla, modificarla y redistribuirla, siempre que conserves el aviso de copyright. El código de `Vendor/mediaremote-adapter/` conserva su propia licencia, [BSD-3-Clause](Vendor/mediaremote-adapter/LICENSE).
