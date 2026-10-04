# GearLink

Addon para **World of Warcraft: Forever** que conecta a tus amigos: mira su equipo, descubre qué items de tus bolsas les sirven y ofréceselos con un click.

> Versión beta para grupos de amigos. Cualquier error, avísale a quien te pasó el addon (idealmente con una captura de **BugSack**).

## Qué hace

- **Mi equipo**: ficha estilo personaje con tu modelo 3D, nivel de item de cada slot y nivel de objeto promedio. Detecta tu rol y stat principal desde tus talentos (o los eliges a mano).
- **Amigos**: detecta automáticamente a tus amigos (de personaje y de Battle.net) que tienen GearLink, y puedes agregar contactos a mano (`Nombre-Apellido`).
- **Ficha de un amigo**: click en un contacto para ver su equipo y sus bolsas, aunque esté desconectado (últimos datos guardados).
- **Le sirve a…**: un 🎁 junto a los items de tus bolsas que son una mejora para un amigo, y una línea en el tooltip: *"GearLink - le sirve a: Pedro"*. Compara nivel de item, tipo de armadura y arma, nivel requerido y stat principal.
- **Ofrecer**: click en el 🎁 → se abre el chat con el mensaje escrito y a tu amigo le aparece un aviso para **Aceptar** o **No, gracias**. Una oferta por item a la vez.
- **Entregas por correo**: si tu amigo acepta, al abrir un buzón GearLink te prepara el correo (destinatario, asunto e item adjunto).
- **Botón en el minimapa**: click izquierdo abre GearLink, click derecho va directo a tus amigos.

## Instalación

### Opción A: WowUp (se actualiza solo)
1. En [WowUp](https://wowup.io), elige tu instalación de Forever.
2. **Get Addons → Install from URL** y pega: `https://github.com/suprahh/GearLink`

### Opción B: manual
1. Descarga el `GearLink-x.y.z.zip` más reciente desde [Releases](https://github.com/suprahh/GearLink/releases).
2. Descomprímelo en `World of Warcraft\_classic_beta_\Interface\AddOns\`.
   Debe quedar así: `AddOns\GearLink\GearLink.toc` (sin una carpeta `GearLink` dentro de otra).
3. En la pantalla de personajes, botón **AddOns**: verifica que **GearLink** esté activado.

Recomendado: instala también **BugSack** + **!BugGrabber** para ver errores sin que te interrumpan.

## Primeros pasos

1. Entra al juego y escribe `/gl` (o click en el botón del minimapa).
2. Pestaña **Amigos**: tus amigos con GearLink aparecen solos en unos segundos. Para alguien que no es tu amigo en el juego, escribe su `Nombre-Apellido` y pulsa **Agregar** (ambos deben agregarse).
3. La casilla **Sug.** de cada contacto decide si GearLink te sugiere items para esa persona.

## Comandos

| Comando | Qué hace |
|---|---|
| `/gl` | Abrir / cerrar la ventana |
| `/gl add Nombre-Apellido` | Agregar un contacto a mano |
| `/gl remove Nombre-Apellido` | Quitar un contacto manual |
| `/gl friends` | Listar tus contactos |
| `/gl share on` / `off` | Compartir o no tus bolsas (si está en `off`, solo se ve tu equipo) |
| `/gl offers on` / `off` | Recibir o no ofertas de tus contactos |
| `/gl notify on` / `off` | Aviso y sonido cuando recibes loot que le sirve a un amigo |
| `/gl offermode chat` / `direct` | Abrir el chat con la oferta escrita, o enviarla directo |
| `/gl template [texto]` | Ver o cambiar el mensaje de oferta (`%item%`, `%reason%`, `%slot%`, `%name%`) |
| `/gl accepttemplate [texto]` | Ver o cambiar el mensaje al aceptar (`%item%`, `%zone%`, `%reason%`) |
| `/gl deliveries` | Ver las entregas pendientes por correo |
| `/gl role tank` / `healer` / `damager` / `auto` | Fijar tu rol a mano |
| `/gl stat str` / `agi` / `int` / `auto` | Fijar tu stat principal a mano |
| `/gl minimap` | Mostrar u ocultar el botón del minimapa |
| `/gl eval` | Ver por qué cada item le sirve (o no) a cada amigo |
| `/gl debug` | Mensajes de diagnóstico (útil para reportar problemas) |
| `/gl help` | Lista completa de comandos |

## Privacidad

- GearLink **solo** habla con tus contactos (amigos del juego, de Battle.net o agregados a mano). Los mensajes de cualquier otra persona se ignoran.
- Por defecto compartes tu **equipo y tus bolsas**. Usa `/gl share off` para compartir solo el equipo.
- Nadie recibe whispers automáticos: las ofertas salen **solo** cuando tú haces click.

## Limitaciones conocidas (beta)

- Los servidores de la beta a veces entregan whispers y mensajes de addon con hasta ~30 s de demora. GearLink espera y reintenta, pero el aviso de una oferta puede tardar.
- Algunos bonus "Equipar:" (poder con hechizos, golpe %) no se cuentan todavía al comparar stats; el nivel de item manda.
- Los items ligados con ventana de intercambio (loot de grupo) no se pueden enviar por correo: solo intercambio en persona.

## Créditos

Usa las librerías **Ace3** (AceAddon, AceDB, AceEvent, AceConsole, AceComm), **CallbackHandler**, **LibStub**, **ChatThrottleLib**, **LibSerialize**, **LibDeflate**, **LibDataBroker** y **LibDBIcon**, cada una bajo su propia licencia y de sus respectivos autores.
