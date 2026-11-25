"""
Smart Inventory · Experimento de concurrencia con dos sesiones (y una prueba de carga).

Reproduce los escenarios de la sección 5 del enunciado sobre PostgreSQL real:
cada escenario recarga 01_schema.sql y 02_seed.sql, abre conexiones independientes
(una por sesión), fuerza la carrera con una pausa entre la lectura y la escritura
y registra una línea de tiempo con lo que observa cada sesión.

Uso:
    pip install "psycopg[binary]"
    PGHOST=localhost PGPORT=55433 PGUSER=si_admin PGPASSWORD=si_local PGDATABASE=smart_inventory \
        python tests/concurrencia/experimento.py
    (si psql no está instalado, recarga los scripts con el psql del contenedor de docker-compose)

Salida: imprime el informe y lo guarda en evidencias/concurrencia_resultados.md
"""
from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from pathlib import Path

import psycopg
from psycopg import errors

RAIZ = Path(__file__).resolve().parents[2]
PAUSA = 3.0  # segundos que la sesión A mantiene su decisión antes de escribir
SKU = "FAR-SUERO-500"

lineas_informe: list[str] = []


def out(texto: str = "") -> None:
    print(texto)
    lineas_informe.append(texto)


def conectar(autocommit: bool = False) -> psycopg.Connection:
    return psycopg.connect(autocommit=autocommit, options="-c search_path=si,public")


def psql(script: str) -> list[str]:
    """Comando psql local o, si no está instalado, el psql del contenedor de docker-compose."""
    if shutil.which("psql"):
        return ["psql", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(RAIZ / script)]
    return ["docker", "compose", "-f", str(RAIZ / "docker-compose.yml"), "exec", "-T", "db",
            "psql", "-q", "-U", os.environ.get("PGUSER", "si_admin"),
            "-d", os.environ.get("PGDATABASE", "smart_inventory"), "-v", "ON_ERROR_STOP=1", "-f", f"/work/{script}"]


def recargar() -> None:
    """Deja la base en el estado exacto de la semilla (01, 02 y la función de laboratorio de 04)."""
    for script in ("sql/01_schema.sql", "sql/02_seed.sql", "sql/04_transactions.sql"):
        subprocess.run(psql(script), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def crear_pedidos(cantidades: list[int], sku: str = SKU) -> list[int]:
    with conectar(autocommit=True) as c:
        ids = []
        for q in cantidades:
            pid = c.execute(
                "INSERT INTO pedido (id_cliente, id_bodega, fecha_compromiso) "
                "VALUES (1, (SELECT id_bodega FROM bodega WHERE codigo='UIO'), current_date + 1) "
                "RETURNING id_pedido").fetchone()[0]
            c.execute("INSERT INTO detalle_pedido VALUES (%s, 1, (SELECT id_producto FROM producto WHERE sku=%s), %s)",
                      (pid, sku, q))
            ids.append(pid)
        return ids


def estado_saldo(sku: str = SKU) -> list[tuple]:
    with conectar(autocommit=True) as c:
        return c.execute(
            "SELECT l.numero_lote, e.cantidad_fisica, e.cantidad_reservada "
            "FROM existencia_lote e JOIN lote l USING (id_lote) JOIN producto p USING (id_producto) "
            "WHERE p.sku = %s AND (l.fecha_vencimiento IS NULL OR l.fecha_vencimiento > current_date) "
            "ORDER BY l.fecha_vencimiento NULLS LAST, l.numero_lote", (sku,)).fetchall()


def conciliacion() -> int:
    with conectar(autocommit=True) as c:
        return c.execute("SELECT (SELECT count(*) FROM v_conciliacion_fisico) + "
                         "(SELECT count(*) FROM v_conciliacion_reservado)").fetchone()[0]


class Linea:
    """Línea de tiempo compartida por las sesiones de un escenario."""

    def __init__(self) -> None:
        self.t0 = time.perf_counter()
        self.lock = threading.Lock()
        self.eventos: list[tuple[float, str, str]] = []

    def __call__(self, sesion: str, texto: str) -> None:
        with self.lock:
            self.eventos.append((time.perf_counter() - self.t0, sesion, texto))

    def imprimir(self) -> None:
        out("| t (s) | Sesión | Evento |")
        out("|---:|:---:|---|")
        for t, s, e in sorted(self.eventos):
            out(f"| {t:5.2f} | {s} | {e} |")


def vigilar_bloqueos(pids: dict[str, int], tl: Linea, fin: threading.Event) -> None:
    """Observa pg_stat_activity y anota cuándo una sesión queda esperando un bloqueo."""
    esperando: set[str] = set()
    with conectar(autocommit=True) as c:
        while not fin.is_set():
            for nombre, pid in pids.items():
                fila = c.execute("SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = %s",
                                 (pid,)).fetchone()
                bloqueada = fila is not None and fila[0] == "Lock"
                if bloqueada and nombre not in esperando:
                    esperando.add(nombre)
                    tl(nombre, f"queda ESPERANDO un bloqueo ({fila[1]})")
                elif not bloqueada and nombre in esperando:
                    esperando.discard(nombre)
                    tl(nombre, "se libera el bloqueo y continúa")
            time.sleep(0.02)


def sesion(nombre: str, pedido: int, aislamiento: str, bloquear: bool, pausa: float, retraso: float,
           tl: Linea, pids: dict, listo: threading.Barrier, reintentos_max: int = 0, resultado: dict | None = None):
    intento = 0
    conn = conectar()
    pids[nombre] = conn.info.backend_pid
    listo.wait()
    time.sleep(retraso)
    while True:
        intento += 1
        try:
            conn.execute(f"BEGIN ISOLATION LEVEL {aislamiento}")
            tl(nombre, f"BEGIN {aislamiento} (intento {intento}); reserva {'con FOR UPDATE' if bloquear else 'sin bloqueo'}")
            filas = conn.execute("SELECT numero_lote, cantidad FROM reservar_fefo_lab(%s::int, 1::smallint, %s, %s::numeric)",
                                 (pedido, bloquear, pausa)).fetchall()
            plan = ", ".join(f"{l}={q}" for l, q in filas)
            tl(nombre, f"reservas escritas: {plan}")
            conn.execute("COMMIT")
            tl(nombre, "COMMIT ✔")
            if resultado is not None:
                resultado[nombre] = ("COMMIT", plan, intento)
            break
        except errors.SerializationFailure as e:
            conn.execute("ROLLBACK")
            tl(nombre, f"40001 serialization_failure → ROLLBACK ({e.diag.message_primary})")
            if intento > reintentos_max:
                if resultado is not None:
                    resultado[nombre] = ("40001", "", intento)
                break
            tl(nombre, "el cliente REINTENTA la transacción completa")
        except psycopg.Error as e:
            conn.execute("ROLLBACK")
            tl(nombre, f"{e.sqlstate} {e.diag.message_primary[:90]} → ROLLBACK")
            if resultado is not None:
                resultado[nombre] = (e.sqlstate, "", intento)
            break
    conn.close()


def escenario(titulo: str, explicacion: str, aislamiento: str, bloquear: bool,
              q_a: int, q_b: int, reintentos: int = 0) -> None:
    recargar()
    pa, pb = crear_pedidos([q_a, q_b])
    out(f"\n### {titulo}\n")
    out(explicacion + "\n")
    disp = sum(f - r for _, f, r in estado_saldo())
    out(f"Saldo elegible inicial de {SKU}: " +
        ", ".join(f"{l} físico={f} reservado={r}" for l, f, r in estado_saldo()) +
        f" (disponible total = {disp}). Sesión A pide {q_a} (pedido {pa}); sesión B pide {q_b} (pedido {pb}).\n")
    tl, pids, fin, res = Linea(), {}, threading.Event(), {}
    barrera = threading.Barrier(2)
    ta = threading.Thread(target=sesion, args=("A", pa, aislamiento, bloquear, PAUSA, 0.0, tl, pids, barrera, reintentos, res))
    tb = threading.Thread(target=sesion, args=("B", pb, aislamiento, bloquear, 0.0, 0.5, tl, pids, barrera, reintentos, res))
    ta.start(); tb.start()
    while len(pids) < 2:
        time.sleep(0.01)
    vig = threading.Thread(target=vigilar_bloqueos, args=(pids, tl, fin))
    vig.start()
    ta.join(); tb.join(); fin.set(); vig.join()
    tl.imprimir()
    final = estado_saldo()
    out("\nSaldo final: " + ", ".join(f"{l} físico={f} reservado={r}" for l, f, r in final) +
        f". Divergencias libro/balance: {conciliacion()}. "
        f"Unidades reservadas en total: {sum(r for _, _, r in final)} de {sum(f for _, f, _ in final)}.")


def escenario_sin_protecciones() -> None:
    """Patrón ingenuo sobre una tabla de saldo SIN CHECK ni triggers: actualización perdida."""
    out("\n### E0 · Sin protecciones (tabla de saldo sin CHECK, la aplicación escribe el valor calculado)\n")
    out("Laboratorio aislado en el esquema `lab`: muestra qué pasaría si la aplicación leyera el saldo, "
        "calculara el nuevo valor y lo escribiera como número absoluto. Disponible = 7; A pide 5 y B pide 5.\n")
    with conectar(autocommit=True) as c:
        c.execute("DROP SCHEMA IF EXISTS lab CASCADE; CREATE SCHEMA lab;"
                  "CREATE TABLE lab.saldo (lote text PRIMARY KEY, fisico int, reservado int);"
                  "INSERT INTO lab.saldo VALUES ('SU-2411A', 4, 0), ('SU-2411B', 3, 0);")
    tl = Linea()

    def app(nombre: str, pedido_q: int, retraso: float, pausa: float) -> None:
        time.sleep(retraso)
        with conectar() as c:
            c.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
            filas = c.execute("SELECT lote, fisico, reservado FROM lab.saldo ORDER BY lote").fetchall()
            tl(nombre, "lee saldo: " + ", ".join(f"{l} disp={f - r}" for l, f, r in filas))
            pend, escrituras = pedido_q, []
            for lote, f, r in filas:
                toma = min(f - r, pend)
                if toma > 0:
                    escrituras.append((r + toma, lote)); pend -= toma
            time.sleep(pausa)
            for nuevo, lote in escrituras:
                c.execute("UPDATE lab.saldo SET reservado = %s WHERE lote = %s", (nuevo, lote))
            tl(nombre, "escribe reservado = " + ", ".join(f"{l}:{n}" for n, l in escrituras))
            c.execute("COMMIT")
            tl(nombre, "COMMIT ✔ (cree que reservó 5)")

    ha = threading.Thread(target=app, args=("A", 5, 0.0, 1.0))
    hb = threading.Thread(target=app, args=("B", 5, 0.2, 0.0))
    ha.start(); hb.start(); ha.join(); hb.join()
    tl.imprimir()
    with conectar(autocommit=True) as c:
        filas = c.execute("SELECT lote, fisico, reservado FROM lab.saldo ORDER BY lote").fetchall()
        c.execute("DROP SCHEMA lab CASCADE")
    out("\nSaldo final: " + ", ".join(f"{l} físico={f} reservado={r}" for l, f, r in filas) +
        ". Se prometieron 10 unidades con solo 7 físicas: **sobreventa por actualización perdida**; "
        "el saldo solo registra la escritura de A, que pisó la de B.")


def escenario_deadlock() -> None:
    recargar()
    out("\n### E6 · Deadlock por orden de bloqueo inconsistente vs. orden FEFO global\n")
    with conectar(autocommit=True) as c:
        la, lb = [r[0] for r in c.execute(
            "SELECT l.id_lote FROM lote l JOIN producto p USING (id_producto) "
            "WHERE p.sku=%s AND l.numero_lote IN ('SU-2411A','SU-2411B') ORDER BY l.numero_lote", (SKU,))]
    for etiqueta, orden_a, orden_b in (("Orden inconsistente (A: SU-2411A→SU-2411B, B: SU-2411B→SU-2411A)", (la, lb), (lb, la)),
                                       ("Orden FEFO común (ambas: SU-2411A→SU-2411B)", (la, lb), (la, lb))):
        out(f"\n**{etiqueta}**\n")
        tl, pids, barrera = Linea(), {}, threading.Barrier(2)

        def s(nombre: str, orden: tuple[int, int], retraso: float) -> None:
            conn = conectar()
            pids[nombre] = conn.info.backend_pid
            barrera.wait()
            time.sleep(retraso)
            try:
                conn.execute("BEGIN")
                conn.execute("SELECT 1 FROM existencia_lote WHERE id_lote = %s FOR UPDATE", (orden[0],))
                tl(nombre, f"bloquea lote {orden[0]}")
                time.sleep(1.0)
                conn.execute("SELECT 1 FROM existencia_lote WHERE id_lote = %s FOR UPDATE", (orden[1],))
                tl(nombre, f"bloquea lote {orden[1]}")
                time.sleep(0.3)
                conn.execute("COMMIT")
                tl(nombre, "COMMIT ✔")
            except psycopg.Error as e:
                conn.execute("ROLLBACK")
                tl(nombre, f"{e.sqlstate} {e.diag.message_primary} → ROLLBACK")
            conn.close()

        fin = threading.Event()
        a = threading.Thread(target=s, args=("A", orden_a, 0.0))
        b = threading.Thread(target=s, args=("B", orden_b, 0.2))
        a.start(); b.start()
        while len(pids) < 2:
            time.sleep(0.01)
        v = threading.Thread(target=vigilar_bloqueos, args=(pids, tl, fin)); v.start()
        a.join(); b.join(); fin.set(); v.join()
        tl.imprimir()


def carga(aislamiento: str, bloquear: bool, clientes: int = 20) -> dict:
    """N clientes reservan 1 unidad del mismo SKU a la vez (fila caliente)."""
    recargar()
    pedidos = crear_pedidos([1] * clientes, sku="FER-TORN-M6")
    stats = {"ok": 0, "reintentos": 0, "errores": 0}
    lock = threading.Lock()
    barrera = threading.Barrier(clientes)

    def cliente(pid: int) -> None:
        conn = conectar()
        barrera.wait()
        intento = 0
        while True:
            intento += 1
            try:
                conn.execute(f"BEGIN ISOLATION LEVEL {aislamiento}")
                conn.execute("SELECT * FROM reservar_fefo_lab(%s::int, 1::smallint, %s, 0.05)", (pid, bloquear))
                conn.execute("COMMIT")
                with lock:
                    stats["ok"] += 1
                break
            except errors.SerializationFailure:
                conn.execute("ROLLBACK")
                with lock:
                    stats["reintentos"] += 1
                time.sleep(0.01 * intento)
            except psycopg.Error:
                conn.execute("ROLLBACK")
                with lock:
                    stats["errores"] += 1
                break
        conn.close()

    t0 = time.perf_counter()
    hilos = [threading.Thread(target=cliente, args=(p,)) for p in pedidos]
    for h in hilos: h.start()
    for h in hilos: h.join()
    stats["segundos"] = round(time.perf_counter() - t0, 2)
    stats["divergencias"] = conciliacion()
    return stats


def main() -> None:
    out("# Resultados del experimento de concurrencia")
    with conectar(autocommit=True) as c:
        out(f"\nServidor: {c.execute('SELECT version()').fetchone()[0].split(' on ')[0]}. "
            f"Fecha de ejecución: {c.execute('SELECT now()::timestamp(0)').fetchone()[0]}.")
    out(f"Pausa de la sesión A entre decidir y escribir: {PAUSA} s; B arranca 0,5 s después de A.")

    escenario_sin_protecciones()
    escenario("E1 · READ COMMITTED sin bloqueo (leer → decidir → escribir)",
              "A pide 5 y B pide 2: la suma (7) es exactamente el disponible, así que ambos pedidos se podían atender.",
              "READ COMMITTED", False, 5, 2)
    escenario("E2 · READ COMMITTED + SELECT … FOR UPDATE en orden FEFO (estrategia elegida)",
              "Mismo caso que E1: A pide 5 y B pide 2.",
              "READ COMMITTED", True, 5, 2)
    escenario("E3 · READ COMMITTED + FOR UPDATE: las últimas unidades (la suma excede el saldo)",
              "A pide 5 y B pide 5 con 7 disponibles: solo uno puede ser atendido.",
              "READ COMMITTED", True, 5, 5)
    escenario("E4 · SERIALIZABLE sin bloqueo explícito, con reintento en el cliente",
              "A pide 5 y B pide 2. El cliente reintenta hasta 3 veces ante 40001.",
              "SERIALIZABLE", False, 5, 2, reintentos=3)
    escenario("E5 · SERIALIZABLE: las últimas unidades, con reintento",
              "A pide 5 y B pide 5 con 7 disponibles.",
              "SERIALIZABLE", False, 5, 5, reintentos=3)
    escenario_deadlock()

    out("\n### E7 · Costo bajo contención: 20 clientes reservan 1 unidad del mismo lote a la vez\n")
    out("| Estrategia | Reservas OK | Reintentos (40001) | Errores | Tiempo total (s) | Divergencias |")
    out("|---|---:|---:|---:|---:|---:|")
    for nombre, iso, bl in (("READ COMMITTED + FOR UPDATE", "READ COMMITTED", True),
                            ("SERIALIZABLE + reintento", "SERIALIZABLE", False)):
        s = carga(iso, bl)
        out(f"| {nombre} | {s['ok']} | {s['reintentos']} | {s['errores']} | {s['segundos']} | {s['divergencias']} |")

    recargar()
    destino = RAIZ / "evidencias" / "concurrencia_resultados.md"
    destino.parent.mkdir(exist_ok=True)
    destino.write_text("\n".join(lineas_informe) + "\n", encoding="utf-8")
    print(f"\nInforme guardado en {destino}")


if __name__ == "__main__":
    main()
