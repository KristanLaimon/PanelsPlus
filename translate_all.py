import re

translations = {
    " fps)": " fps)",
    "(Long Press)": "(Mantención prolongada)",
    "(Long press config)": "(Configurar mantención)",
    "Adjust how long the camera pan between panels takes in milliseconds.": "Ajuste el tiempo de paneo de la cámara entre paneles en milisegundos.",
    "After each dictionary lookup that used OCR in a zoomed panel, ask whether the word was read correctly. If not, draw the correct word box and type what it actually says. Everything -- including the exact long-press point -- is appended to OCR.debug.session.log for later review. Off by default.": "Después de cada búsqueda en el diccionario que usó OCR en un panel ampliado, pregunte si la palabra se leyó correctamente. Si no, dibuje la caja correcta para la palabra y escriba lo que realmente dice. Todo, incluyendo el punto exacto de la pulsación prolongada, se anexa a OCR.debug.session.log para revisión posterior. Desactivado por defecto.",
    "Allow touch and hold on text inside zoomed panels to select text and trigger OCR-based dictionary lookups. On by default; turn off if the OCR word detection misfires often on your comics.": "Permitir tocar y mantener sobre el texto dentro de los paneles ampliados para seleccionar texto y activar búsquedas en el diccionario basadas en OCR. Activado por defecto; desactívelo si la detección de palabras OCR falla a menudo en sus cómics.",
    "Also pan across the boundary between the last panel of a page and the first panel of the next, instead of cutting instantly. Only animates when the adjacent page has already been detected in the background; otherwise the crossing stays an instant cut.": "También hace un paneo al límite entre el último panel de una página y el primer panel de la siguiente, en lugar de cortar instantáneamente. Solo se anima cuando la página adyacente ya se ha detectado en segundo plano; de lo contrario el salto es instantáneo.",
    "Always detect panels from a reduced-size page. Quickest, and the only mode that works on pages with a dark background, but it cannot split interlocking panel layouts.": "Siempre detectar paneles desde una página reducida. El modo más rápido y el único que funciona en páginas con fondo oscuro, pero no puede dividir paneles entrelazados.",
    "Always use KOReader's own panel detector. Slower and unable to find panels on pages with a dark background, but more literal about panel edges. Unavailable in comic mode, where dark backgrounds are common.": "Usar siempre el detector de paneles de KOReader. Más lento y no puede encontrar paneles en páginas con fondo oscuro, pero más exacto con los bordes del panel. No disponible en el modo cómic, donde los fondos oscuros son comunes.",
    "Animate page-to-page transitions (Actual: ": "Animar transiciones de página (Actual: ",
    "Close": "Cerrar",
    "Comic mode": "Modo cómic",
    "Comic mode (left to right)": "Modo cómic (de izquierda a derecha)",
    "Comic mode only. Split panels that touch edge to edge with no gap between them, using the black stroke the artist drew between them. Off by default: that stroke looks exactly like a horizon, a caption rule or a black band drawn inside a single panel, so this also cuts some whole panels in half. Try it if your comic's panels are being merged together.": "Solo modo cómic. Divide los paneles que se tocan de borde a borde sin espacio entre ellos, utilizando el trazo negro que dibujó el artista entre ellos. Desactivado por defecto: ese trazo se ve exactamente como un horizonte, una regla de subtítulos o una banda negra dibujada dentro de un solo panel, por lo que esto también corta algunos paneles enteros por la mitad. Inténtalo si los paneles de tu cómic se están fusionando.",
    "Comic mode: left to right": "Modo cómic: de izquierda a derecha",
    "Correct word/text": "Palabra/texto correcto",
    "Deep mode": "Modo Profundo",
    "Device rotation": "Rotación del dispositivo",
    "Disable plugin panel focusing": "Desactivar el enfoque de paneles del plugin",
    "Enable debugging logs": "Habilitar registros de depuración",
    "Hide progress": "Ocultar progreso",
    "How long the camera pan between panels takes.": "Cuánto tiempo toma el paneo de la cámara entre paneles.",
    "How many discrete steps the smooth camera pan between panels is split into. More frames look smoother but schedule more work per transition.": "En cuántos pasos discretos se divide el paneo suave de la cámara entre paneles. Más fotogramas se ven más suaves pero programan más trabajo por transición.",
    "How many steps the camera pan between panels is split into. More frames look smoother but schedule more work per transition.": "En cuántos pasos discretos se divide el paneo de la cámara entre paneles. Más fotogramas se ven más suaves pero programan más trabajo por transición.",
    "How much page area outside each panel's edges to reveal.": "Cuánta área de página revelar por fuera de los bordes del panel.",
    "Image rotation (this view only)": "Rotación de imagen (solo esta vista)",
    "Invert panel swipe direction": "Invertir la dirección de deslizamiento del panel",
    "Loose crop": "Recorte holgado",
    "Loose crop bleed": "Sangrado de recorte holgado",
    "Manga mode": "Modo manga",
    "Manga mode (right to left)": "Modo manga (de derecha a izquierda)",
    "Manga mode: right to left": "Modo manga: de derecha a izquierda",
    "More Panel Viewer Settings": "Más ajustes del visor de paneles",
    "More config...": "Más config...",
    "Native panel focusing enabled": "Enfoque de panel nativo habilitado",
    "Nav. Classic": "Nav. Clásica",
    "Nav. Smooth": "Nav. Suave",
    "Navigation Transition Settings": "Ajustes de transición de navegación",
    "No crop": "Sin recorte",
    "No rotation": "Sin rotación",
    "No, wrong": "No, incorrecto",
    "OCR debug review mode": "Modo de revisión de depuración de OCR",
    "Original size": "Tamaño original",
    "Pan animation duration...": "Duración de la animación de paneo...",
    "Panel detection": "Detección de paneles",
    "Panel margin": "Margen del panel",
    "Panels+ OCR debug": "Depuración de OCR de Panels+",
    "Panels+ OCR debug: no word was read here. Draw the correct box and type what it says.": "Depuración OCR Panels+: no se leyó ninguna palabra aquí. Dibuja el cuadro correcto y escribe lo que dice.",
    "Panels+ OCR debug\n\nWas the OCR word correct?": "Depuración OCR Panels+\n\n¿Era correcta la palabra OCR?",
    "Panels+ panel focusing enabled": "Enfoque de paneles de Panels+ habilitado",
    "Panels+: comic mode": "Panels+: modo cómic",
    "Panels+: manga mode": "Panels+: modo manga",
    "Panels+: manga/comic mode": "Panels+: modo manga/cómic",
    "Panels+: set comic mode": "Panels+: configurar modo cómic",
    "Panels+: set manga mode": "Panels+: configurar modo manga",
    "Panels+: toggle panel focusing": "Panels+: alternar el enfoque de panel",
    "Pre-render next panel": "Renderizar previamente el siguiente panel",
    "Quick mode": "Modo Rápido",
    "Render the next panel while you read the current one, so swiping to it is instant. Skipped automatically when the device is low on memory.": "Renderiza el siguiente panel mientras lees el actual, para que pasar a él sea instantáneo. Omitido automáticamente cuando el dispositivo tiene poca memoria.",
    "Rotate": "Rotar",
    "Save": "Guardar",
    "Scale": "Escalar",
    "Screenshot": "Captura de pantalla",
    "Show progress": "Mostrar progreso",
    "Skip": "Omitir",
    "Smart Mode": "Modo Inteligente",
    "Smooth navigation duration": "Duración de la navegación suave",
    "Smooth navigation frames": "Fotogramas de la navegación suave",
    "Split on drawn panel borders (experimental)": "Dividir en los bordes de panel dibujados (experimental)",
    "Strict crop": "Recorte estricto",
    "Swipe left/right to move between panels. Turning this off leaves panel navigation to taps, buttons, or physical page-turn keys only.": "Desliza el dedo hacia la izquierda/derecha para moverte entre paneles. Desactivar esto deja la navegación por el panel solo a toques, botones o teclas físicas de paso de página.",
    "Swipe to navigate (Actual: ": "Deslizar para navegar (Actual: ",
    "Tap screen sides to navigate (Actual: ": "Tocar a los lados de la pantalla para navegar (Actual: ",
    "Tap the correct word's top-left corner, then tap its bottom-right corner.": "Toque la esquina superior izquierda de la palabra correcta y, a continuación, toque su esquina inferior derecha.",
    "Tap the left or right edge of the screen to move to the previous or next panel, instead of only showing/hiding the controls. Which side advances depends on reading mode: right side in Comic mode, left side in Manga mode. Only active at standard zoom.": "Toque el borde izquierdo o derecho de la pantalla para moverse al panel anterior o siguiente, en lugar de solo mostrar/ocultar los controles. Qué lado avanza depende del modo de lectura: el lado derecho en modo cómic, el lado izquierdo en modo manga. Solo activo con zoom estándar.",
    "Top-left corner marked. Now tap the bottom-right corner.": "Esquina superior izquierda marcada. Ahora toque la esquina inferior derecha.",
    "Touch & hold text selection in zoom [EXPERIMENTAL]": "Selección de texto en zoom al mantener presionado [EXPERIMENTAL]",
    "Transition frames (Actual: ": "Fotogramas de transición (Actual: ",
    "Use KOReader's native panel zoom instead of the Panels+ panel sequence viewer.": "Usar el zoom de paneles nativo de KOReader en lugar del visor de secuencias de Panels+.",
    "Use fast detection, falling back to exact detection on layouts it cannot split. Recommended.": "Usar la detección rápida, recayendo a la detección exacta en los diseños que no se puedan dividir. Recomendado.",
    "Use this if panel navigation feels reversed on your device. It changes swipe direction only, not panel order.": "Utilice esto si la navegación por el panel se siente invertida en su dispositivo. Cambia solo la dirección de deslizamiento, no el orden del panel.",
    "What is actually written in the box you drew?": "¿Qué está escrito realmente en la caja que dibujó?",
    "With margin": "Con margen",
    "Write panel detection, render timings, and memory usage to KOReader's log. Useful for diagnosing slowness or crashes, otherwise leave off.": "Escriba la detección del panel, los tiempos de renderización y el uso de memoria en el registro de KOReader. Útil para diagnosticar lentitud o fallas, de lo contrario déjelo desactivado.",
    "Yes, correct": "Sí, correcto",
    "Zooms panels out a little to leave breathing room around them. Has no effect on full-page panels.": "Aleja un poco el zoom de los paneles para dejar espacio para respirar a su alrededor. No tiene ningún efecto en paneles de página completa.",
    "false": "falso",
    "frames": "fotogramas",
    "true": "verdadero"
}

with open("locales/es.po", "r", encoding="utf-8") as f:
    content = f.read()

for k, v in translations.items():
    # Replace any [ES] occurrences
    content = re.sub(
        f'msgid "{re.escape(k)}"\\nmsgstr "\\[ES\\] {re.escape(k)}"',
        f'msgid "{k}"\\nmsgstr "{v}"',
        content
    )
    # Also replace any non-[ES] ones if they were just mirrored in the python script
    content = re.sub(
        f'msgid "{re.escape(k)}"\\nmsgstr "{re.escape(k)}"',
        f'msgid "{k}"\\nmsgstr "{v}"',
        content
    )

with open("locales/es.po", "w", encoding="utf-8") as f:
    f.write(content)
print("All strings translated in es.po!")
