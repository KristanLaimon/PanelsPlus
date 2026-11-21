# Chainsmoker Cat 1 · revisión Safe del 21-11-2026

Se verificaron las 69 decisiones de Chainsmoker Cat contra el reporte
`9203884382a954ba920951e848f5fa5a2ee7b2a70a20beddc9f8c5fba1e09015`,
la revisión persistida y las dimensiones de cada imagen. El mapping ya
reflejaba 46 decisiones. Se guardaron 23 con el servicio del revisor, que
valida el hash antes de reemplazar el archivo y guarda el original en
`data-persistence/backups/safe::Chainsmoker_Cat_Vol_1/`. El respaldo creado
termina en `f6948d6f-fd44-4bb1-9e0d-eda4eed04790.json`. Las páginas son
43, 46, 47, 58, 59, 63, 65, 67, 71, 73, 74, 79, 86, 88, 89, 94, 95, 105,
108, 112, 117, 122 y 129. La comparación con el respaldo confirmó que solo cambiaron las cajas
y, según el número de paneles, el campo `illustration_type` en esas
páginas.

Las 36 decisiones de Bloom ya estaban incorporadas. En las páginas 112,
119, 121 y 127, «Antes» se refiere a las cajas de la revisión original
guardada. La columna «Antes» del export posterior muestra otras cajas
porque el reporte cambió. Se verificó el mapping contra la base histórica
de cada una de esas cuatro selecciones.

## Cambio de detección

Safe permite separar marcos adyacentes cuando la tinta de alto contraste
distingue marcos alineados que cubren casi toda la altura y el área del
componente original. Una conexión oscura sigue vetando la separación.
Una página de fondo oscuro con varios fragmentos y sin candidatos
estructurales vuelve a página completa. Se mantienen los límites de
cobertura y de número de paneles.

Se descartó una separación más amplia porque rompía agrupaciones
revisadas en Chainsmoker Cat y empeoraba dos páginas de Bloom. También
se descartó una variante que aceptaba bordes menos alineados, pues
separaba el encabezado ilustrado de Chainsmoker Cat 53. Una prueba
sintética verifica el mismo tipo de separación con y sin puente de un
píxel, en orden manga y comic. La prueba con imágenes de Chainsmoker Cat
falló con el detector previo en la página 3 y pasó con el nuevo.

## Resultado en las 214 páginas de Chainsmoker Cat

| Métrica | Al inicio | Mapping reconciliado, detector anterior | Mapping reconciliado, detector nuevo |
|---|---:|---:|---:|
| Paneles esperados / detectados / coincidentes | 951 / 844 / 787 | 926 / 844 / 799 | 926 / 872 / 828 |
| Precisión | 93.25% | 94.67% | 94.95% |
| Recall | 82.75% | 86.29% | 89.42% |
| F1 | 87.69% | 90.28% | 92.10% |
| IoU medio | 0.9385 | 0.9475 | 0.9607 |
| Páginas correctas y en orden | 127 | 140 | 159 |
| Orden relativo por pares | 99.52% | 99.53% | 99.56% |

El detector mejoró 19 páginas completas y ninguna anteriormente correcta
empeoró. La página 108 seguía pendiente y pasó de cinco a cuatro paneles
coincidentes porque dividió una agrupación previamente aprobada. En la
página 2 dividió una agrupación aprobada de la fila inferior mientras la
fila superior sigue fusionada. El 100% por página requeriría coincidencia
de todos los paneles y su orden con IoU 0.50 o tolerancia de bordes de
35 px. El benchmark de Safe falla por recall y el baseline quedó intacto.

Pasaron 39 de las 69 páginas revisadas, frente a 28 con el detector previo.
Quedan pendientes las páginas 2, 4, 7, 8, 27, 33, 35, 38, 39, 41, 42,
47, 48, 50, 63, 66, 72, 81, 84, 85, 91, 96, 99, 105, 108, 109, 112,
116, 122 y 127. Entre ellas hay marcos escalonados o inclinados con cajas
solapadas, ilustraciones fragmentadas y un caso de orden en la página 42
con los cinco paneles emparejados. El volumen tiene otras 25 diferencias
fuera del feedback.

## Controles

| Libro, algoritmo | Páginas | F1 anterior → nuevo | Páginas correctas antes → después | Páginas antes correctas que empeoraron |
|---|---:|---:|---:|---:|
| Bloom Into You 8, Safe | 213 | 100% → 100% | 213 → 213 | 0 |
| Komi Can't Communicate 1, Safe | 190 | 95.61% → 95.61% | 153 → 153 | 0 |
| Scott Pilgrim 5, Safe | 218 | 97.11% → 97.28% | 195 → 197 | 0 |

El benchmark Smart de Chainsmoker Cat pasó sobre las 214 páginas con
F1 93.78%. Su diagnóstico antes y después coincide byte por byte, igual
que el diagnóstico Safe de Bloom. Pasaron 55 pruebas de detector,
colección y geometría, incluida la prueba con imágenes de Chainsmoker
Cat, y las 8 pruebas seleccionadas de Bloom. `luacheck` y
`stylua --check` pasaron en los tres archivos Lua modificados o agregados.

El reporte del revisor se actualizó para Safe de Chainsmoker Cat con 214
páginas y 55 diferencias. La comparación anterior y los demás grupos
se conservaron. El revisor carga el nuevo diagnóstico con
`./start-reviewer.sh` y una recarga del navegador. Las decisiones con
cajas o resultados que cambiaron pueden aparecer como antiguas porque
el revisor conserva su base histórica. Queda pendiente la validación
en KOReader o dispositivo. La suite completa no se ejecutó.
