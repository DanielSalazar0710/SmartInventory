"""Genera el diagrama ER (docs/img/diagrama_er.png/.svg) leyendo el catálogo de PostgreSQL.

Uso: PGHOST=... PGDATABASE=smart_inventory python docs/generar_er.py   (requiere Graphviz)
Las claves y cardinalidades salen de las restricciones reales del esquema `si`.
"""
import subprocess
from pathlib import Path

import psycopg

SALIDA = Path(__file__).resolve().parent / "img"
UNO_A_MUCHOS_OBLIGATORIO = {("orden_compra", "detalle_compra"), ("pedido", "detalle_pedido"),
                            ("recepcion", "recepcion_linea")}
GRUPOS = {
    "Catálogo y almacén": (["bodega", "ubicacion", "producto", "lote", "existencia_lote"], "#1f3a5f"),
    "Reposición y compras": (["proveedor", "orden_compra", "detalle_compra", "recepcion", "recepcion_linea"], "#a65c1a"),
    "Movimientos y fulfillment": (["cliente", "pedido", "detalle_pedido", "reserva", "movimiento"], "#2f6f4f"),
}

with psycopg.connect() as c:
    cols = c.execute("""
        SELECT a.attrelid::regclass::text, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, a.attnum
          FROM pg_attribute a JOIN pg_class t ON t.oid = a.attrelid JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE n.nspname = 'si' AND t.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
         ORDER BY 1, a.attnum""").fetchall()
    cons = c.execute("""
        SELECT con.conrelid::regclass::text, con.conname, con.contype,
               array(SELECT attname FROM unnest(con.conkey) k JOIN pg_attribute ON attrelid = con.conrelid AND attnum = k),
               con.confrelid::regclass::text
          FROM pg_constraint con JOIN pg_namespace n ON n.oid = con.connamespace
         WHERE n.nspname = 'si' AND con.contype IN ('p','f','u')""").fetchall()

tabla = lambda s: s.split(".")[-1]
pk, fk, uq = {}, {}, {}
for t, nombre, tipo, columnas, ref in cons:
    t = tabla(t)
    for col in columnas:
        if tipo == "p": pk.setdefault(t, set()).add(col)
        if tipo == "f": fk.setdefault(t, set()).add(col)
        if tipo == "u": uq.setdefault(t, set()).add(col)
unicos = {(tabla(t), tuple(cs)) for t, _, tipo, cs, _ in cons if tipo in ("u", "p")}
notnull = {(tabla(t), col): nn for t, col, _, nn, _ in cols}

def nodo(t, color):
    filas = [f'<tr><td bgcolor="{color}" colspan="3"><font color="white"><b>{t.upper()}</b></font></td></tr>']
    for tt, col, tipo, nn, _ in cols:
        if tabla(tt) != t: continue
        marcas = "/".join(m for m, s in (("PK", pk), ("FK", fk), ("UQ", uq)) if col in s.get(t, ()))
        tipo = tipo.replace("character varying", "varchar").replace("timestamp with time zone", "timestamptz")
        nulo = "" if nn else " ∅"
        filas.append(f'<tr><td align="left"><font point-size="9">{marcas or " "}</font></td>'
                     f'<td align="left">{"<b>" + col + "</b>" if col in pk.get(t, ()) else col}</td>'
                     f'<td align="left"><font color="#555555" point-size="9">{tipo}{nulo}</font></td></tr>')
    return f'"{t}" [label=<<table border="0" cellborder="1" cellspacing="0" cellpadding="3">{"".join(filas)}</table>>];'

lineas = ['digraph ER {', 'graph [rankdir=LR, splines=true, nodesep=0.5, ranksep=1.1, fontname="DejaVu Sans", '
          'label=<<b>Smart Inventory · Diagrama entidad–relación</b><br/><font point-size="10">'
          'PK clave primaria · FK clave foránea · UQ parte de una restricción UNIQUE · ∅ admite NULL · '
          'pata de gallo = muchos, barra = uno, círculo = opcional</font>>, labelloc=t, fontsize=18];',
          'node [shape=plaintext, fontname="DejaVu Sans", fontsize=10];',
          'edge [fontname="DejaVu Sans", fontsize=8, color="#555555", dir=both];']
for i, (g, (ts, color)) in enumerate(GRUPOS.items()):
    lineas.append(f'subgraph cluster_{i} {{ label="{g}"; fontsize=13; style="rounded,dashed"; color="{color}"; fontcolor="{color}";')
    lineas += [nodo(t, color) for t in ts]
    lineas.append("}")
for t, nombre, tipo, columnas, ref in sorted(cons, key=lambda x: x[1]):
    if tipo != "f": continue
    hijo, padre = tabla(t), tabla(ref)
    opcional = not all(notnull[(hijo, col)] for col in columnas)
    tail = "teeodot" if opcional else "teetee"
    if (hijo, tuple(columnas)) in unicos or (hijo, tuple(sorted(columnas))) in {(a, tuple(sorted(b))) for a, b in unicos}:
        head = "teeodot"
    elif (padre, hijo) in UNO_A_MUCHOS_OBLIGATORIO:
        head = "crowtee"
    else:
        head = "crowodot"
    lineas.append(f'"{padre}" -> "{hijo}" [arrowtail={tail}, arrowhead={head}, '
                  f'xlabel="{nombre}", style={"dashed" if opcional else "solid"}];')
lineas.append("}")
dot = "\n".join(lineas)
(SALIDA / "diagrama_er.dot").write_text(dot, encoding="utf-8")
for fmt in ("png", "svg"):
    subprocess.run(["dot", f"-T{fmt}", "-Gdpi=170" if fmt == "png" else "-Gdpi=72",
                    "-o", str(SALIDA / f"diagrama_er.{fmt}")], input=dot.encode(), check=True)
print("diagrama generado en", SALIDA)
