# A50 Control — controlador para ASTRO A50 Gen 4 en macOS

<img src="docs/logo.png" width="96" align="right" alt="Logo de A50 Control">

**English, in short:** a free, independent macOS menu-bar app and Swift library to control the ASTRO A50 Gen 4 base station
(USB `9886:002c`, base switch on **PC**): 3 EQ presets, game/chat balance, microphone, sidetone, noise gate, stream port,
auto-shutoff, brightness, profiles, battery alerts and a USB/mic diagnostic. It talks to the base over its HID control
channel: no drivers, no kernel extensions, **no firmware writes**. Free for non-commercial use
([PolyForm Noncommercial 1.0.0](LICENSE)). Not affiliated with Logitech or ASTRO. The docs below are in Spanish.

---

Sustituye al ASTRO Command Center (una app Qt solo x86_64 de 2021) con una app nativa de barra de menús. Habla directamente
con la base por su canal HID de control (usage page `0xFF32`). Sin drivers ni extensiones del kernel. Único permiso de
macOS: el micrófono, y solo si usas «Probar micrófono».

## Qué hace

- **Ecualizador** de 5 bandas ×3 presets, con editor gráfico, importación/exportación `.astroeq` (el formato del Command
  Center) y 13 predefinidos (`EQLibrary`).
- **Mezcla juego↔chat, micrófono, sidetone, puerta de ruido, EQ del micro y volumen de avisos.**
- **Puerto de stream** (salida analógica trasera): micrófono, chat, juego y aux, con silenciar.
- **Apagado automático** (10/15/20/25/30 min) y **brillo** de la base (la base acepta 20–70).
- **Perfiles** (`.a50perfil`, texto editable): toda la configuración en un fichero; un fichero defectuoso se rechaza sin tocar la base.
- **Estado en vivo** (batería, firmware, enlace) y **avisos de batería baja**.
- **Diagnóstico** de voz robótica y cortes: registro de incidencias, lectura de la corriente que concede el USB y una prueba
  de micrófono de 10 s que busca huecos de silencio digital.
- **CLI** `a50ctl` para scripts: `a50ctl help`.

## Compatibilidad

- **Base A50 Gen 4 con el interruptor trasero en PC** (`9886:002c`). Es lo único probado, con una base de PlayStation/PC.
- Con el interruptor en **PS** la base se presenta como `9886:002b`, solo con audio y **sin canal de control**: A50 Control no
  la ve. Para configurarla, en PC; lo guardado se conserva al volver a PS (comprobado).
- **Xbox: no soportado ni probado.** La base Xbox es otro modelo y no sé qué ID USB usa. `a50ctl usb` imprime el ID y las
  interfaces de cualquier base Astro conectada: si tienes una, abre una incidencia con esa salida.
- macOS 14 o superior. Binario universal (Apple Silicon e Intel).

## Instalar

**Descarga** el `.zip` de la sección *Releases*, descomprímelo y arrastra `A50 Control.app` a Aplicaciones. La app no está
notarizada por Apple, así que la primera vez macOS la bloquea: pulsa con el botón derecho → *Abrir*, o ejecuta
`xattr -dr com.apple.quarantine "/Applications/A50 Control.app"`.

**O compílala** (Xcode o las Command Line Tools):

```sh
./build-app.sh --instalar     # compila universal, firma ad-hoc y copia a ~/Applications/A50 Control.app
swift build -c release        # solo la librería y el CLI
```

Quitarla: borra la app y, si lo activaste, «Abrir al iniciar sesión» en su menú.

## Lo que conviene saber

- **Activo ≠ guardado.** Todo cambio suena al instante, pero se pierde al reiniciar la base hasta que pulses **«Guardar en la
  base»** (`a50ctl save`).
- **No abras el Command Center a la vez.** Cada cliente HID recibe todas las respuestas de la base, así que dos programas se
  pisan. A50 Control lo evita entre sus propios procesos con un cerrojo; el Command Center no lo usa y toma la base en exclusiva.
- **No escribe firmware.** Por diseño no incluye actualizador: si fallara a mitad, la base podría quedar inservible.
- **No toca nada de consolas ni de licencias.** Solo configura la base como dispositivo USB.
- Rangos de la Gen 4: ganancia ±7 dB, 80–15 000 Hz, ancho 0,1–3,0 (×frecuencia). La curva del editor es aproximada.
- Cambiar de preset tarda 80–400 ms en hacerse efectivo; la app lo tiene en cuenta.
- Radio e interferencias **no se pueden medir**: la base no expone la calidad del enlace.
- Los 8 predefinidos propios son valores de manual, no medidos en la A50. Los 5 «de fábrica» son los del Command Center, incluidos como datos.

## Lo que no está probado

- Los avisos de batería baja (requieren que la batería baje del 20 %).
- El arranque sin ventana al iniciar sesión (heurística de uptime).
- Que el analizador de cortes detecte un episodio real de voz robótica (solo validado con señal sintética: `a50ctl diag selftest`).
- Que el apagado automático y el brillo sobrevivan a un reinicio de la base.
- Cualquier base Xbox.

## Piezas

| Pieza | Qué es |
|---|---|
| `A50Kit` | Librería Swift con el protocolo: batería, estado, EQ, balance, micrófono, stream, apagado, brillo, perfiles, guardar. |
| `a50ctl` | CLI para scripts y para explorar. |
| `A50 Control.app` | App de barra de menús y ventana de panel. |

Modos de prueba: `A50Control --autotest <informe.txt>`, `--autotest-ventana`, `--autotest-diag`, `--capturar <carpeta>`;
CLI: `a50ctl eq library test`, `a50ctl profile test`, `a50ctl diag selftest`; `./probar-con-la-base.sh` lanza las tres contra tu base
(interruptor en PC). Las pruebas con la base **dejan todo como estaba**.

## Créditos, marcas y licencia

El protocolo parte de la ingeniería inversa de [eh-fifty](https://github.com/tdryer/eh-fifty) de Tom Dryer (MIT), contrastada
aquí contra el aparato real. Proyecto independiente: **ASTRO, A50 y Logitech son marcas de sus propietarios y este proyecto
no está afiliado ni respaldado por ellos.** Se nombran solo para indicar con qué aparato funciona.

Licencia: [PolyForm Noncommercial 1.0.0](LICENSE). Gratis para uso no comercial; el uso comercial no está permitido. No es
«software libre» según la OSI, es código disponible. Sin garantía: úsalo bajo tu responsabilidad; si algo se descontrola,
reconecta la base y reinicia los auriculares manteniendo «game» y «Dolby» 15 s.

Required Notice: Copyright 2026 Cristian Sanchez (https://cristianprograma.com)
