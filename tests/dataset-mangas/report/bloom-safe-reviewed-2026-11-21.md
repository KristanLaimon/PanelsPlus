# Bloom Into You 8 — revisión Safe del 21-11-2026

## Alcance y decisiones del usuario

Libro `Bloom_Into_You_Vol_8`, algoritmo `safe`. Feedback exportado a las
17:53:10 UTC, reporte `3e556ac1bed03f6ffba7a5f8a9e35ac8c53ea594e3e6221b82c5c28c1a10d51d`.
El feedback ya identifica manga, algoritmo, página, elección, observaciones y cajas.
No se necesita pedir esa identidad de nuevo.

El usuario revisó las 36 páginas que diferían del mapping y guardó las decisiones.
Después corrigió expresamente la página 158: conservar **Después**, no Mapping
original. Se actualizó esa página y la revisión persistida, con respaldo del mapping.
También aclaró: Safe debe ignorar conexiones causadas solo por sombreado gris y
preservar las uniones reales hechas por bordes, dibujo o globos.

Las decisiones finales son 7 Mapping original, 4 Antes y 25 Después. Los mappings
están en `dataset/Bloom_Into_You_Vol_8/panels_safe.json`. La reducción del total a
**684 paneles** procede de las decisiones del usuario, no de recalcar automáticamente
las anotaciones para igualar el detector.

## Cambio general del detector

Solo cambia el runtime de Safe, `src/_safecomponentdetector.lua`. No hay condiciones
por título, número de página, ruta, hash, tamaño particular de la imagen ni cajas
esperadas. Los ejemplos de Bloom aparecen exclusivamente en datos y pruebas.

- Conserva componentes conectados y frames envolventes completos.
- Usa evidencia de alto contraste para proponer separaciones de sombreado gris,
  con cobertura, disposición conservadora y protección de conexiones oscuras.
- Recupera bandas completas de frames sin recortar por separado el resto de una
  ilustración flotante. La dirección de lectura decide qué lado es el inicial.
- Evita tratar ventanas y cajas de texto pequeñas como paneles cuando la mayoría
  de la tinta de la ilustración queda fuera de esas pequeñas cajas.
- Prefiere la página completa cuando los candidatos carecen de evidencia de frame.
- Mantiene los guardas de cobertura y límite de paneles y el orden propio de Safe.

Los primeros prototipos también separaban agrupaciones aprobadas en 45, 76 y 160:
se descartaron esas políticas demasiado permisivas. La evaluación de todo Bloom
reveló dos errores nuevos, 25 y 74; la protección de frames envolventes y la
exigencia de evidencia independiente cuando falta el componente inicial los evitaron.
Una prueba sintética adicional detectó la agrupación incorrecta de tres paneles
pequeños reales; falló antes y pasó después del guarda de tinta fuera de candidatos.

## Resultados del libro completo

Evaluador de producción sin cambios: matching IoU >= 0.50 o tolerancia de bordes
35 px. No significa que cada coordenada sea idéntica al mapping manual.

| Métrica Safe | Resultado |
|---|---:|
| Páginas evaluadas | 213 |
| Páginas con todos los paneles coincidentes y orden correcto | 213 |
| Paneles esperados / devueltos / coincidentes | 684 / 684 / 684 |
| Precisión / recall / F1 | 100% / 100% / 100% |
| Orden exacto por página / orden relativo por pares | 100% / 100% |
| IoU medio | 0.9802683434 |

Se estableció únicamente el baseline Safe de este libro después de la revisión
manual. `Benchmark.establishBaseline` archiva el anterior por cambio de anotaciones.
Se comprobó por igualdad profunda que `smart_full_volume` y los registros ajenos
no cambiaron. El control Smart de las 213 páginas sigue pasando: F1 95.78%.

## Comprobación de generalidad

Comparación del Safe anterior a esta tarea con el nuevo en otros cinco volúmenes,
**926 páginas**. No se escribieron mappings ni baselines de esos libros.

| Libro | Tipo | F1 anterior | F1 nuevo | Páginas completas correctas antes / ahora | Páginas antes correctas que dejaron de serlo |
|---|---|---:|---:|---:|---:|
| Chainsmoker Cat 1 | manga | 83.92% | 85.79% | 108 / 116 | 0 |
| Nagatoro 1 | manga | 96.25% | 96.33% | 139 / 139 | 0 |
| Komi 1 | manga | 95.33% | 95.61% | 152 / 153 | 0 |
| Kobayashi 2 | manga | 93.21% | 93.57% | 105 / 105 | 0 |
| Scott Pilgrim 5 | comic | 96.59% | 97.11% | 193 / 195 | 0 |

Esto no certifica todas las anotaciones de esos libros ni todos los mangas futuros.
Sus fallos preexistentes siguen pendientes de la revisión por libro del usuario.

## Validación y estado

Base Git `6ca8775a0816c20a0ca25cede56a4903d0d40fb6`, rama `main-nightly`, cambios
sin commit. Se conservaron los cambios staged del usuario. El Safe previo a esta
tarea tenía SHA-256 `720ad988f24c2bf563a7f652ecc2a0dc261c6cb10ef3383e7aa1f82f585234d2`.
No se modificaron `_smartcomponentdetector.lua`, `_componentpipeline.lua` ni
`_smartgeometry.lua`.

Comandos desde la raíz:

```sh
lua tests/run_tests.lua tests/componentdetector_spec.lua tests/panelcollector_spec.lua tests/embedded_image_spec.lua tests/geometry_spec.lua
PANELSPLUS_TEST_ALGORITHM=safe PANELSPLUS_TEST_DATASET=Bloom_Into_You_Vol_8 lua tests/run_tests.lua tests/new_dataset_benchmark_spec.lua tests/bloom_into_you_spec.lua
PANELSPLUS_TEST_ALGORITHM=smart PANELSPLUS_TEST_DATASET=Bloom_Into_You_Vol_8 lua tests/run_tests.lua tests/new_dataset_benchmark_spec.lua
luacheck src/_safecomponentdetector.lua tests/componentdetector_spec.lua tests/bloom_into_you_spec.lua tools/panels_revision/revision/diagnose.lua
```

Resultados: **65** pruebas unitarias, **8** pruebas Safe/dataset y **2** de control
Smart pasan; lint de cuatro archivos sin advertencias ni errores. Se probaron
conexiones grises/oscuras y puente oscuro de un píxel en manga y comic. La protección de conexiones oscuras también se verifica al recuperar bandas
junto a ilustraciones flotantes; los bordes deliberadamente compartidos por los
crops no cuentan como evidencia de una conexión nueva. La prueba
del libro cubre las 36 decisiones revisadas y los guardas de las páginas 25 y 74.
Loader, detectores y evaluador son reales; las APIs de KOReader/FFI usan los mocks
habituales de `tests.helper`. Falta validación visual en KOReader/dispositivo. No
se repitió la suite completa de OCR, Python ni compatibilidad entre plugins.

Se actualizó solo el grupo persistido `safe::Bloom_Into_You_Vol_8` del revisor:
**213 páginas, cero diferencias**. Se conservaron los otros grupos Safe y el
snapshot Smart byte por byte. El CLI `diagnose.lua` acepta ahora un segundo
argumento opcional con el título del libro para generar diagnósticos acotados.
Reiniciar `./start-reviewer` y recargar el navegador carga ese resultado sin rescan.
Las revisiones históricas pueden aparecer como antiguas por el nuevo snapshot;
no hay que volver a guardarlas sobre el mapping ya corregido.
