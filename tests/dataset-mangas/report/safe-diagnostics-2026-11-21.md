# Diagnóstico de Safe — 2026-11-21

## Revisión interactiva

Ejecuta `bun tools/panels_revision/revision.ts` desde la raíz y abre http://127.0.0.1:3210. Permite notas, antes/después, rectángulos propios, guardado del dataset con respaldo y exportación del feedback. También genera nuevos diagnósticos al ejecutar los tests de paneles.

Páginas según page_index del dataset (base 1); el nombre del archivo puede usar otra numeración. Esperados: panels_safe.json. Devueltos: Safe actual. Antes: código de HEAD previo al cambio. Evaluación estándar: IoU ≥0.50 o tolerancia de bordes de 35 px. La secuencia expresa qué panel esperado corresponde a cada panel devuelto; ? significa sin coincidencia. Una diferencia no determina por sí sola si el mapping o el detector es incorrecto.

Las coordenadas JSON son [x, y, ancho, alto] en píxeles nativos. Los paneles se numeran desde 1 en orden de lectura. No se modificaron mappings ni baselines.

| Manga | Páginas evaluadas | Con diferencias | Nuevas diferencias | Menos coincidencias que antes |
|---|---:|---:|---:|---:|
| Bloom_Into_You_Vol_8 | 213 | 36 | 11 | 4 |
| Chainsmoker_Cat_Vol_1 | 214 | 106 | 35 | 29 |
| Don't_Bully_Me_Nagatoro_Vol_1 | 161 | 22 | 5 | 6 |
| Komi_Can't_Communicate_Vol_1 | 190 | 38 | 17 | 4 |
| Miss_Kobayashi's_Dragon_Maid_Vol_2 | 143 | 38 | 12 | 5 |
| Scott_Pilgrim_Vol_5 | 218 | 25 | 8 | 0 |

Detalle visual: [safe-diagnostics-2026-11-21.html](safe-diagnostics-2026-11-21.html). Datos completos: [safe-diagnostics-2026-11-21.json](safe-diagnostics-2026-11-21.json).

## Bloom_Into_You_Vol_8

| Página | Imagen | Esperados | Devueltos | Antes | Secuencia actual | Tipo | Comparación |
|---:|---|---:|---:|---:|---|---|---|
| 6 | [05.png](<../dataset/Bloom_Into_You_Vol_8/05.png>) | 3 | 8 | 5 | ?, ?, ?, ?, ?, ?, 2, 3 | Más paneles | Ya difería antes |
| 16 | [15.png](<../dataset/Bloom_Into_You_Vol_8/15.png>) | 3 | 2 | 2 | 1, 3 | Menos paneles | Ya difería antes |
| 30 | [29.png](<../dataset/Bloom_Into_You_Vol_8/29.png>) | 3 | 2 | 3 | 2, 3 | Menos paneles | Nueva diferencia |
| 34 | [33.png](<../dataset/Bloom_Into_You_Vol_8/33.png>) | 5 | 1 | 5 | 3 | Menos paneles | Nueva diferencia |
| 36 | [35.png](<../dataset/Bloom_Into_You_Vol_8/35.png>) | 2 | 1 | 1 | 1 | Menos paneles | Ya difería antes |
| 45 | [44.png](<../dataset/Bloom_Into_You_Vol_8/44.png>) | 4 | 2 | 4 | 1, 4 | Menos paneles | Nueva diferencia |
| 67 | [66.png](<../dataset/Bloom_Into_You_Vol_8/66.png>) | 3 | 2 | 2 | 1, 2 | Menos paneles | Ya difería antes |
| 69 | [68.png](<../dataset/Bloom_Into_You_Vol_8/68.png>) | 1 | 1 | 1 | ? | Página completa (fallback) | Ya difería antes |
| 73 | [72.png](<../dataset/Bloom_Into_You_Vol_8/72.png>) | 5 | 3 | 5 | 1, 2, 3 | Menos paneles | Nueva diferencia |
| 76 | [75.png](<../dataset/Bloom_Into_You_Vol_8/75.png>) | 6 | 4 | 6 | 1, 2, 3, 4 | Menos paneles | Nueva diferencia |
| 88 | [87.png](<../dataset/Bloom_Into_You_Vol_8/87.png>) | 4 | 3 | 3 | 1, 2, 3 | Menos paneles | Ya difería antes |
| 94 | [93.png](<../dataset/Bloom_Into_You_Vol_8/93.png>) | 5 | 4 | 4 | 2, 3, 4, 5 | Menos paneles | Ya difería antes |
| 96 | [95.png](<../dataset/Bloom_Into_You_Vol_8/95.png>) | 3 | 2 | 2 | 1, 3 | Menos paneles | Ya difería antes |
| 112 | [111.png](<../dataset/Bloom_Into_You_Vol_8/111.png>) | 5 | 1 | 5 | ? | Página completa (fallback) | Nueva diferencia |
| 116 | [115.png](<../dataset/Bloom_Into_You_Vol_8/115.png>) | 2 | 1 | 1 | 1 | Menos paneles | Ya difería antes |
| 119 | [118.png](<../dataset/Bloom_Into_You_Vol_8/118.png>) | 5 | 2 | 4 | 1, ? | Menos paneles | Menos coincidencias que antes |
| 121 | [120.png](<../dataset/Bloom_Into_You_Vol_8/120.png>) | 3 | 1 | 3 | ? | Menos paneles | Nueva diferencia |
| 122 | [121.png](<../dataset/Bloom_Into_You_Vol_8/121.png>) | 1 | 2 | 5 | ?, ? | Más paneles | Ya difería antes |
| 127 | [126.png](<../dataset/Bloom_Into_You_Vol_8/126.png>) | 5 | 3 | 5 | 1, 2, ? | Menos paneles | Menos coincidencias que antes |
| 149 | [148.png](<../dataset/Bloom_Into_You_Vol_8/148.png>) | 5 | 4 | 5 | 1, 2, 3, 5 | Menos paneles | Nueva diferencia |
| 158 | [157.png](<../dataset/Bloom_Into_You_Vol_8/157.png>) | 5 | 5 | 5 | 1, 5, 2, 3, 4 | Orden distinto | Ya difería antes |
| 160 | [159.png](<../dataset/Bloom_Into_You_Vol_8/159.png>) | 5 | 2 | 5 | ?, 5 | Menos paneles | Nueva diferencia |
| 161 | [160.png](<../dataset/Bloom_Into_You_Vol_8/160.png>) | 2 | 1 | 2 | 1 | Página completa (fallback) | Nueva diferencia |
| 162 | [161.png](<../dataset/Bloom_Into_You_Vol_8/161.png>) | 5 | 1 | 5 | ? | Menos paneles | Menos coincidencias que antes |
| 163 | [162.png](<../dataset/Bloom_Into_You_Vol_8/162.png>) | 4 | 2 | 3 | ?, 3 | Menos paneles | Menos coincidencias que antes |
| 164 | [163.png](<../dataset/Bloom_Into_You_Vol_8/163.png>) | 2 | 1 | 1 | 2 | Menos paneles | Ya difería antes |
| 165 | [164.png](<../dataset/Bloom_Into_You_Vol_8/164.png>) | 1 | 2 | 3 | ?, 1 | Más paneles | Ya difería antes |
| 170 | [169.png](<../dataset/Bloom_Into_You_Vol_8/169.png>) | 1 | 1 | 1 | ? | Página completa (fallback) | Ya difería antes |
| 183 | [182.png](<../dataset/Bloom_Into_You_Vol_8/182.png>) | 3 | 1 | 3 | 1 | Menos paneles | Nueva diferencia |
| 196 | [195.png](<../dataset/Bloom_Into_You_Vol_8/195.png>) | 3 | 2 | 2 | 1, 3 | Menos paneles | Ya difería antes |
| 205 | [204.png](<../dataset/Bloom_Into_You_Vol_8/204.png>) | 3 | 3 | 3 | ?, 2, 3 | Cajas distintas | Ya difería antes |
| 208 | [207.png](<../dataset/Bloom_Into_You_Vol_8/207.png>) | 5 | 3 | 3 | 1, 2, 5 | Menos paneles | Ya difería antes |
| 209 | [208.png](<../dataset/Bloom_Into_You_Vol_8/208.png>) | 5 | 3 | 3 | 1, 3, 5 | Menos paneles | Ya difería antes |
| 210 | [209.png](<../dataset/Bloom_Into_You_Vol_8/209.png>) | 2 | 1 | 1 | 2 | Página completa (fallback) | Ya difería antes |
| 212 | [211.png](<../dataset/Bloom_Into_You_Vol_8/211.png>) | 1 | 2 | 2 | 1, ? | Más paneles | Ya difería antes |
| 213 | [212.png](<../dataset/Bloom_Into_You_Vol_8/212.png>) | 1 | 3 | 2 | ?, ?, 1 | Más paneles | Ya difería antes |

## Chainsmoker_Cat_Vol_1

| Página | Imagen | Esperados | Devueltos | Antes | Secuencia actual | Tipo | Comparación |
|---:|---|---:|---:|---:|---|---|---|
| 2 | [01.png](<../dataset/Chainsmoker_Cat_Vol_1/01.png>) | 7 | 3 | 5 | 2, 5, 7 | Menos paneles | Menos coincidencias que antes |
| 3 | [02.png](<../dataset/Chainsmoker_Cat_Vol_1/02.png>) | 4 | 3 | 3 | 1, 2, 3 | Menos paneles | Ya difería antes |
| 4 | [03.png](<../dataset/Chainsmoker_Cat_Vol_1/03.png>) | 5 | 3 | 5 | 1, 4, 5 | Menos paneles | Nueva diferencia |
| 5 | [04.png](<../dataset/Chainsmoker_Cat_Vol_1/04.png>) | 5 | 2 | 1 | 2, 5 | Menos paneles | Ya difería antes |
| 6 | [05.png](<../dataset/Chainsmoker_Cat_Vol_1/05.png>) | 4 | 3 | 3 | 2, 3, 4 | Menos paneles | Ya difería antes |
| 7 | [06.png](<../dataset/Chainsmoker_Cat_Vol_1/06.png>) | 3 | 4 | 4 | 1, ?, ?, 3 | Más paneles | Ya difería antes |
| 8 | [07.png](<../dataset/Chainsmoker_Cat_Vol_1/07.png>) | 7 | 5 | 6 | 2, 4, 6, 7, 5 | Menos paneles | Menos coincidencias que antes |
| 9 | [08.png](<../dataset/Chainsmoker_Cat_Vol_1/08.png>) | 7 | 6 | 6 | 1, 2, 3, 5, 6, 7 | Menos paneles | Ya difería antes |
| 11 | [10.png](<../dataset/Chainsmoker_Cat_Vol_1/10.png>) | 7 | 6 | 7 | 1, 2, 3, 4, 5, 7 | Menos paneles | Nueva diferencia |
| 12 | [11.png](<../dataset/Chainsmoker_Cat_Vol_1/11.png>) | 6 | 3 | 6 | 1, 2, 5 | Menos paneles | Nueva diferencia |
| 13 | [12.png](<../dataset/Chainsmoker_Cat_Vol_1/12.png>) | 3 | 1 | 3 | 1 | Menos paneles | Nueva diferencia |
| 17 | [16.png](<../dataset/Chainsmoker_Cat_Vol_1/16.png>) | 5 | 3 | 5 | 1, 2, ? | Menos paneles | Nueva diferencia |
| 21 | [20.png](<../dataset/Chainsmoker_Cat_Vol_1/20.png>) | 7 | 6 | 6 | 1, 2, 4, 5, 6, 7 | Menos paneles | Ya difería antes |
| 25 | [24.png](<../dataset/Chainsmoker_Cat_Vol_1/24.png>) | 3 | 1 | 4 | 1 | Página completa (fallback) | Ya difería antes |
| 26 | [25.png](<../dataset/Chainsmoker_Cat_Vol_1/25.png>) | 6 | 1 | 7 | ? | Página completa (fallback) | Menos coincidencias que antes |
| 27 | [26.png](<../dataset/Chainsmoker_Cat_Vol_1/26.png>) | 6 | 5 | 6 | ?, 4, 5, ?, 6 | Menos paneles | Menos coincidencias que antes |
| 30 | [29.png](<../dataset/Chainsmoker_Cat_Vol_1/29.png>) | 1 | 2 | 1 | 1, ? | Más paneles | Nueva diferencia |
| 33 | [32.png](<../dataset/Chainsmoker_Cat_Vol_1/32.png>) | 7 | 6 | 5 | 3, 4, ?, ?, 5, 7 | Menos paneles | Menos coincidencias que antes |
| 34 | [33.png](<../dataset/Chainsmoker_Cat_Vol_1/33.png>) | 8 | 5 | 8 | 1, 2, 3, 5, ? | Menos paneles | Menos coincidencias que antes |
| 35 | [34.png](<../dataset/Chainsmoker_Cat_Vol_1/34.png>) | 8 | 4 | 7 | 3, 4, 5, ? | Menos paneles | Menos coincidencias que antes |
| 36 | [35.png](<../dataset/Chainsmoker_Cat_Vol_1/35.png>) | 4 | 3 | 3 | 1, 2, 4 | Menos paneles | Ya difería antes |
| 38 | [37.png](<../dataset/Chainsmoker_Cat_Vol_1/37.png>) | 5 | 6 | 6 | 1, ?, 2, 3, 4, 5 | Más paneles | Ya difería antes |
| 39 | [38.png](<../dataset/Chainsmoker_Cat_Vol_1/38.png>) | 6 | 5 | 7 | 2, 3, 4, 5, 6 | Menos paneles | Menos coincidencias que antes |
| 41 | [40.png](<../dataset/Chainsmoker_Cat_Vol_1/40.png>) | 8 | 4 | 8 | ?, 6, 7, 8 | Menos paneles | Nueva diferencia |
| 42 | [41.png](<../dataset/Chainsmoker_Cat_Vol_1/41.png>) | 5 | 5 | 4 | 2, 1, 3, 4, 5 | Orden distinto | Ya difería antes |
| 43 | [42.png](<../dataset/Chainsmoker_Cat_Vol_1/42.png>) | 4 | 2 | 4 | ?, 4 | Menos paneles | Nueva diferencia |
| 46 | [45.png](<../dataset/Chainsmoker_Cat_Vol_1/45.png>) | 6 | 1 | 6 | ? | Menos paneles | Menos coincidencias que antes |
| 47 | [46.png](<../dataset/Chainsmoker_Cat_Vol_1/46.png>) | 7 | 4 | 7 | 1, 3, 4, ? | Menos paneles | Nueva diferencia |
| 48 | [47.png](<../dataset/Chainsmoker_Cat_Vol_1/47.png>) | 7 | 10 | 7 | 1, 2, 3, ?, 4, 6, ?, 5, ?, 7 | Más paneles | Ya difería antes |
| 50 | [49.png](<../dataset/Chainsmoker_Cat_Vol_1/49.png>) | 9 | 6 | 7 | 1, 2, 3, ?, 7, 9 | Menos paneles | Menos coincidencias que antes |
| 51 | [50.png](<../dataset/Chainsmoker_Cat_Vol_1/50.png>) | 6 | 5 | 5 | 1, 2, 4, 5, 6 | Menos paneles | Ya difería antes |
| 55 | [54.png](<../dataset/Chainsmoker_Cat_Vol_1/54.png>) | 7 | 7 | 7 | 1, ?, 3, 4, 5, 6, 7 | Cajas distintas | Ya difería antes |
| 58 | [57.png](<../dataset/Chainsmoker_Cat_Vol_1/57.png>) | 5 | 4 | 5 | 1, 2, 3, 4 | Menos paneles | Nueva diferencia |
| 59 | [58.png](<../dataset/Chainsmoker_Cat_Vol_1/58.png>) | 5 | 4 | 5 | 2, 3, 4, 5 | Menos paneles | Ya difería antes |
| 63 | [62.png](<../dataset/Chainsmoker_Cat_Vol_1/62.png>) | 5 | 4 | 6 | 1, 3, 4, 5 | Menos paneles | Menos coincidencias que antes |
| 64 | [63.png](<../dataset/Chainsmoker_Cat_Vol_1/63.png>) | 3 | 2 | 2 | 2, 3 | Menos paneles | Ya difería antes |
| 65 | [64.png](<../dataset/Chainsmoker_Cat_Vol_1/64.png>) | 7 | 6 | 7 | 1, 3, 4, 5, 6, 7 | Menos paneles | Nueva diferencia |
| 66 | [65.png](<../dataset/Chainsmoker_Cat_Vol_1/65.png>) | 5 | 4 | 6 | ?, 4, ?, 5 | Menos paneles | Menos coincidencias que antes |
| 67 | [66.png](<../dataset/Chainsmoker_Cat_Vol_1/66.png>) | 7 | 5 | 7 | 1, 2, 3, 4, ? | Menos paneles | Nueva diferencia |
| 69 | [68.png](<../dataset/Chainsmoker_Cat_Vol_1/68.png>) | 7 | 6 | 6 | 1, 3, 4, 5, 6, 7 | Menos paneles | Ya difería antes |
| 71 | [70.png](<../dataset/Chainsmoker_Cat_Vol_1/70.png>) | 5 | 1 | 4 | 3 | Menos paneles | Menos coincidencias que antes |
| 72 | [71.png](<../dataset/Chainsmoker_Cat_Vol_1/71.png>) | 5 | 5 | 6 | 2, 3, 4, ?, ? | Cajas distintas | Menos coincidencias que antes |
| 73 | [72.png](<../dataset/Chainsmoker_Cat_Vol_1/72.png>) | 1 | 5 | 1 | 1, ?, ?, ?, ? | Más paneles | Nueva diferencia |
| 74 | [73.png](<../dataset/Chainsmoker_Cat_Vol_1/73.png>) | 6 | 2 | 6 | ?, 4 | Menos paneles | Nueva diferencia |
| 79 | [78.png](<../dataset/Chainsmoker_Cat_Vol_1/78.png>) | 1 | 2 | 2 | ?, ? | Más paneles | Ya difería antes |
| 81 | [80.png](<../dataset/Chainsmoker_Cat_Vol_1/80.png>) | 7 | 6 | 6 | 1, ?, ?, 5, 6, 7 | Menos paneles | Ya difería antes |
| 82 | [81.png](<../dataset/Chainsmoker_Cat_Vol_1/81.png>) | 8 | 7 | 7 | 1, 2, 3, 4, 5, 7, 8 | Menos paneles | Ya difería antes |
| 83 | [82.png](<../dataset/Chainsmoker_Cat_Vol_1/82.png>) | 7 | 4 | 6 | ?, 4, 6, 7 | Menos paneles | Menos coincidencias que antes |
| 84 | [83.png](<../dataset/Chainsmoker_Cat_Vol_1/83.png>) | 5 | 4 | 5 | 1, 2, 4, 5 | Menos paneles | Nueva diferencia |
| 85 | [84.png](<../dataset/Chainsmoker_Cat_Vol_1/84.png>) | 3 | 5 | 4 | 1, 2, ?, ?, 3 | Más paneles | Ya difería antes |
| 86 | [85.png](<../dataset/Chainsmoker_Cat_Vol_1/85.png>) | 1 | 1 | 1 | ? | Página completa (fallback) | Ya difería antes |
| 88 | [87.png](<../dataset/Chainsmoker_Cat_Vol_1/87.png>) | 8 | 9 | 9 | 1, 2, 3, 4, 5, 6, 7, 8, ? | Más paneles | Ya difería antes |
| 89 | [88.png](<../dataset/Chainsmoker_Cat_Vol_1/88.png>) | 1 | 2 | 1 | 1, ? | Más paneles | Nueva diferencia |
| 91 | [90.png](<../dataset/Chainsmoker_Cat_Vol_1/90.png>) | 9 | 10 | 10 | 1, 2, 3, 4, 5, ?, ?, 7, 8, 9 | Más paneles | Ya difería antes |
| 94 | [93.png](<../dataset/Chainsmoker_Cat_Vol_1/93.png>) | 1 | 1 | 1 | ? | Página completa (fallback) | Ya difería antes |
| 95 | [94.png](<../dataset/Chainsmoker_Cat_Vol_1/94.png>) | 5 | 1 | 1 | ? | Menos paneles | Ya difería antes |
| 96 | [95.png](<../dataset/Chainsmoker_Cat_Vol_1/95.png>) | 1 | 3 | 2 | ?, 1, ? | Más paneles | Ya difería antes |
| 99 | [98.png](<../dataset/Chainsmoker_Cat_Vol_1/98.png>) | 6 | 4 | 5 | 2, 3, 5, 6 | Menos paneles | Menos coincidencias que antes |
| 102 | [101.png](<../dataset/Chainsmoker_Cat_Vol_1/101.png>) | 8 | 7 | 7 | 1, 2, 3, 4, ?, 7, 8 | Menos paneles | Ya difería antes |
| 105 | [104.png](<../dataset/Chainsmoker_Cat_Vol_1/104.png>) | 7 | 6 | 7 | 1, 2, 3, 4, 5, 7 | Menos paneles | Nueva diferencia |
| 108 | [107.png](<../dataset/Chainsmoker_Cat_Vol_1/107.png>) | 6 | 6 | 5 | 1, ?, 2, 3, ?, 6 | Cajas distintas | Ya difería antes |
| 109 | [108.png](<../dataset/Chainsmoker_Cat_Vol_1/108.png>) | 4 | 3 | 5 | 1, 2, 4 | Menos paneles | Ya difería antes |
| 112 | [111.png](<../dataset/Chainsmoker_Cat_Vol_1/111.png>) | 7 | 4 | 7 | 1, 4, 5, 6 | Menos paneles | Nueva diferencia |
| 116 | [115.png](<../dataset/Chainsmoker_Cat_Vol_1/115.png>) | 6 | 7 | 8 | 1, 2, 3, ?, ?, 5, 6 | Más paneles | Ya difería antes |
| 117 | [116.png](<../dataset/Chainsmoker_Cat_Vol_1/116.png>) | 1 | 2 | 1 | 1, ? | Más paneles | Nueva diferencia |
| 122 | [121.png](<../dataset/Chainsmoker_Cat_Vol_1/121.png>) | 4 | 2 | 3 | 1, ? | Menos paneles | Menos coincidencias que antes |
| 124 | [123.png](<../dataset/Chainsmoker_Cat_Vol_1/123.png>) | 6 | 5 | 5 | 1, 2, 4, 5, 6 | Menos paneles | Ya difería antes |
| 127 | [126.png](<../dataset/Chainsmoker_Cat_Vol_1/126.png>) | 6 | 3 | 4 | 3, 4, 6 | Menos paneles | Menos coincidencias que antes |
| 129 | [128.png](<../dataset/Chainsmoker_Cat_Vol_1/128.png>) | 6 | 2 | 6 | 2, ? | Menos paneles | Nueva diferencia |
| 131 | [130.png](<../dataset/Chainsmoker_Cat_Vol_1/130.png>) | 6 | 5 | 5 | 1, 2, 3, 4, 6 | Menos paneles | Ya difería antes |
| 132 | [131.png](<../dataset/Chainsmoker_Cat_Vol_1/131.png>) | 6 | 5 | 5 | 2, 3, 4, 5, 6 | Menos paneles | Ya difería antes |
| 136 | [135.png](<../dataset/Chainsmoker_Cat_Vol_1/135.png>) | 1 | 2 | 1 | 1, ? | Más paneles | Nueva diferencia |
| 140 | [139.png](<../dataset/Chainsmoker_Cat_Vol_1/139.png>) | 11 | 11 | 11 | 1, 2, 3, 4, 5, 6, 7, 8, 10, 9, 11 | Orden distinto | Ya difería antes |
| 142 | [141.png](<../dataset/Chainsmoker_Cat_Vol_1/141.png>) | 5 | 8 | 8 | ?, ?, ?, ?, 2, 3, 4, 5 | Más paneles | Ya difería antes |
| 143 | [142.png](<../dataset/Chainsmoker_Cat_Vol_1/142.png>) | 7 | 6 | 8 | 1, 2, 3, 4, 5, 7 | Menos paneles | Menos coincidencias que antes |
| 145 | [144.png](<../dataset/Chainsmoker_Cat_Vol_1/144.png>) | 7 | 1 | 6 | ? | Menos paneles | Menos coincidencias que antes |
| 146 | [145.png](<../dataset/Chainsmoker_Cat_Vol_1/145.png>) | 7 | 5 | 7 | 3, 4, 5, 6, 7 | Menos paneles | Menos coincidencias que antes |
| 148 | [147.png](<../dataset/Chainsmoker_Cat_Vol_1/147.png>) | 7 | 6 | 7 | 1, 2, 3, 4, 6, 7 | Menos paneles | Ya difería antes |
| 150 | [149.png](<../dataset/Chainsmoker_Cat_Vol_1/149.png>) | 1 | 2 | 1 | 1, ? | Más paneles | Nueva diferencia |
| 155 | [154.png](<../dataset/Chainsmoker_Cat_Vol_1/154.png>) | 3 | 2 | 2 | 1, 2 | Menos paneles | Ya difería antes |
| 156 | [155.png](<../dataset/Chainsmoker_Cat_Vol_1/155.png>) | 6 | 5 | 6 | 1, 2, 3, 5, 6 | Menos paneles | Nueva diferencia |
| 157 | [156.png](<../dataset/Chainsmoker_Cat_Vol_1/156.png>) | 8 | 7 | 7 | 1, 2, 3, 4, 5, 6, 8 | Menos paneles | Ya difería antes |
| 159 | [158.png](<../dataset/Chainsmoker_Cat_Vol_1/158.png>) | 3 | 1 | 3 | 1 | Página completa (fallback) | Nueva diferencia |
| 160 | [159.png](<../dataset/Chainsmoker_Cat_Vol_1/159.png>) | 6 | 5 | 6 | 1, 2, 4, 5, 6 | Menos paneles | Nueva diferencia |
| 161 | [160.png](<../dataset/Chainsmoker_Cat_Vol_1/160.png>) | 5 | 4 | 5 | 2, 3, 4, 5 | Menos paneles | Nueva diferencia |
| 162 | [161.png](<../dataset/Chainsmoker_Cat_Vol_1/161.png>) | 3 | 1 | 3 | ? | Página completa (fallback) | Nueva diferencia |
| 163 | [162.png](<../dataset/Chainsmoker_Cat_Vol_1/162.png>) | 1 | 2 | 1 | 1, ? | Más paneles | Nueva diferencia |
| 167 | [166.png](<../dataset/Chainsmoker_Cat_Vol_1/166.png>) | 4 | 4 | 5 | 1, 3, 2, 4 | Orden distinto | Ya difería antes |
| 170 | [169.png](<../dataset/Chainsmoker_Cat_Vol_1/169.png>) | 8 | 6 | 7 | 1, 3, 4, 6, 7, 8 | Menos paneles | Menos coincidencias que antes |
| 171 | [170.png](<../dataset/Chainsmoker_Cat_Vol_1/170.png>) | 7 | 6 | 7 | 1, 2, 3, 4, 5, 6 | Menos paneles | Nueva diferencia |
| 180 | [179.png](<../dataset/Chainsmoker_Cat_Vol_1/179.png>) | 7 | 4 | 7 | 2, ?, 6, 7 | Menos paneles | Menos coincidencias que antes |
| 183 | [182.png](<../dataset/Chainsmoker_Cat_Vol_1/182.png>) | 6 | 5 | 6 | 1, 2, 3, 4, 6 | Menos paneles | Nueva diferencia |
| 187 | [186.png](<../dataset/Chainsmoker_Cat_Vol_1/186.png>) | 5 | 4 | 5 | 1, 3, 4, 5 | Menos paneles | Nueva diferencia |
| 190 | [189.png](<../dataset/Chainsmoker_Cat_Vol_1/189.png>) | 1 | 2 | 1 | 1, ? | Más paneles | Nueva diferencia |
| 192 | [191.png](<../dataset/Chainsmoker_Cat_Vol_1/191.png>) | 7 | 4 | 6 | ?, 4, 6, 7 | Menos paneles | Menos coincidencias que antes |
| 193 | [192.png](<../dataset/Chainsmoker_Cat_Vol_1/192.png>) | 8 | 7 | 8 | 1, 2, 3, 4, 5, 6, 8 | Menos paneles | Nueva diferencia |
| 194 | [193.png](<../dataset/Chainsmoker_Cat_Vol_1/193.png>) | 9 | 7 | 6 | ?, 3, 4, 5, 7, 8, 9 | Menos paneles | Ya difería antes |
| 195 | [194.png](<../dataset/Chainsmoker_Cat_Vol_1/194.png>) | 6 | 2 | 5 | ?, 6 | Menos paneles | Menos coincidencias que antes |
| 200 | [199.png](<../dataset/Chainsmoker_Cat_Vol_1/199.png>) | 4 | 1 | 3 | ? | Menos paneles | Menos coincidencias que antes |
| 201 | [200.png](<../dataset/Chainsmoker_Cat_Vol_1/200.png>) | 7 | 4 | 7 | 1, 2, ?, 7 | Menos paneles | Menos coincidencias que antes |
| 204 | [203.png](<../dataset/Chainsmoker_Cat_Vol_1/203.png>) | 7 | 1 | 7 | ? | Página completa (fallback) | Nueva diferencia |
| 205 | [204.png](<../dataset/Chainsmoker_Cat_Vol_1/204.png>) | 7 | 6 | 7 | 1, 2, 3, 5, 6, 7 | Menos paneles | Ya difería antes |
| 208 | [207.png](<../dataset/Chainsmoker_Cat_Vol_1/207.png>) | 4 | 1 | 3 | ? | Menos paneles | Menos coincidencias que antes |
| 209 | [208.png](<../dataset/Chainsmoker_Cat_Vol_1/208.png>) | 7 | 4 | 7 | 1, 2, ?, 7 | Menos paneles | Menos coincidencias que antes |
| 212 | [211.png](<../dataset/Chainsmoker_Cat_Vol_1/211.png>) | 7 | 1 | 7 | ? | Página completa (fallback) | Nueva diferencia |
| 213 | [212.png](<../dataset/Chainsmoker_Cat_Vol_1/212.png>) | 7 | 6 | 7 | 1, 2, 3, 5, 6, 7 | Menos paneles | Ya difería antes |

## Don't_Bully_Me_Nagatoro_Vol_1

| Página | Imagen | Esperados | Devueltos | Antes | Secuencia actual | Tipo | Comparación |
|---:|---|---:|---:|---:|---|---|---|
| 4 | [03.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/03.png>) | 3 | 1 | 5 | 3 | Página completa (fallback) | Menos coincidencias que antes |
| 7 | [06.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/06.png>) | 5 | 6 | 5 | 1, ?, 2, 3, 4, 5 | Más paneles | Nueva diferencia |
| 27 | [26.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/26.png>) | 2 | 3 | 3 | ?, 1, 2 | Más paneles | Ya difería antes |
| 37 | [36.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/36.png>) | 5 | 5 | 5 | 5, 1, 2, 3, 4 | Orden distinto | Ya difería antes |
| 40 | [39.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/39.png>) | 5 | 1 | 5 | ? | Menos paneles | Nueva diferencia |
| 49 | [48.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/48.png>) | 4 | 3 | 3 | 1, 2, 3 | Menos paneles | Ya difería antes |
| 55 | [54.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/54.png>) | 4 | 1 | 5 | 4 | Página completa (fallback) | Menos coincidencias que antes |
| 75 | [74.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/74.png>) | 4 | 2 | 4 | 1, 4 | Menos paneles | Menos coincidencias que antes |
| 113 | [112.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/112.png>) | 3 | 1 | 1 | 3 | Menos paneles | Ya difería antes |
| 116 | [115.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/115.png>) | 3 | 2 | 3 | 1, ? | Menos paneles | Nueva diferencia |
| 117 | [116.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/116.png>) | 5 | 4 | 4 | 1, 2, 3, 4 | Menos paneles | Ya difería antes |
| 120 | [119.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/119.png>) | 3 | 1 | 3 | 1 | Menos paneles | Nueva diferencia |
| 126 | [125.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/125.png>) | 3 | 1 | 3 | 3 | Página completa (fallback) | Nueva diferencia |
| 128 | [127.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/127.png>) | 7 | 1 | 3 | ? | Menos paneles | Ya difería antes |
| 129 | [128.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/128.png>) | 5 | 1 | 5 | ? | Página completa (fallback) | Menos coincidencias que antes |
| 132 | [131.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/131.png>) | 7 | 8 | 8 | 1, 2, 3, 4, 5, 6, ?, 7 | Más paneles | Ya difería antes |
| 145 | [144.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/144.png>) | 4 | 3 | 4 | 1, 2, 3 | Menos paneles | Menos coincidencias que antes |
| 148 | [147.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/147.png>) | 8 | 7 | 8 | 1, 3, 4, 5, 6, 7, 8 | Menos paneles | Ya difería antes |
| 151 | [150.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/150.png>) | 5 | 4 | 5 | 1, 2, 3, 4 | Menos paneles | Ya difería antes |
| 152 | [151.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/151.png>) | 7 | 7 | 8 | 3, 1, 2, 4, 5, 6, 7 | Orden distinto | Ya difería antes |
| 155 | [154.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/154.png>) | 3 | 2 | 4 | 1, 3 | Menos paneles | Menos coincidencias que antes |
| 159 | [158.png](<../dataset/Don't_Bully_Me_Nagatoro_Vol_1/158.png>) | 4 | 3 | 3 | 1, 2, 3 | Menos paneles | Ya difería antes |

## Komi_Can't_Communicate_Vol_1

| Página | Imagen | Esperados | Devueltos | Antes | Secuencia actual | Tipo | Comparación |
|---:|---|---:|---:|---:|---|---|---|
| 3 | [02.png](<../dataset/Komi_Can't_Communicate_Vol_1/02.png>) | 1 | 1 | 1 | ? | Cajas distintas | Nueva diferencia |
| 15 | [14.png](<../dataset/Komi_Can't_Communicate_Vol_1/14.png>) | 8 | 9 | 8 | 1, 2, 3, 4, 5, 6, 7, ?, 8 | Más paneles | Nueva diferencia |
| 17 | [16.png](<../dataset/Komi_Can't_Communicate_Vol_1/16.png>) | 5 | 5 | 5 | 1, 2, 3, 4, ? | Cajas distintas | Nueva diferencia |
| 20 | [19.png](<../dataset/Komi_Can't_Communicate_Vol_1/19.png>) | 8 | 7 | 7 | 1, 2, 3, 4, 5, 6, 7 | Menos paneles | Ya difería antes |
| 22 | [21.png](<../dataset/Komi_Can't_Communicate_Vol_1/21.png>) | 4 | 1 | 3 | ? | Menos paneles | Menos coincidencias que antes |
| 24 | [23.png](<../dataset/Komi_Can't_Communicate_Vol_1/23.png>) | 4 | 2 | 4 | 1, ? | Menos paneles | Nueva diferencia |
| 26 | [25.png](<../dataset/Komi_Can't_Communicate_Vol_1/25.png>) | 6 | 7 | 6 | 1, 2, 3, 4, 5, 6, ? | Más paneles | Nueva diferencia |
| 28 | [27.png](<../dataset/Komi_Can't_Communicate_Vol_1/27.png>) | 4 | 3 | 5 | 1, 2, 3 | Menos paneles | Ya difería antes |
| 32 | [31.png](<../dataset/Komi_Can't_Communicate_Vol_1/31.png>) | 6 | 7 | 6 | 1, 2, 3, 4, 5, 6, ? | Más paneles | Nueva diferencia |
| 33 | [32.png](<../dataset/Komi_Can't_Communicate_Vol_1/32.png>) | 10 | 9 | 7 | 1, 2, 3, 4, 5, 6, 7, 8, 9 | Menos paneles | Ya difería antes |
| 35 | [34.png](<../dataset/Komi_Can't_Communicate_Vol_1/34.png>) | 5 | 4 | 5 | 1, 2, 3, 4 | Menos paneles | Nueva diferencia |
| 48 | [47.png](<../dataset/Komi_Can't_Communicate_Vol_1/47.png>) | 5 | 4 | 5 | 1, 2, 3, 4 | Menos paneles | Nueva diferencia |
| 50 | [49.png](<../dataset/Komi_Can't_Communicate_Vol_1/49.png>) | 3 | 1 | 2 | 1 | Menos paneles | Menos coincidencias que antes |
| 57 | [56.png](<../dataset/Komi_Can't_Communicate_Vol_1/56.png>) | 5 | 4 | 4 | 1, 2, 3, 4 | Menos paneles | Ya difería antes |
| 58 | [57.png](<../dataset/Komi_Can't_Communicate_Vol_1/57.png>) | 6 | 5 | 4 | 1, 2, 3, 4, 5 | Menos paneles | Ya difería antes |
| 68 | [67.png](<../dataset/Komi_Can't_Communicate_Vol_1/67.png>) | 4 | 3 | 4 | 1, 2, 3 | Menos paneles | Nueva diferencia |
| 74 | [73.png](<../dataset/Komi_Can't_Communicate_Vol_1/73.png>) | 5 | 4 | 4 | 1, 2, 3, 4 | Menos paneles | Ya difería antes |
| 79 | [78.png](<../dataset/Komi_Can't_Communicate_Vol_1/78.png>) | 4 | 5 | 4 | 1, 2, 3, 4, ? | Más paneles | Nueva diferencia |
| 89 | [88.png](<../dataset/Komi_Can't_Communicate_Vol_1/88.png>) | 4 | 3 | 3 | 1, 2, 3 | Menos paneles | Ya difería antes |
| 90 | [89.png](<../dataset/Komi_Can't_Communicate_Vol_1/89.png>) | 2 | 1 | 1 | 1 | Menos paneles | Ya difería antes |
| 99 | [98.png](<../dataset/Komi_Can't_Communicate_Vol_1/98.png>) | 5 | 4 | 4 | 1, 2, 3, 4 | Menos paneles | Ya difería antes |
| 100 | [99.png](<../dataset/Komi_Can't_Communicate_Vol_1/99.png>) | 4 | 3 | 4 | 1, 2, 3 | Menos paneles | Nueva diferencia |
| 110 | [109.png](<../dataset/Komi_Can't_Communicate_Vol_1/109.png>) | 5 | 4 | 5 | 1, 2, 3, 4 | Menos paneles | Nueva diferencia |
| 111 | [110.png](<../dataset/Komi_Can't_Communicate_Vol_1/110.png>) | 6 | 5 | 5 | 1, 2, 3, 4, 5 | Menos paneles | Ya difería antes |
| 112 | [111.png](<../dataset/Komi_Can't_Communicate_Vol_1/111.png>) | 4 | 1 | 5 | ? | Menos paneles | Menos coincidencias que antes |
| 122 | [121.png](<../dataset/Komi_Can't_Communicate_Vol_1/121.png>) | 5 | 4 | 5 | 1, 2, 3, 4 | Menos paneles | Nueva diferencia |
| 123 | [122.png](<../dataset/Komi_Can't_Communicate_Vol_1/122.png>) | 5 | 1 | 1 | ? | Menos paneles | Ya difería antes |
| 124 | [123.png](<../dataset/Komi_Can't_Communicate_Vol_1/123.png>) | 4 | 1 | 4 | ? | Menos paneles | Nueva diferencia |
| 125 | [124.png](<../dataset/Komi_Can't_Communicate_Vol_1/124.png>) | 4 | 1 | 1 | ? | Menos paneles | Ya difería antes |
| 129 | [128.png](<../dataset/Komi_Can't_Communicate_Vol_1/128.png>) | 5 | 4 | 4 | 1, 2, 3, 4 | Menos paneles | Ya difería antes |
| 130 | [129.png](<../dataset/Komi_Can't_Communicate_Vol_1/129.png>) | 1 | 1 | 1 | ? | Página completa (fallback) | Ya difería antes |
| 137 | [136.png](<../dataset/Komi_Can't_Communicate_Vol_1/136.png>) | 5 | 4 | 5 | 1, 2, 3, 4 | Menos paneles | Nueva diferencia |
| 138 | [137.png](<../dataset/Komi_Can't_Communicate_Vol_1/137.png>) | 5 | 5 | 6 | ?, 1, 2, 3, 4 | Cajas distintas | Menos coincidencias que antes |
| 140 | [139.png](<../dataset/Komi_Can't_Communicate_Vol_1/139.png>) | 4 | 5 | 4 | 1, 2, 3, 4, ? | Más paneles | Nueva diferencia |
| 143 | [142.png](<../dataset/Komi_Can't_Communicate_Vol_1/142.png>) | 3 | 3 | 2 | 1, 2, ? | Cajas distintas | Ya difería antes |
| 177 | [176.png](<../dataset/Komi_Can't_Communicate_Vol_1/176.png>) | 5 | 6 | 5 | 1, 2, 3, 4, 5, ? | Más paneles | Nueva diferencia |
| 187 | [186.png](<../dataset/Komi_Can't_Communicate_Vol_1/186.png>) | 5 | 5 | 5 | ?, 2, 3, 4, 5 | Cajas distintas | Ya difería antes |
| 188 | [187.png](<../dataset/Komi_Can't_Communicate_Vol_1/187.png>) | 5 | 5 | 5 | ?, 2, 3, 4, 5 | Cajas distintas | Ya difería antes |

## Miss_Kobayashi's_Dragon_Maid_Vol_2

| Página | Imagen | Esperados | Devueltos | Antes | Secuencia actual | Tipo | Comparación |
|---:|---|---:|---:|---:|---|---|---|
| 4 | [03.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/03.png>) | 3 | 4 | 3 | ?, 1, 2, 3 | Más paneles | Nueva diferencia |
| 15 | [14.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/14.png>) | 2 | 3 | 3 | 1, 2, ? | Más paneles | Ya difería antes |
| 18 | [17.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/17.png>) | 5 | 4 | 4 | 1, 2, 4, 5 | Menos paneles | Ya difería antes |
| 20 | [19.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/19.png>) | 5 | 4 | 4 | 1, 4, 3, 5 | Menos paneles | Ya difería antes |
| 21 | [20.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/20.png>) | 5 | 4 | 4 | 1, 2, 3, 5 | Menos paneles | Ya difería antes |
| 23 | [22.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/22.png>) | 5 | 3 | 3 | 1, 2, 5 | Menos paneles | Ya difería antes |
| 27 | [26.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/26.png>) | 5 | 6 | 6 | 1, ?, 2, 3, 4, 5 | Más paneles | Ya difería antes |
| 28 | [27.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/27.png>) | 4 | 4 | 5 | 1, ?, 3, ? | Cajas distintas | Menos coincidencias que antes |
| 29 | [28.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/28.png>) | 6 | 5 | 4 | 2, 5, 6, ?, ? | Menos paneles | Ya difería antes |
| 43 | [42.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/42.png>) | 6 | 6 | 6 | 1, 2, 3, 4, 5, ? | Cajas distintas | Nueva diferencia |
| 52 | [51.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/51.png>) | 14 | 13 | 14 | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 | Menos paneles | Nueva diferencia |
| 53 | [52.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/52.png>) | 6 | 6 | 6 | 1, 2, ?, 4, 5, 6 | Cajas distintas | Nueva diferencia |
| 58 | [57.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/57.png>) | 5 | 5 | 4 | 1, ?, 2, 3, 5 | Cajas distintas | Ya difería antes |
| 59 | [58.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/58.png>) | 1 | 4 | 1 | ?, ?, ?, 1 | Más paneles | Nueva diferencia |
| 60 | [59.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/59.png>) | 5 | 5 | 4 | 1, 2, ?, 4, ? | Cajas distintas | Ya difería antes |
| 61 | [60.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/60.png>) | 7 | 6 | 6 | 1, 2, 3, 4, 6, 7 | Menos paneles | Ya difería antes |
| 62 | [61.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/61.png>) | 5 | 4 | 4 | 1, 2, 3, 5 | Menos paneles | Ya difería antes |
| 64 | [63.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/63.png>) | 5 | 3 | 3 | ?, 4, 5 | Menos paneles | Ya difería antes |
| 65 | [64.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/64.png>) | 4 | 3 | 3 | 1, 3, 4 | Menos paneles | Ya difería antes |
| 67 | [66.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/66.png>) | 5 | 3 | 5 | 2, 3, 5 | Menos paneles | Nueva diferencia |
| 72 | [71.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/71.png>) | 3 | 1 | 3 | 3 | Menos paneles | Nueva diferencia |
| 78 | [77.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/77.png>) | 8 | 4 | 8 | ?, 6, 7, 8 | Menos paneles | Nueva diferencia |
| 80 | [79.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/79.png>) | 6 | 5 | 5 | 1, 3, 4, 5, 6 | Menos paneles | Ya difería antes |
| 82 | [81.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/81.png>) | 4 | 4 | 4 | 1, 2, 3, ? | Cajas distintas | Nueva diferencia |
| 85 | [84.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/84.png>) | 4 | 3 | 3 | 1, 2, 4 | Menos paneles | Ya difería antes |
| 92 | [91.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/91.png>) | 5 | 5 | 5 | 2, 1, 3, 4, 5 | Orden distinto | Ya difería antes |
| 93 | [92.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/92.png>) | 7 | 4 | 4 | 1, 2, ?, 7 | Menos paneles | Ya difería antes |
| 96 | [95.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/95.png>) | 6 | 4 | 4 | 1, 2, 4, 6 | Menos paneles | Ya difería antes |
| 99 | [98.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/98.png>) | 6 | 6 | 6 | 1, 2, 3, 4, 6, 5 | Orden distinto | Ya difería antes |
| 104 | [103.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/103.png>) | 6 | 5 | 7 | 1, 2, 3, ?, 6 | Menos paneles | Menos coincidencias que antes |
| 110 | [109.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/109.png>) | 4 | 5 | 4 | 1, 2, 3, ?, ? | Más paneles | Nueva diferencia |
| 113 | [112.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/112.png>) | 2 | 1 | 3 | 2 | Menos paneles | Menos coincidencias que antes |
| 117 | [116.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/116.png>) | 3 | 1 | 2 | ? | Página completa (fallback) | Menos coincidencias que antes |
| 123 | [122.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/122.png>) | 4 | 5 | 4 | 1, 2, 3, ?, 4 | Más paneles | Nueva diferencia |
| 124 | [123.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/123.png>) | 4 | 4 | 4 | 1, 3, 4, 2 | Orden distinto | Ya difería antes |
| 138 | [137.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/137.png>) | 6 | 3 | 5 | ?, 5, 6 | Menos paneles | Menos coincidencias que antes |
| 139 | [138.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/138.png>) | 5 | 4 | 5 | 1, 2, 3, 4 | Menos paneles | Nueva diferencia |
| 142 | [141.png](<../dataset/Miss_Kobayashi's_Dragon_Maid_Vol_2/141.png>) | 1 | 2 | 2 | 1, ? | Más paneles | Ya difería antes |

## Scott_Pilgrim_Vol_5

| Página | Imagen | Esperados | Devueltos | Antes | Secuencia actual | Tipo | Comparación |
|---:|---|---:|---:|---:|---|---|---|
| 1 | [00.png](<../dataset/Scott_Pilgrim_Vol_5/00.png>) | 1 | 2 | 1 | ?, 1 | Más paneles | Nueva diferencia |
| 3 | [02.png](<../dataset/Scott_Pilgrim_Vol_5/02.png>) | 1 | 1 | 1 | ? | Página completa (fallback) | Ya difería antes |
| 4 | [03.png](<../dataset/Scott_Pilgrim_Vol_5/03.png>) | 1 | 3 | 1 | 1, ?, ? | Más paneles | Nueva diferencia |
| 7 | [06.png](<../dataset/Scott_Pilgrim_Vol_5/06.png>) | 4 | 3 | 3 | 1, 2, 3 | Menos paneles | Ya difería antes |
| 8 | [07.png](<../dataset/Scott_Pilgrim_Vol_5/07.png>) | 3 | 2 | 2 | 1, 2 | Menos paneles | Ya difería antes |
| 13 | [12.png](<../dataset/Scott_Pilgrim_Vol_5/12.png>) | 7 | 7 | 7 | 1, 2, 3, 5, 6, 7, 4 | Orden distinto | Ya difería antes |
| 15 | [14.png](<../dataset/Scott_Pilgrim_Vol_5/14.png>) | 4 | 4 | 4 | 1, 3, 2, 4 | Orden distinto | Ya difería antes |
| 88 | [87.png](<../dataset/Scott_Pilgrim_Vol_5/87.png>) | 2 | 1 | 1 | 1 | Menos paneles | Ya difería antes |
| 90 | [89.png](<../dataset/Scott_Pilgrim_Vol_5/89.png>) | 1 | 10 | 5 | ?, ?, ?, ?, ?, ?, ?, ?, ?, ? | Más paneles | Ya difería antes |
| 101 | [100.png](<../dataset/Scott_Pilgrim_Vol_5/100.png>) | 4 | 4 | 4 | 1, 3, 4, 2 | Orden distinto | Ya difería antes |
| 108 | [107.png](<../dataset/Scott_Pilgrim_Vol_5/107.png>) | 6 | 5 | 6 | 1, 2, 3, 4, 6 | Menos paneles | Nueva diferencia |
| 129 | [128.png](<../dataset/Scott_Pilgrim_Vol_5/128.png>) | 4 | 4 | 4 | 1, 3, 4, 2 | Orden distinto | Ya difería antes |
| 139 | [138.png](<../dataset/Scott_Pilgrim_Vol_5/138.png>) | 2 | 1 | 1 | 1 | Página completa (fallback) | Ya difería antes |
| 140 | [139.png](<../dataset/Scott_Pilgrim_Vol_5/139.png>) | 2 | 1 | 1 | ? | Página completa (fallback) | Ya difería antes |
| 146 | [145.png](<../dataset/Scott_Pilgrim_Vol_5/145.png>) | 2 | 1 | 1 | ? | Página completa (fallback) | Ya difería antes |
| 148 | [147.png](<../dataset/Scott_Pilgrim_Vol_5/147.png>) | 5 | 3 | 3 | ?, 4, 5 | Menos paneles | Ya difería antes |
| 175 | [174.png](<../dataset/Scott_Pilgrim_Vol_5/174.png>) | 2 | 1 | 1 | 1 | Menos paneles | Ya difería antes |
| 177 | [176.png](<../dataset/Scott_Pilgrim_Vol_5/176.png>) | 1 | 3 | 1 | ?, ?, 1 | Más paneles | Nueva diferencia |
| 198 | [197.png](<../dataset/Scott_Pilgrim_Vol_5/197.png>) | 1 | 6 | 6 | ?, ?, ?, ?, ?, ? | Más paneles | Ya difería antes |
| 199 | [198.png](<../dataset/Scott_Pilgrim_Vol_5/198.png>) | 5 | 7 | 7 | 1, ?, 2, 3, 4, ?, 5 | Más paneles | Ya difería antes |
| 201 | [200.png](<../dataset/Scott_Pilgrim_Vol_5/200.png>) | 1 | 2 | 1 | 1, ? | Más paneles | Nueva diferencia |
| 202 | [201.png](<../dataset/Scott_Pilgrim_Vol_5/201.png>) | 1 | 3 | 1 | 1, ?, ? | Más paneles | Nueva diferencia |
| 205 | [204.png](<../dataset/Scott_Pilgrim_Vol_5/204.png>) | 1 | 2 | 1 | ?, 1 | Más paneles | Nueva diferencia |
| 215 | [214.png](<../dataset/Scott_Pilgrim_Vol_5/214.png>) | 1 | 6 | 1 | ?, ?, ?, ?, ?, ? | Más paneles | Nueva diferencia |
| 216 | [215.png](<../dataset/Scott_Pilgrim_Vol_5/215.png>) | 1 | 3 | 3 | ?, ?, ? | Más paneles | Ya difería antes |
