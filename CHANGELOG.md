# Cambios

Las versiones de YabaiBar. La 3.0.0 es la primera que se instala sin compilar: con Homebrew o con el DMG de [Releases](https://github.com/jerickgm89/yabaiDynamicIsland/releases). `scripts/release.sh` copia la sección de cada versión en las notas de su release.

## [3.2.0] - 2026-11-04

- **Atajos de escritorio automáticos:**
  - Al crear un escritorio del 1 al 9 sin el atajo «Ir al escritorio N» de Mission Control, YabaiBar pregunta si lo añade, con el mismo modificador que los demás (⌥5 si los otros son ⌥1 a ⌥4).
  - Con «Añadir siempre», los escritorios nuevos lo reciben solos y la isla lo dice.
  - También desde la tarjeta «Añadir atajo» y desde «Primeros pasos».
  - Solo añade los que faltan y antes guarda una copia de tus atajos.
- **Mission Control:** la isla se oculta, como la barra de menús. Antes, al pasar el puntero por ella, se abría y se cerraba varias veces.
- **Escritorios nuevos al momento:** los que se crean o se quitan en Mission Control salen en la isla al cerrarlo, sin tener que cambiar de escritorio.

## [3.1.0] - 2026-11-04

- **Todos los MacBook con notch:** MacBook Pro desde 2021 (de M1 Pro a M5 Max) y MacBook Air desde 2022 (de M2 a M5). La isla ya medía el notch en la pantalla, así que se ajusta a cada modelo y a cada escala de pantalla. Ahora «Primeros pasos» reconoce el modelo y dice cuánto mide su notch.
- **«Copiar datos»** en «Primeros pasos»: el modelo, las pantallas y el notch medido, para pegarlos en un issue si algo se ve descolocado.
- **Escalas de texto grande:** si el notch es muy bajo, el contenido de las alas y los botones de las esquinas se encogen para caber. Si hay muchos espacios en una pantalla estrecha, las tarjetas muestran menos íconos.

## [3.0.0] - 2026-11-04

La primera versión instalable: ya no hace falta Xcode ni tocar el `yabairc`.

- **Se instala sin compilar:** `brew install --cask jerickgm89/tap/yabaibar`, o el DMG de esta página.
- **Señales de yabai automáticas:** YabaiBar le pide a yabai que la avise al crear, cerrar o minimizar ventanas y al cambiar los espacios o las pantallas, sin tocar tu `yabairc`. Si yabai se reinicia, las vuelve a añadir. Se apagan en Ajustes › General.
- **Primeros pasos:** una ventana que se abre la primera vez (y después desde el menú) y comprueba si el Mac está soportado, yabai instalado y en marcha, las señales, los atajos «Ir al escritorio» de Mission Control, el permiso de Accesibilidad e Iniciar al arrancar. Cada fila dice cómo arreglarlo.
- **Solo Apple Silicon** y, por ahora, solo los MacBook Pro de 2021 con M1 Pro o M1 Max y notch.

## [2.11.0] - 2026-11-03

- Atajo global del Pomodoro (⌥P por defecto): inicia, pausa o reanuda desde cualquier app, y la isla cerrada dice cómo quedó.

## [2.10.0] - 2026-11-03

- El Pomodoro avisa con sonido: una nota de kalimba 30 s antes del final, un cuenco al terminar el foco y dos notas al terminar el descanso.
- Si suena música, el volumen baja poco a poco en el aviso y vuelve al terminar. Si tocas el volumen mientras está bajado, se queda como lo dejes.

## [2.9.0] - 2026-11-03

- El Pomodoro en la isla cerrada: un anillo de progreso al final del ala derecha y un aviso al cambiar de fase.

## [2.8.0] - 2026-11-03

- Pomodoro en la isla abierta: foco y descansos, presets Clásico, Largo y Corto, empezar solo, aviso antes del final y objetivo del día.

## [2.7.1] - 2026-11-03

- El adaptador de música ya no se queda abierto cuando YabaiBar se cierra de golpe.

## [2.7.0] - 2026-11-03

- Avisos del cargador y de la batería baja (20 % y 10 %) en la isla cerrada.
- Un sol en la isla abierta que mantiene el Mac despierto.

## [2.6.0] - 2026-11-03

- La música en la isla cerrada: barras mientras suena y la carátula y el título 3 s al cambiar de canción.
- Dos dedos de lado sobre la franja de música cambian de canción.

## [2.5.0] - 2026-11-03

- «Ahora suena» en la isla abierta: carátula, título, artista, progreso y botones, con TIDAL o cualquier app del «Ahora suena» de macOS.

## [2.4.0] - 2026-11-03

- Ventana de ajustes: velocidad de las alas, atajo para abrir la isla y ocultarla sola.

## [2.3.0] - 2026-11-03

- Abrir la isla desde cualquier app con 3 o 4 dedos hacia abajo en el trackpad o con ⌥I.

## [2.2.0] - 2026-11-02

- Tarjetas con hover; un clic en una tarjeta cambia a ese escritorio con la animación de macOS.

## [2.1.0] - 2026-11-02

- Fuente SF Pro; las alas se recogen hacia el notch al cambiar de escritorio.

## [2.0.0] - 2026-11-02

- La isla alrededor del notch, que se abre al pasar el puntero y muestra una tarjeta por espacio.

## [1.0.0] - 2026-11-02

- Los espacios de yabai en la barra de menús, con los íconos de sus apps.
