#!/usr/bin/env python3
"""Genera Keyboard/EmojiData.swift a partir del emoji-test.txt oficial de Unicode.

Uso:
    python3 scripts/generate_emoji_catalog.py [emoji-test.txt] [--cldr CARPETA]

Sin argumento descarga https://www.unicode.org/Public/emoji/latest/emoji-test.txt.
Sólo entran las secuencias «fully-qualified» y en el orden del archivo, que es
el orden oficial de CLDR. Las pestañas son las del teclado de iOS: «Emoticonos y
personas» junta «Smileys & Emotion» y «People & Body», y «Actividades» va antes
que «Viajes y lugares». El grupo «Component» (tonos y peinados sueltos) no es
una pestaña.

Los nombres y palabras clave para buscar salen de CLDR (cldr-json, en una
versión fija); con --cldr se leen de una copia local con la misma estructura
de carpetas que ese repositorio.
"""

import argparse
import json
import re
import unicodedata
import urllib.request
from pathlib import Path

LATEST = "https://www.unicode.org/Public/emoji/latest/emoji-test.txt"
OUT = Path(__file__).resolve().parent.parent / "Keyboard" / "EmojiData.swift"

TONES = ["\U0001F3FB", "\U0001F3FC", "\U0001F3FD", "\U0001F3FE", "\U0001F3FF"]
TONE_WORDS = ["light skin tone", "medium-light skin tone", "medium skin tone",
              "medium-dark skin tone", "dark skin tone"]

# (título, SF Symbols del preferido al de respaldo, grupos de Unicode)
TABS = [
    ("Emoticonos y personas", ["face.smiling"], ["Smileys & Emotion", "People & Body"]),
    ("Animales y naturaleza", ["teddybear", "pawprint", "hare"], ["Animals & Nature"]),
    ("Comida y bebida", ["fork.knife", "cup.and.saucer"], ["Food & Drink"]),
    ("Actividades", ["soccerball", "sportscourt"], ["Activities"]),
    ("Viajes y lugares", ["car", "airplane"], ["Travel & Places"]),
    ("Objetos", ["lightbulb"], ["Objects"]),
    ("Símbolos", ["music.note", "number"], ["Symbols"]),
    ("Banderas", ["flag"], ["Flags"]),
]

# Desde esta versión puede que el iOS del usuario todavía no tenga el glifo
# (iOS 17.0 trae Emoji 15.0); el teclado los comprueba al arrancar.
CHECK_FROM = 15.1

# Nombres y palabras clave para buscar: el español de España y el de
# Latinoamérica, para que «pastel», «carro» o «enojado» encuentren lo mismo que
# «tarta», «coche» o «enfadado». Versión fija de CLDR: regenerar da lo mismo.
CLDR = "https://raw.githubusercontent.com/unicode-org/cldr-json/48.2.3/cldr-json"
CLDR_LOCALES = ["es", "es-419", "es-MX", "es-US"]

# Para desempatar los resultados de la búsqueda, los más usados primero: la
# clasificación de Unicode por frecuencia de uso. Lo que no está (lo más nuevo)
# va detrás, en el orden del catálogo.
FREQUENCY = Path(__file__).resolve().parent / "emoji-frequency.txt"

# Lo que CLDR todavía no nombra en español (Emoji 18.0).
MANUAL_NAMES = {
    "\U0001FAEB": ("cara agrietada", ["cara", "grieta", "rota", "romperse", "estrés", "agobio"]),
    "\U0001FAF9": ("pulgar hacia la izquierda", ["mano", "pulgar", "izquierda", "señalar", "dirección"]),
    "\U0001FAFA": ("pulgar hacia la derecha", ["mano", "pulgar", "derecha", "señalar", "dirección"]),
    "\U0001FACC": ("mariposa monarca", ["mariposa", "monarca", "insecto", "naranja", "migración"]),
    "\U0001FADD": ("pepinillo", ["pepinillo", "pepino", "encurtido", "comida", "verdura"]),
    "\U0001F6D9": ("faro", ["faro", "luz", "mar", "costa", "puerto", "barco"]),
    "\U0001FA8B": ("meteoro", ["meteoro", "meteorito", "asteroide", "espacio", "estrella fugaz"]),
    "\U0001FA8C": ("goma de borrar", ["goma", "borrar", "borrador", "escuela", "error"]),
    "\U0001FA8D": ("red con mango", ["red", "cazamariposas", "pesca", "mango", "atrapar"]),
}

# Las mismas que `EmojiSearchIndex.stopwords`: en las palabras clave no sirven
# (en la consulta no cuentan), en los nombres sí se quedan.
STOPWORDS = {"a", "al", "con", "de", "del", "e", "el", "en", "la", "las", "lo", "los",
             "mi", "o", "para", "por", "que", "se", "sin", "su", "sus", "te", "tu",
             "u", "un", "una", "unas", "unos", "y"}

# Palabras de los chats que CLDR no recoge.
EXTRA_KEYWORDS = {
    "\U0001F602": ["xd"],                              # 😂
    "\U0001F923": ["xd"],                              # 🤣
    "\U0001F44D": ["like", "vale", "dale"],            # 👍
    "\U0001F64F": ["porfa", "amén"],                   # 🙏
    "\U0001F97A": ["porfa", "porfis"],                 # 🥺
    "\U0001F618": ["muak"],                            # 😘
    "\U0001F44B": ["chao", "bye"],                     # 👋
    "\u2764\ufe0f": ["love", "te quiero", "te amo"],    # ❤️
    "\U0001F937": ["ni idea", "no sé", "nose"],        # 🤷
    "\U0001F382": ["torta"],                           # 🎂
}


def read(source):
    if re.match(r"https?://", source):
        with urllib.request.urlopen(source) as r:
            return r.read().decode("utf-8")
    return Path(source).read_text(encoding="utf-8")


def parse(text):
    rows, group, version = [], None, None
    for line in text.splitlines():
        m = re.match(r"# Version: (.*)", line)
        if m:
            version = m.group(1).strip()
        m = re.match(r"# group: (.*)", line)
        if m:
            group = m.group(1).strip()
            continue
        if not line or line.startswith("#"):
            continue
        m = re.match(r"([0-9A-F ]+?)\s*;\s*([\w-]+)\s*#\s*\S+\s+E(\d+\.\d+)\s+(.*)", line)
        if not m:
            raise SystemExit("línea que no se entiende: " + line)
        cps, status, ver, name = m.groups()
        if status != "fully-qualified" or group == "Component":
            continue
        emoji = "".join(chr(int(c, 16)) for c in cps.split())
        rows.append(dict(group=group, emoji=emoji, version=float(ver), name=name.strip()))
    return version, rows


def tones_of(emoji):
    return [TONES.index(c) for c in emoji if c in TONES]


def base_name(name):
    """«man: light skin tone, red hair» → «man: red hair»."""
    if ":" not in name:
        return name
    prefix, rest = name.split(":", 1)
    keep = [a.strip() for a in rest.split(",") if a.strip() not in TONE_WORDS]
    return prefix if not keep else prefix + ": " + ", ".join(keep)


def build(rows):
    bases = [r for r in rows if not tones_of(r["emoji"])]
    by_name = {r["name"]: r for r in bases}
    variants = {}
    for r in rows:
        tones = tones_of(r["emoji"])
        if not tones:
            continue
        name = base_name(r["name"])
        base = by_name.get(name)
        if base is None and ":" in name:
            # «kiss: person, person, …» cuelga de «kiss» (💏); igual «couple with heart».
            base = by_name.get(name.split(":")[0])
        if base is None:
            raise SystemExit("variante sin base: %s %s" % (r["emoji"], r["name"]))
        variants.setdefault(base["emoji"], []).append((tones, r["emoji"]))

    single, pair = {}, {}
    for base, found in variants.items():
        if all(len(t) == 1 for t, _ in found) and len(found) == 5:
            ordered = sorted(found, key=lambda v: v[0][0])
            assert [t[0] for t, _ in ordered] == [0, 1, 2, 3, 4], base
            single[base] = [e for _, e in ordered]
            continue
        grid = {}
        for t, e in found:
            key = (t[0], t[0]) if len(t) == 1 else (t[0], t[1])
            assert key not in grid, (base, key)
            grid[key] = e
        assert len(grid) == 25, (base, len(grid))
        pair[base] = [grid[(a, b)] for a in range(5) for b in range(5)]
    return bases, single, pair


def load_annotations(root):
    """Por idioma: emoji → {"default": [...], "tts": [...]}, con los derivados
    (tonos, familias, banderas) detrás de los propios."""
    result = []
    for locale in CLDR_LOCALES:
        merged = {}
        for package, key in (("cldr-annotations-full/annotations", "annotations"),
                             ("cldr-annotations-derived-full/annotationsDerived", "annotationsDerived")):
            data = json.loads(read("%s/%s/%s/annotations.json" % (root.rstrip("/"), package, locale)))
            for emoji, value in data[key]["annotations"].items():
                merged.setdefault(emoji, value)
        result.append(merged)
    return result


def load_frequency():
    """emoji (sin el selector U+FE0F) → puesto en la clasificación."""
    rank = {}
    for line in FREQUENCY.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("# "):
            continue
        rank.setdefault(line.strip().replace("\ufe0f", ""), len(rank))
    return rank


def fold(text):
    """Sin tildes, en minúsculas y sin signos, como `EmojiSearchIndex.tokens`.
    La ñ se queda: es otra letra y no una n con tilde («moño» no es «mono»)."""
    parts = unicodedata.normalize("NFC", text.lower()).split("ñ")
    parts = ["".join(c for c in unicodedata.normalize("NFD", p) if unicodedata.category(c) != "Mn")
             for p in parts]
    return " ".join(re.sub(r"[^\w#*]+", " ", "ñ".join(parts)).split())


def search_line(emoji, annotations):
    """«emoji ⇥ nombre|otro nombre ⇥ palabras» o None si nadie lo nombra."""
    names, words = [], []
    for locale in annotations:
        # CLDR guarda algunos sin el selector de emoji (❤ y no ❤️).
        value = locale.get(emoji) or locale.get(emoji.replace("\ufe0f", ""))
        if not value:
            continue
        names += [fold(t) for t in value.get("tts", [])]
        words += [fold(k) for k in value.get("default", [])]
    if emoji in MANUAL_NAMES:
        name, extra = MANUAL_NAMES[emoji]
        names.insert(0, fold(name))
        words += [fold(w) for w in extra]
    if not names:
        return None
    words += [fold(w) for w in EXTRA_KEYWORDS.get(emoji, [])]
    unique_names = []
    for n in names:
        if n and n not in unique_names:
            unique_names.append(n)
    in_names = {w for n in unique_names for w in n.split()}
    unique_words = []
    for phrase in words:
        for w in phrase.split():
            # Las letras sueltas («vitamina c») sólo estorban al buscar.
            if len(w) == 1 and w.isalpha():
                continue
            if w not in in_names and w not in STOPWORDS and w not in unique_words:
                unique_words.append(w)
    line = emoji + "\t" + "|".join(unique_names)
    return line + ("\t" + " ".join(unique_words) if unique_words else "")


def swift_list(items, indent, per_line=12):
    lines = []
    for i in range(0, len(items), per_line):
        chunk = items[i:i + per_line]
        lines.append(indent + ",".join('"%s"' % e for e in chunk) + ",")
    return "\n".join(lines)


def generate(version, rows, annotations):
    bases, single, pair = build(rows)
    known = {g for _, _, groups in TABS for g in groups}
    missing = {r["group"] for r in bases} - known
    if missing:
        raise SystemExit("grupos sin pestaña: %s" % missing)

    out = []
    out.append("import Foundation")
    out.append("")
    out.append("// Generado por scripts/generate_emoji_catalog.py a partir del emoji-test.txt")
    out.append("// oficial de Unicode (Emoji %s): sólo secuencias «fully qualified», en el" % version)
    out.append("// orden oficial de CLDR. No se edita a mano: se vuelve a generar.")
    out.append("//")
    out.append("// Las pestañas son las del teclado de iOS: «Emoticonos y personas» junta")
    out.append("// «Smileys & Emotion» y «People & Body», y «Actividades» va antes que")
    out.append("// «Viajes y lugares». Lo que el iOS del usuario todavía no sabe dibujar se")
    out.append("// quita al cargar (ver `EmojiSupport`).")
    out.append("enum EmojiCatalog {")
    out.append("    struct Category {")
    out.append("        let title: String")
    out.append("        /// SF Symbols del icono, del preferido al de respaldo.")
    out.append("        let symbols: [String]")
    out.append("        let emojis: [String]")
    out.append("    }")
    out.append("")
    out.append("    static let categories: [Category] = [")
    total = 0
    for title, symbols, groups in TABS:
        items = [r["emoji"] for r in bases if r["group"] in groups]
        total += len(items)
        syms = ", ".join('"%s"' % s for s in symbols)
        out.append('        Category(title: "%s", symbols: [%s], emojis: [' % (title, syms))
        out.append(swift_list(items, "            "))
        out.append("        ]),")
    out.append("    ]")
    out.append("")

    recent = [r["emoji"] for r in rows if r["version"] >= CHECK_FROM]
    out.append("    /// Emoji %s en adelante (bases y variantes): los iOS que no los traen" % CHECK_FROM)
    out.append("    /// los dibujarían como un cuadrado o como dos emojis sueltos.")
    out.append("    static let recentAdditions: Set<String> = [")
    out.append(swift_list(recent, "        "))
    out.append("    ]")
    out.append("")

    flat_single = []
    for base, vs in single.items():
        flat_single += [base] + vs
    out.append("    /// Base seguida de sus cinco tonos, de claro a oscuro.")
    out.append("    private static let singleToneRaw: [String] = [")
    out.append(swift_list(flat_single, "        ", per_line=6))
    out.append("    ]")
    out.append("")

    flat_pair = []
    for base, vs in pair.items():
        flat_pair += [base] + vs
    out.append("    /// Emojis de dos personas: base seguida de las 25 combinaciones, por filas")
    out.append("    /// según el tono de la primera persona y por columnas según el de la segunda.")
    out.append("    private static let pairToneRaw: [String] = [")
    out.append(swift_list(flat_pair, "        ", per_line=13))
    out.append("    ]")
    out.append("")
    lines, unnamed = [], []
    for title, _, groups in TABS:
        for r in bases:
            if r["group"] in groups:
                line = search_line(r["emoji"], annotations)
                if line is None:
                    unnamed.append("%s %s" % (r["emoji"], r["name"]))
                else:
                    lines.append(line)
    if unnamed:
        raise SystemExit("sin nombre en español (añadir a MANUAL_NAMES):\n  " + "\n  ".join(unnamed))
    rank = load_frequency()
    order = {line: i for i, line in enumerate(lines)}
    lines.sort(key=lambda l: (rank.get(l.split("\t", 1)[0].replace("\ufe0f", ""), len(rank)), order[l]))
    out.append("    /// Para buscar: una línea por emoji con «emoji ⇥ nombre|otro nombre ⇥")
    out.append("    /// palabras clave», todo sin tildes ni mayúsculas. Nombres y palabras de")
    out.append("    /// CLDR en el español de España y el de Latinoamérica. Del más usado al")
    out.append("    /// menos (clasificación de Unicode), que es como se desempatan los")
    out.append("    /// resultados; lo más nuevo, detrás. Lo lee `EmojiSearchIndex`.")
    out.append('    static let searchData = #"""')
    out += ["        " + line for line in lines]
    out.append('        """#')
    out.append("")
    out.append("    static let toneVariants: [String: [String]] = grouped(singleToneRaw, size: 5)")
    out.append("    static let pairToneVariants: [String: [String]] = grouped(pairToneRaw, size: 25)")
    out.append("")
    out.append("    private static func grouped(_ raw: [String], size: Int) -> [String: [String]] {")
    out.append("        var result: [String: [String]] = [:]")
    out.append("        var i = 0")
    out.append("        while i + size < raw.count {")
    out.append("            result[raw[i]] = Array(raw[(i + 1)...(i + size)])")
    out.append("            i += size + 1")
    out.append("        }")
    out.append("        return result")
    out.append("    }")
    out.append("}")
    out.append("")
    stats = dict(bases=total, single=len(single), pair=len(pair), recent=len(recent),
                 search=sum(len(l.encode("utf-8")) + 1 for l in lines) // 1024)
    return "\n".join(out), stats


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", nargs="?", default=LATEST, help="emoji-test.txt (ruta o URL)")
    parser.add_argument("--cldr", default=CLDR, help="raíz de cldr-json (ruta o URL)")
    args = parser.parse_args()
    version, rows = parse(read(args.source))
    annotations = load_annotations(args.cldr)
    swift, stats = generate(version, rows, annotations)
    OUT.write_text(swift, encoding="utf-8")
    print("Emoji %s → %s" % (version, OUT))
    print("  %(bases)d emojis, %(single)d con tonos, %(pair)d de dos personas, "
          "%(recent)d a comprobar en el dispositivo, %(search)d KB para buscar" % stats)


if __name__ == "__main__":
    main()
