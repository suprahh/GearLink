# Seguridad de GearLink

## Reportar un problema de seguridad

Si encuentras algo que pueda afectar a quienes usan GearLink, **no abras un issue público**.
Usa **Security → Report a vulnerability** en este repositorio (reporte privado) y lo revisaré lo antes posible.

## Qué puede y qué no puede hacer un addon de WoW

GearLink es un addon de World of Warcraft: corre dentro del entorno restringido del juego.

- **No puede** leer archivos de tu PC, tus contraseñas, tu cuenta de Battle.net ni conectarse a internet fuera del juego.
- **Sí puede** actuar dentro del juego en tu nombre: mandar whispers y mensajes de addon, preparar correos, etc.
  Por eso GearLink:
  - solo envía whispers u ofertas **cuando tú haces click**;
  - solo acepta mensajes de **tus contactos** (amigos del juego, de Battle.net o agregados a mano) y valida todo lo que recibe;
  - nunca envía un correo por sí solo: prepara el formulario y **tú** pulsas *Enviar*.

## Cómo se protege el código

- La rama `main` está protegida: nadie hace push directo y todo cambio entra por Pull Request revisado por @suprahh.
- Solo @suprahh puede crear tags de versión; las releases las arma GitHub Actions a partir de un tag en `main`, y cada release publica el SHA256 de su ZIP.
- Las releases son inmutables: el ZIP publicado no se puede reemplazar después.

## Descarga segura

Descarga GearLink **solo** desde [github.com/suprahh/GearLink/releases](https://github.com/suprahh/GearLink/releases)
(o con WowUp apuntando a esa URL). No instales copias que te pasen por otros medios.
