# YabaiBar

Una isla alrededor del notch del Mac que muestra los espacios de [yabai](https://github.com/asmvik/yabai), con los íconos de sus apps, y resalta el activo. Es una app nativa de macOS escrita en Swift 6 con SwiftUI y AppKit.

La isla vive por encima de la barra de menús, nace del notch como la Dynamic Island y está en todos los escritorios. Su diseño se inspira en [Atoll](https://github.com/Ebullioscopic/Atoll) (ver [Agradecimientos](#agradecimientos)).

<p align="center">
  <img src="docs/images/isla-cerrada.png" width="640" alt="La isla cerrada: el espacio 3 activo con su app a la izquierda del notch y los espacios 1, 2 y 4 a la derecha">
</p>

<p align="center">
  <img src="docs/images/isla-abierta.png" width="820" alt="La isla abierta: una tarjeta por espacio con su número, sus apps y su atajo, con el puntero sobre la tarjeta 1">
</p>

## Qué hace

**Cerrada (siempre visible)**

- A la izquierda del notch, el espacio activo: su número en el color del espacio y los íconos de sus apps (hasta 3, y "+n" si hay más).
- A la derecha, los espacios inactivos. Los que tienen ventanas llevan un punto de su color; los vacíos se ven apagados.
- Las dos alas miden lo mismo, para que la isla quede centrada en el notch.
- Cada espacio tiene su color, de una paleta inspirada en el tema liquid-glass.

**Al cambiar de escritorio**

- En cuanto empieza el cambio (con ⌥N o al iniciar el gesto del trackpad), las alas se recogen hacia el notch y la isla se desvanece.
- Al llegar al escritorio nuevo, las alas vuelven a salir con el contenido actualizado.
- Con "Reducir movimiento" activado, el contenido solo se funde.

**Abierta (al pasar el puntero)**

- Al entrar el puntero, la isla crece un poco y el trackpad vibra.
- Si el puntero se queda encima, la isla se abre hacia abajo y muestra una tarjeta por espacio, con su número, sus apps y su atajo de teclado.
- Al pasar sobre una tarjeta, esta se ilumina; al hacer clic, macOS cambia a ese escritorio con su animación nativa.
- El clic derecho, o cualquier clic fuera de las tarjetas, abre el menú: el error de yabai si lo hay, Refrescar, Iniciar al arrancar y Salir.

**Casos especiales**

- Si yabai no responde, la isla muestra "YB ⚠︎" y el menú explica el motivo.
- En un espacio a pantalla completa nativa, la isla se recoge al tamaño del notch.
- Las ventanas minimizadas y las de apps ocultas con ⌘H no cuentan.

## Requisitos

- macOS 14 o posterior. La isla está pensada para Macs con notch. En pantallas sin notch usa un notch imaginario de 180 × 32 pt centrado arriba, que todavía no se ha probado a fondo.
- [yabai](https://github.com/asmvik/yabai) v7 instalado en `/opt/homebrew/bin/yabai` o `/usr/local/bin/yabai`. Solo se usan consultas (`yabai -m query`), así que **no hace falta la scripting addition** ni desactivar SIP.
- Para compilar: Xcode con Swift 6 y [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Instalación

El proyecto se genera con XcodeGen a partir de `project.yml`; el `.xcodeproj` no se versiona. El script `yb.sh` lo regenera, compila y ejecuta:

```bash
git clone git@github.com:jerickgm89/yabaiDynamicIsland.git
cd yabaiDynamicIsland
.claude/skills/build-run/scripts/yb.sh install
```

`install` compila la versión Release, la copia en `/Applications/YabaiBar.app` y la abre. La opción "Iniciar al arrancar" del menú solo está disponible desde `/Applications`.

Si prefieres Xcode, ejecuta `xcodegen generate` y abre `YabaiBar.xcodeproj`.

### Firma (opcional, recomendada)

El permiso de Accesibilidad (ver abajo) queda ligado a la firma de la app. Con la firma ad-hoc, la firma cambia en cada compilación y macOS deja de reconocer el permiso. Para evitarlo, crea un certificado autofirmado:

1. Abre Acceso a Llaveros y ve a Asistente de certificados › Crear un certificado.
2. Llámalo **YabaiBar Dev**, con tipo de identidad "Raíz autofirmada" y tipo de certificado "Firma de código".
3. Ábrelo y, en Confiar, marca "Firma de código" como "Confiar siempre".

Si el certificado existe, `yb.sh` firma con él; si no, firma ad-hoc y avisa.

## Configuración

### Refresco en tiempo real

La app ya se actualiza sola al cambiar de escritorio y al abrir, cerrar, ocultar o activar apps. Para que también reaccione al crear, cerrar o minimizar ventanas, y a los cambios de espacios y pantallas, añade estas señales a tu `yabairc`:

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

El aviso es una notificación Darwin: llega a la instancia de YabaiBar que esté abierta y, si no hay ninguna, no hace nada. Si usas skhd para mover ventanas entre espacios, añade el mismo aviso al final de esos atajos:

```sh
shift + alt - 1 : yabai -m window --space 1; notifyutil -p com.jerickdev.yabaibar.refresh
```

### Cambiar de escritorio con clic

Al pulsar una tarjeta, YabaiBar pulsa por ti el atajo "Ir al escritorio N" de Mission Control, así que el cambio usa la animación nativa de macOS. Para que funcione:

1. Activa los atajos en Ajustes del Sistema › Teclado › Atajos de teclado › Mission Control. Las tarjetas de los escritorios sin atajo muestran "Sin atajo".
2. Da permiso de Accesibilidad a YabaiBar. El primer clic muestra el aviso de macOS; después, actívala en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad.

Si el permiso está marcado pero el clic no cambia de escritorio, la firma de la app cambió: quita YabaiBar de la lista con "−" y vuelve a pulsar una tarjeta para que la pida de nuevo.

## Desarrollo

`yb.sh` agrupa las tareas habituales:

| Comando | Qué hace |
| --- | --- |
| `yb.sh build [Debug\|Release]` | Regenera el proyecto y compila |
| `yb.sh test` | Ejecuta los tests |
| `yb.sh run` | Compila en Debug y relanza la app |
| `yb.sh stop` | Cierra la app |
| `yb.sh logs [2m]` | Muestra los logs recientes de la app |
| `yb.sh snapshot [abierta\|hover]` | Guarda una imagen de la isla (solo Debug) |
| `yb.sh refresh` | Envía el aviso de refresco |
| `yb.sh install` | Compila en Release e instala en `/Applications` |
| `yb.sh clean` | Borra `build/` |

**Estructura**

- `YabaiBar/`: el código de la app.
  - `YabaiClient` ejecuta yabai fuera del hilo principal y decodifica el JSON.
  - `SpaceGrouper` agrupa ventanas por espacio.
  - `SpacesStore` publica el estado.
  - `NotchGeometry` e `IslandLayout` calculan la geometría.
  - `IslandView` dibuja la isla e `IslandController` la coloca y la anima.
- `YabaiBarTests/`: tests con Swift Testing y fixtures JSON reales de yabai. Se ejecutan dentro de la app, que también consulta el yabai real.
- `docs/`: el plan de la versión 1 (barra de menús, [PLAN.md](docs/PLAN.md)) y el de la versión 2 (la isla, [PLAN-ISLA.md](docs/PLAN-ISLA.md)), con las medidas y las decisiones de diseño.
- `.claude/`: los agentes y skills de [Claude Code](https://claude.com/claude-code) con los que se desarrolló el proyecto.

## Agradecimientos

**[Atoll](https://github.com/Ebullioscopic/Atoll)**, de Hariharan Mudaliar ([@Ebullioscopic](https://github.com/Ebullioscopic)) y su comunidad. Atoll nos ayudó muchísimo con el diseño de la isla. De él aprendimos cómo colocar la ventana sobre el notch y en todos los escritorios, la forma de la isla y sus radios, el crecimiento con hover, la vibración del trackpad y las curvas de las animaciones al abrirse y cerrarse. Sin su trabajo, YabaiBar no se vería ni se movería así. ¡Gracias!

Atoll se publica con licencia GPL-3.0 y deriva de [boring.notch](https://github.com/TheBoredTeam/boring.notch), así que también va nuestro agradecimiento a TheBoredTeam. YabaiBar toma de ellos ideas, medidas y curvas de animación, pero no copia su código: toda la implementación está escrita desde cero.

**[yabai](https://github.com/asmvik/yabai)**, que hace posible todo lo demás.
