import re

translations = {
    "Panels+: comic mode": "Panels+: modo cómic",
    "Panels+: manga mode": "Panels+: modo manga",
    "Disable plugin panel focusing": "Desactivar el enfoque de paneles del plugin",
    "Use KOReader's native panel zoom instead of the Panels+ panel sequence viewer.": "Usar el zoom de paneles nativo de KOReader en lugar del visor de secuencias de Panels+.",
    "Manga mode (right to left)": "Modo manga (de derecha a izquierda)",
    "Comic mode (left to right)": "Modo cómic (de izquierda a derecha)",
    "Invert panel swipe direction": "Invertir la dirección de deslizamiento del panel",
    "Panel detection": "Detección de paneles",
    "Smart Mode": "Modo Inteligente",
    "Quick mode": "Modo Rápido",
    "Deep mode": "Modo Profundo",
    "Split on drawn panel borders (experimental)": "Dividir en los bordes de panel dibujados (experimental)",
    "Pre-render next panel": "Renderizar previamente el siguiente panel",
    "Enable debugging logs": "Habilitar registros de depuración",
    "OCR debug review mode": "Modo de revisión de depuración de OCR"
}

with open("locales/es.po", "r", encoding="utf-8") as f:
    content = f.read()

for k, v in translations.items():
    # We replace the msgstr "[ES] k" with msgstr "v"
    content = re.sub(
        f'msgid "{re.escape(k)}"\\nmsgstr "\\[ES\\] {re.escape(k)}"',
        f'msgid "{k}"\\nmsgstr "{v}"',
        content
    )

with open("locales/es.po", "w", encoding="utf-8") as f:
    f.write(content)
print("Updated es.po")
