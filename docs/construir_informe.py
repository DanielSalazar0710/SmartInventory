"""Arma el informe a partir de docs/*.md y de las salidas reales en evidencias/.

Uso:  python docs/construir_informe.py      -> docs/informe.md y docs/informe.html
      node docs/html_a_pdf.js               -> docs/Informe_Deber2_Smart_Inventory.pdf
Los resultados de consultas, pruebas y experimentos se copian de evidencias/, no se escriben a mano.
"""
import re
import subprocess
from pathlib import Path

DOCS = Path(__file__).resolve().parent
RAIZ = DOCS.parent
EVID = RAIZ / "evidencias"


def psql_a_markdown(bloque: str, quitar: tuple[str, ...] = ()) -> str:
    """Convierte una tabla alineada de psql en una tabla Markdown."""
    lineas = [l for l in bloque.strip("\n").splitlines() if l.strip()]
    cab = [c.strip() for c in lineas[0].split("|")]
    filas = []
    for l in lineas[2:]:
        if re.match(r"^\(\d+ rows?\)$", l.strip()):
            break
        filas.append([c.strip() for c in l.split("|")])
    idx = [i for i, c in enumerate(cab) if c not in quitar]
    out = ["| " + " | ".join(cab[i].replace("_", " ") for i in idx) + " |",
           "|" + "|".join("---" for _ in idx) + "|"]
    for f in filas:
        out.append("| " + " | ".join(f[i].replace("|", "¦") for i in idx) + " |")
    return "\n".join(out)


def tablas_psql(texto: str) -> list[str]:
    """Extrae todas las tablas alineadas de una salida de psql."""
    res, actual = [], []
    lineas = texto.splitlines()
    i = 0
    while i < len(lineas):
        if i + 1 < len(lineas) and re.match(r"^-+(\+-+)*$", lineas[i + 1].strip()) and "|" in lineas[i]:
            j = i + 2
            while j < len(lineas) and not re.match(r"^\(\d+ rows?\)$", lineas[j].strip()):
                j += 1
            res.append("\n".join(lineas[i:j + 1]))
            i = j + 1
        else:
            i += 1
    return res


def sql_de_consultas() -> dict[str, str]:
    texto = (RAIZ / "sql/03_queries.sql").read_text(encoding="utf-8")
    partes = {}
    for n in range(1, 9):
        ini = texto.index(f"\\echo '== Q{n}.")
        ini = texto.index("\n", ini) + 1
        fin = texto.find("\n-- ----", ini)
        cuerpo = texto[ini:fin if fin != -1 else None].strip()
        cuerpo = "\n".join(l for l in cuerpo.splitlines() if not l.startswith("\\echo"))
        partes[f"Q{n}"] = cuerpo
    return partes


def resultados_consultas() -> dict[str, str]:
    texto = (EVID / "consultas_resultados.txt").read_text(encoding="utf-8")
    res = {}
    for n in range(1, 9):
        ini = texto.index(f"== Q{n}.")
        fin = texto.find(f"== Q{n + 1}.") if n < 8 else len(texto)
        tablas = tablas_psql(texto[ini:fin])
        md = "**Resultado:**\n\n" + psql_a_markdown(tablas[0])
        if n == 8 and len(tablas) > 1:
            md += "\n\n**Detalle de quiebres:**\n\n" + psql_a_markdown(tablas[1])
        res[f"Q{n}"] = md
    return res


def bajar_niveles(md: str, n: int = 1) -> str:
    return re.sub(r"^(#+) ", lambda m: "#" * (len(m.group(1)) + n) + " ", md, flags=re.M)


def main() -> None:
    sql, res = sql_de_consultas(), resultados_consultas()
    pruebas = psql_a_markdown(tablas_psql((EVID / "pruebas_integridad_resultados.txt").read_text(encoding="utf-8"))[0],
                              quitar=("mensaje",))
    vista = psql_a_markdown(tablas_psql((EVID / "vista_stock_disponible.txt").read_text(encoding="utf-8"))[0],
                            quitar=("id_producto", "nombre", "id_bodega"))
    conc = (EVID / "concurrencia_resultados.md").read_text(encoding="utf-8")
    conc = conc[conc.index("### E0"):]
    conc = conc.replace("### ", "#### ")
    conc = "### Líneas de tiempo observadas\n\n" + conc

    dicc = (DOCS / "diccionario_datos.md").read_text(encoding="utf-8")
    dicc = dicc.replace("# Diccionario de datos", "# 3. Diccionario de datos", 1)
    dicc = re.sub(r"^## (\w+)$", r"### \1", dicc, flags=re.M)

    partes = [(DOCS / "01_modelo.md").read_text(encoding="utf-8"), dicc]
    for nombre in ("02_matriz_reglas.md", "03_normalizacion.md", "04_implementacion.md", "05_consultas.md",
                   "06_vistas_indices.md", "07_concurrencia.md", "08_sprints.md", "09_conclusiones.md"):
        partes.append((DOCS / nombre).read_text(encoding="utf-8"))
    md = "\n\n".join(partes)
    md = md.replace("{{PRUEBAS}}", pruebas).replace("{{VISTA_STOCK}}", vista).replace("{{CONCURRENCIA}}", conc)
    for k, v in sql.items():
        md = md.replace("{{SQL_" + k + "}}", "```sql\n" + v + "\n```")
    for k, v in res.items():
        md = md.replace("{{RES_" + k + "}}", v)
    assert "{{" not in md, "quedó un marcador sin reemplazar"
    (DOCS / "informe.md").write_text(md, encoding="utf-8")

    subprocess.run(["pandoc", str(DOCS / "informe.md"), "-f", "markdown-subscript-superscript-smart-inline_notes-tex_math_dollars+pipe_tables", "-t", "html5",
                    "--standalone", "--toc", "--toc-depth=2", "--metadata", "title=Smart Inventory",
                    "--template", str(DOCS / "plantilla_informe.html"),
                    "-o", str(DOCS / "informe.html")], check=True, cwd=DOCS)
    print("informe.md e informe.html generados")


if __name__ == "__main__":
    main()
