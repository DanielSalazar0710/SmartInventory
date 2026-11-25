"""Genera docs/diccionario_datos.md a partir del catálogo de PostgreSQL más las descripciones del equipo.

Uso: PGHOST=... PGDATABASE=smart_inventory python docs/generar_diccionario.py
Así el diccionario nunca se desactualiza respecto del DDL real (tipos, nulos, claves, CHECK y DEFAULT).
"""
from pathlib import Path
import psycopg

TABLAS = {
 "bodega": ("Centro de almacenamiento físico.", {
   "id_bodega": "Identificador sustituto.", "codigo": "Código corto de la bodega (UIO, GYE).",
   "nombre": "Nombre descriptivo.", "ciudad": "Ciudad donde opera.",
   "activa": "Desactivación lógica; una bodega con historial no se borra."}),
 "ubicacion": ("Posición física dentro de una bodega (rack, picking, cuarentena…).", {
   "id_ubicacion": "Identificador sustituto.", "id_bodega": "Bodega a la que pertenece.",
   "codigo": "Código físico, único dentro de la bodega.", "zona": "Zona operativa.",
   "tipo": "Uso de la ubicación; CUARENTENA no es vendible.", "activa": "Una ubicación inactiva no es elegible para picking."}),
 "proveedor": ("Empresa que abastece productos mediante órdenes de compra.", {
   "id_proveedor": "Identificador sustituto.", "codigo": "Código interno.", "nombre": "Razón social.",
   "email": "Correo de pedidos (opcional, único).", "lead_time_dias": "Días promedio entre orden y entrega.",
   "activo": "Desactivación lógica."}),
 "producto": ("Artículo identificado por SKU.", {
   "id_producto": "Identificador sustituto.", "sku": "Código comercial único.", "nombre": "Descripción.",
   "unidad": "Unidad de control del inventario.",
   "controla_vencimiento": "Si es verdadero, cada lote exige fecha de vencimiento.",
   "stock_minimo": "Umbral de reposición (punto de pedido).", "stock_objetivo": "Nivel al que se repone.",
   "id_proveedor_pref": "Proveedor sugerido para compras.", "activo": "Un producto inactivo conserva su historial pero no admite nuevas líneas."}),
 "lote": ("Partida de un producto con fechas propias; base de la trazabilidad y de FEFO.", {
   "id_lote": "Identificador sustituto.", "id_producto": "Producto al que pertenece el lote.",
   "numero_lote": "Número de lote del fabricante, único por producto.",
   "fecha_fabricacion": "Fecha de fabricación (opcional).",
   "fecha_vencimiento": "Vencimiento; NULL solo para productos sin vencimiento.",
   "recibido_en": "Primera recepción; desempate FEFO."}),
 "existencia_lote": ("Balance por lote y ubicación. Dato derivado del libro; solo lo escriben triggers.", {
   "id_lote": "Lote.", "id_ubicacion": "Ubicación.",
   "cantidad_fisica": "Unidades presentes = neto de movimientos del par (lote, ubicación).",
   "cantidad_reservada": "Unidades comprometidas = suma de reservas ACTIVAS.",
   "actualizado_en": "Último cambio aplicado por trigger."}),
 "orden_compra": ("Cabecera de compra a un proveedor para una bodega.", {
   "id_oc": "Identificador sustituto.", "id_proveedor": "Proveedor.", "id_bodega": "Bodega de destino.",
   "fecha_emision": "Fecha de emisión.", "fecha_esperada": "Fecha comprometida de entrega.",
   "estado": "ABIERTA → PARCIAL → COMPLETA (por trigger) o CANCELADA."}),
 "detalle_compra": ("Línea de la orden de compra.", {
   "id_oc": "Orden de compra.", "nro_linea": "Número de línea dentro de la OC.", "id_producto": "Producto ordenado (una línea por producto).",
   "cantidad_pedida": "Unidades ordenadas.", "costo_unitario": "Costo pactado."}),
 "recepcion": ("Evento de recepción física (guía de remisión) de una OC.", {
   "id_recepcion": "Identificador sustituto.", "id_oc": "Orden de compra recibida.",
   "id_bodega": "Bodega; debe coincidir con la de la OC (FK compuesta).",
   "recibido_en": "Fecha y hora de recepción.", "guia_remision": "Documento del transportista."}),
 "recepcion_linea": ("Cantidad recibida de una línea de OC en un lote y ubicación; genera la ENTRADA del libro.", {
   "id_recepcion_linea": "Identificador sustituto.", "id_recepcion": "Recepción.", "id_oc": "OC (repetida para la FK compuesta).",
   "nro_linea_oc": "Línea de la OC recibida.", "id_producto": "Producto (controla que lote y línea sean del mismo SKU).",
   "id_lote": "Lote recibido.", "id_ubicacion": "Ubicación donde se deja.", "cantidad_recibida": "Unidades recibidas en esta recepción."}),
 "cliente": ("Destinatario de los pedidos (datos sintéticos).", {
   "id_cliente": "Identificador sustituto.", "codigo": "Código interno.", "nombre": "Nombre o razón social."}),
 "pedido": ("Cabecera de pedido de cliente atendido desde una bodega.", {
   "id_pedido": "Identificador sustituto.", "id_cliente": "Cliente.", "id_bodega": "Bodega que despacha.",
   "creado_en": "Fecha de creación.", "fecha_compromiso": "Fecha prometida; base del nivel de servicio.",
   "estado": "ABIERTO, PARCIAL, RESERVADO, DESPACHADO o CANCELADO (transiciones por trigger).",
   "despachado_en": "Fecha de despacho; obligatoria solo si estado = DESPACHADO."}),
 "detalle_pedido": ("Línea del pedido; puede cubrirse con varios lotes.", {
   "id_pedido": "Pedido.", "nro_linea": "Número de línea.", "id_producto": "Producto solicitado (una línea por producto).",
   "cantidad": "Unidades solicitadas."}),
 "reserva": ("Asignación de una línea de pedido a un (lote, ubicación).", {
   "id_reserva": "Identificador sustituto.", "id_pedido": "Pedido.", "nro_linea": "Línea del pedido.",
   "id_producto": "Producto (redundancia controlada por FK compuestas).", "id_lote": "Lote asignado.",
   "id_ubicacion": "Ubicación de donde se toma.", "cantidad": "Unidades asignadas.",
   "estado": "ACTIVA → CONSUMIDA (despacho) o LIBERADA (cancelación).",
   "creada_en": "Momento de la reserva.", "cerrada_en": "Momento en que dejó de estar ACTIVA."}),
 "movimiento": ("Libro de movimientos inmutable; fuente de verdad del inventario.", {
   "id_movimiento": "Identificador sustituto.", "tipo": "ENTRADA, SALIDA, TRASLADO, AJUSTE o REVERSO.",
   "id_lote": "Lote afectado.", "id_ubicacion_origen": "Ubicación de la que sale (si aplica).",
   "id_ubicacion_destino": "Ubicación a la que entra (si aplica).", "cantidad": "Unidades, siempre positivas.",
   "ocurrido_en": "Fecha del hecho físico.", "registrado_en": "Fecha de registro en la base.",
   "id_recepcion_linea": "Origen de una ENTRADA.", "id_reserva": "Reserva consumida por una SALIDA.",
   "id_movimiento_revertido": "Movimiento que este REVERSO compensa.", "motivo": "Justificación (obligatoria en AJUSTE y REVERSO)."}),
}

with psycopg.connect() as c:
    filas = c.execute("""
      SELECT t.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull,
             pg_get_expr(d.adbin, d.adrelid), a.attidentity
        FROM pg_attribute a JOIN pg_class t ON t.oid = a.attrelid JOIN pg_namespace n ON n.oid = t.relnamespace
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
       WHERE n.nspname = 'si' AND t.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
       ORDER BY t.relname, a.attnum""").fetchall()
    cons = c.execute("""
      SELECT t.relname, con.conname, con.contype, pg_get_constraintdef(con.oid),
             array(SELECT attname FROM unnest(con.conkey) k JOIN pg_attribute ON attrelid = con.conrelid AND attnum = k)
        FROM pg_constraint con JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
       WHERE n.nspname = 'si' ORDER BY t.relname, con.contype, con.conname""").fetchall()

import re
def limpiar(d: str) -> str:
    d = re.sub(r"::(character varying|text\[\]|text|date|integer|timestamp with time zone)", "", d)
    d = re.sub(r"= ANY \(\(ARRAY\[(.*?)\]\)\)", lambda m: "IN (" + m.group(1) + ")", d)
    d = d.replace("REFERENCES si.", "REFERENCES ").replace(" ON UPDATE RESTRICT ON DELETE RESTRICT", " (RESTRICT)")
    return d.replace("|", "¦").replace("`", "")

md = ["# Diccionario de datos", "",
      "Generado desde el catálogo de PostgreSQL (esquema `si`). Clave: PK clave primaria, FK clave foránea, "
      "UQ participa en una restricción UNIQUE. Las restricciones de varias columnas se listan bajo cada tabla.", ""]
for tabla, (desc, cols) in TABLAS.items():
    md += [f"## {tabla}", "", desc, "", "| Columna | Tipo | Nulo | Clave | Default | Significado |", "|---|---|:---:|---|---|---|"]
    for t, col, tipo, nn, dflt, ident in filas:
        if t != tabla: continue
        claves = []
        for tt, nom, ct, defi, colsc in cons:
            if tt == tabla and col in colsc:
                etiqueta = {"p": "PK", "f": "FK", "u": "UQ"}.get(ct)
                if etiqueta and etiqueta not in claves: claves.append(etiqueta)
        dflt = "identity" if ident else (dflt or "").replace("::character varying", "").replace("'", "’")
        tipo = tipo.replace("character varying", "varchar").replace("timestamp with time zone", "timestamptz")
        md.append(f"| `{col}` | {tipo} | {'No' if nn else 'Sí'} | {' '.join(claves)} | {dflt} | {cols.get(col, '')} |")
    md += ["", "Restricciones:", ""]
    for tt, nom, ct, defi, colsc in cons:
        if tt == tabla and ct in "pfuc":
            md.append(f"- `{nom}`: `{limpiar(defi)}`")
    md.append("")
Path(__file__).with_name("diccionario_datos.md").write_text("\n".join(md), encoding="utf-8")
print("ok")
