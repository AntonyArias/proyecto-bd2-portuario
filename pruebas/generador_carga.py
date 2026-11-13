#!/usr/bin/env python3
"""
generador_carga.py | Carga masiva y concurrente de movimientos logisticos (inspecciones)
para la prueba de estres. Enruta cada terminal a su nodo, registra exitos y fallos con marca de
tiempo, reintenta y redirige al standby cuando el primario cae.

Requisitos:  pip install psycopg2-binary      (ver requirements.txt)
Credenciales: variables de entorno estandar de PostgreSQL (PGUSER, PGPASSWORD, PGDATABASE, PGHOST).
              La contrasena NO va en el repo (ver .env.example).

Topologia (decisiones congeladas del equipo):
    terminal 1 = Moin    primario 5441   standby 5451
    terminal 2 = Limon   primario 5442   standby 5452
    terminal 3 = Caldera primario 5443   standby 5453
Cada terminal se escribe SOLO en su nodo: ninguna operacion toca dos fragmentos.

Modos de operacion:
    --modo insert   (por defecto) INSERT directo en puerto."InspeccionTransito".
                    Sirve para probar la caida de un nodo mientras no esten listos los
                    procedimientos del Rol 3.
    --modo llamada  Ejecuta la sentencia que se pase en --llamada, con parametros con nombre.
                    Parametros disponibles: %(id_terminal)s %(id_contenedor)s %(id_tipo_inspeccion)s
                    %(id_agente_aduanero)s %(resultado)s %(observaciones)s
                    Ejemplo (el nombre real lo define el Rol 3):
                    --llamada "CALL puerto.<procedimiento>(%(id_contenedor)s, %(id_tipo_inspeccion)s)"
                    (los nombres de parametro son internos del generador; no son columnas de la BD)

Ejemplos:
    python3 pruebas/generador_carga.py --hilos 8 --duracion 120
    python3 pruebas/generador_carga.py --total 20000 --pesos 3,2,1
    python3 pruebas/generador_carga.py --enrutamiento enrutamiento.json
"""
import argparse
import csv
import json
import os
import random
import signal
import sys
import threading
import time
from collections import Counter
from datetime import datetime

import psycopg2

PUERTOS_PRIMARIO = {1: 5441, 2: 5442, 3: 5443}
PUERTOS_STANDBY = {1: 5451, 2: 5452, 3: 5453}
NOMBRE_TERMINAL = {1: "Moin", 2: "Limon", 3: "Caldera"}
N_AGENTES = 30          # agentes cargados por 02_dml/02_entidades_comunes.sql (IDs 1..30)
TIPOS_INSPECCION = [1, 2, 3, 4, 5]
RESULTADO_POR_TIPO = {3: "RETENIDO", 4: "AUTORIZADO", 5: "AUTORIZADO"}
CODIGOS_REINTENTABLES = ("40001", "40P01")   # fallo de serializacion / deadlock: reintentar en el MISMO nodo


# ----------------------------------------------------------------------------- rutas
def construir_rutas(archivo):
    """terminal -> [primario, standby], cada uno (host, puerto, etiqueta).
    Soporta tanto el formato de infra/enrutamiento.json del Rol 2 como el formato diccionario."""
    host = os.environ.get("PGHOST", "localhost")
    rutas = {t: [(host, PUERTOS_PRIMARIO[t], "primario"),
                 (host, PUERTOS_STANDBY[t], "standby")] for t in PUERTOS_PRIMARIO}
    if not archivo and os.path.exists("infra/enrutamiento.json"):
        archivo = "infra/enrutamiento.json"
    if archivo and os.path.exists(archivo):
        with open(archivo, encoding="utf-8") as f:
            datos = json.load(f)
        if "terminales" in datos:
            # Formato de infra/enrutamiento.json (Rol 2):
            # {"terminales": {"1": {"nombre": "Moin", "nodos": ["localhost:5441", "localhost:5451"]}}}
            for t, info in datos["terminales"].items():
                nodos_lista = info.get("nodos", [])
                etiquetas = ("primario", "standby")
                pares = []
                for idx, hp in enumerate(nodos_lista[:2]):
                    h, p = hp.split(":")
                    pares.append((h or host, int(p), etiquetas[idx]))
                if pares:
                    rutas[int(t)] = pares
        else:
            # Formato alternativo directo: {"1": {"primario": {"host": "...", "port": 5441}, "standby": {...}}}
            for t, nodos in datos.items():
                if isinstance(nodos, dict) and "primario" in nodos:
                    rutas[int(t)] = [(nodos[k].get("host", host), int(nodos[k]["port"]), k)
                                     for k in ("primario", "standby")]
    return rutas


class Enrutador:
    """Recuerda, por terminal, que extremo esta activo (0 = primario, 1 = standby)."""

    def __init__(self, rutas):
        self.rutas = rutas
        self.activo = {t: 0 for t in rutas}
        self.lock = threading.Lock()

    def activa(self, t):
        with self.lock:
            i = self.activo[t]
        return i, self.rutas[t][i]

    def fallo(self, t, i):
        """Cambia de extremo solo si nadie lo cambio ya (evita bailar entre hilos)."""
        with self.lock:
            if self.activo[t] == i:
                self.activo[t] = 1 - i


def conectar(ruta):
    host, puerto, _ = ruta
    return psycopg2.connect(host=host, port=puerto, connect_timeout=3,
                            dbname=os.environ.get("PGDATABASE", "puerto"),
                            user=os.environ.get("PGUSER", "postgres"),
                            options="-c statement_timeout=10000")


def es_de_conexion(e):
    """Errores que justifican reintentar/redirigir (caida, corte, standby de solo lectura)."""
    return (isinstance(e, (psycopg2.OperationalError, psycopg2.InterfaceError))
            or getattr(e, "pgcode", None) == "25006")


# ----------------------------------------------------------------------------- contexto
class Contexto:
    def __init__(self, args, enrutador, contenedores, archivo_log):
        self.args = args
        self.enr = enrutador
        self.contenedores = contenedores            # terminal -> [id_contenedor]
        self.terminales = sorted(contenedores)
        pesos = [int(p) for p in args.pesos.split(",")]
        self.pesos = [pesos[t - 1] for t in self.terminales]
        self.parar = threading.Event()
        self.lock = threading.Lock()
        self.cuenta = Counter()                     # (terminal, resultado) -> n
        self.operaciones = 0
        self.primer_fallo = {}                      # terminal -> instante
        self.recuperado = {}                        # terminal -> instante
        self.f = open(archivo_log, "w", newline="", encoding="utf-8")
        self.csv = csv.writer(self.f)
        self.csv.writerow(["marca_tiempo", "hilo", "terminal", "extremo", "intento",
                           "resultado", "ms", "detalle"])

    def tomar_operacion(self):
        with self.lock:
            if self.args.total and self.operaciones >= self.args.total:
                return False
            self.operaciones += 1
            return True

    def registrar(self, hilo, t, ruta, intento, resultado, ms, detalle=""):
        ahora = time.time()
        with self.lock:
            self.cuenta[(t, resultado)] += 1
            if resultado == "FALLO":
                self.primer_fallo.setdefault(t, ahora)
            elif resultado == "OK" and t in self.primer_fallo and t not in self.recuperado:
                self.recuperado[t] = ahora
            self.csv.writerow([datetime.fromtimestamp(ahora).isoformat(timespec="milliseconds"),
                               hilo, t, f"{ruta[2]}:{ruta[1]}", intento, resultado,
                               f"{ms:.1f}", detalle])
            self.f.flush()


# ----------------------------------------------------------------------------- operaciones
def nueva_operacion(rnd, ctx, t):
    tipo = rnd.choice(TIPOS_INSPECCION)
    return {
        "id_terminal": t,
        "id_contenedor": rnd.choice(ctx.contenedores[t]),
        "id_tipo_inspeccion": tipo,
        "id_agente_aduanero": rnd.randint(1, N_AGENTES),
        "resultado": RESULTADO_POR_TIPO.get(tipo, rnd.choice(["CONFORME", "CONFORME", "OBSERVACION"])),
        "observaciones": f"generador_carga {datetime.now().isoformat(timespec='seconds')}",
    }


SQL_INSERT = """
    INSERT INTO puerto."InspeccionTransito"
        ("CI_IdContenedor", "CI_IdTipoInspeccion", "CI_IdAgenteAduanero",
         "CT_Resultado", "CT_Observaciones")
    VALUES (%(id_contenedor)s, %(id_tipo_inspeccion)s, %(id_agente_aduanero)s,
            %(resultado)s, %(observaciones)s)"""


def hilo_trabajo(n, ctx):
    rnd = random.Random(ctx.args.semilla + n)
    conexiones = {}                                 # (terminal, extremo) -> conexion
    sql = SQL_INSERT if ctx.args.modo == "insert" else ctx.args.llamada
    while not ctx.parar.is_set() and ctx.tomar_operacion():
        t = rnd.choices(ctx.terminales, weights=ctx.pesos)[0]
        op = nueva_operacion(rnd, ctx, t)
        for intento in range(1, ctx.args.intentos + 1):
            if ctx.parar.is_set():
                break
            i, ruta = ctx.enr.activa(t)
            inicio = time.perf_counter()
            conn = None
            try:
                conn = conexiones.get((t, i)) or conectar(ruta)
                conexiones[(t, i)] = conn
                with conn.cursor() as cur:
                    cur.execute(sql, op)
                conn.commit()
                ctx.registrar(n, t, ruta, intento, "OK", (time.perf_counter() - inicio) * 1000)
                break
            except psycopg2.Error as e:
                ms = (time.perf_counter() - inicio) * 1000
                detalle = (str(e).strip().splitlines() or [type(e).__name__])[0][:160]
                if conn is not None:
                    try:
                        conn.rollback()
                    except psycopg2.Error:
                        pass
                if getattr(e, "pgcode", None) in CODIGOS_REINTENTABLES:
                    # psycopg2 los clasifica como OperationalError: sin esta rama se tomarian por
                    # una caida de nodo y se redirigiria al standby (solo lectura) sin motivo.
                    ctx.registrar(n, t, ruta, intento, "REINTENTO", ms, detalle)
                    time.sleep(0.05 * intento)
                    continue
                if es_de_conexion(e):
                    if conn is not None:
                        try:
                            conn.close()
                        except psycopg2.Error:
                            pass
                    conexiones.pop((t, i), None)
                    ctx.registrar(n, t, ruta, intento, "FALLO", ms, detalle)
                    ctx.enr.fallo(t, i)                       # redirige al otro extremo
                    time.sleep(min(ctx.args.espera * intento, 5))
                else:                                          # error de datos: no se reintenta
                    ctx.registrar(n, t, ruta, intento, "ERROR_DATOS", ms, detalle)
                    break
        else:
            ctx.registrar(n, t, ctx.enr.activa(t)[1], ctx.args.intentos, "DESCARTADA", 0,
                          "agotados los reintentos")
    for c in conexiones.values():
        try:
            c.close()
        except psycopg2.Error:
            pass


# ----------------------------------------------------------------------------- arranque
def cargar_contenedores(enr, limite):
    """IDs de contenedores existentes de cada terminal (lee del primario o, si cae, del standby)."""
    res = {}
    for t, rutas in enr.rutas.items():
        for ruta in rutas:
            try:
                conn = conectar(ruta)
                with conn.cursor() as cur:
                    cur.execute('SELECT "CI_IdContenedor" FROM puerto."Contenedor" '
                                "ORDER BY random() LIMIT %s", (limite,))
                    ids = [r[0] for r in cur.fetchall()]
                conn.close()
                if ids:
                    res[t] = ids
                    break
            except psycopg2.Error as e:
                print(f"  aviso: terminal {t} {ruta[2]}:{ruta[1]} no disponible ({str(e).splitlines()[0]})")
    return res


def main():
    ap = argparse.ArgumentParser(description="Generador de carga concurrente para la prueba de estres")
    ap.add_argument("--hilos", type=int, default=8)
    ap.add_argument("--duracion", type=int, default=60, help="segundos (ignorado si se da --total)")
    ap.add_argument("--total", type=int, default=0, help="operaciones a intentar en total")
    ap.add_argument("--pesos", default="3,2,1", help="reparto por terminal 1,2,3 (por defecto 3,2,1)")
    ap.add_argument("--modo", choices=["insert", "llamada"], default="insert")
    ap.add_argument("--llamada", help="sentencia con parametros con nombre (modo llamada)")
    ap.add_argument("--intentos", type=int, default=8, help="reintentos por operacion")
    ap.add_argument("--espera", type=float, default=0.5, help="espera base entre reintentos (s)")
    ap.add_argument("--enrutamiento", help="JSON con las rutas (ver cabecera); por defecto, puertos congelados")
    ap.add_argument("--semilla", type=int, default=42)
    ap.add_argument("--log", help="archivo CSV de registro (por defecto pruebas/log_generador_<fecha>.csv)")
    args = ap.parse_args()
    if args.modo == "llamada" and not args.llamada:
        sys.exit("El modo 'llamada' requiere --llamada con la sentencia del Rol 3.")

    enr = Enrutador(construir_rutas(args.enrutamiento))
    print("Leyendo contenedores existentes de cada terminal...")
    contenedores = cargar_contenedores(enr, 5000)
    if not contenedores:
        sys.exit("No se pudo leer ningun nodo. Verifique que los nodos esten arriba y PGPASSWORD definido.")
    log = args.log or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   f"log_generador_{datetime.now():%Y%m%d_%H%M%S}.csv")
    ctx = Contexto(args, enr, contenedores, log)
    print(f"Terminales activas: {', '.join(NOMBRE_TERMINAL[t] for t in ctx.terminales)} | "
          f"hilos={args.hilos} modo={args.modo} | log: {log}")

    signal.signal(signal.SIGINT, lambda *_: ctx.parar.set())
    inicio = time.time()
    hilos = [threading.Thread(target=hilo_trabajo, args=(n, ctx), daemon=True) for n in range(args.hilos)]
    for h in hilos:
        h.start()

    ultimo = 0
    while any(h.is_alive() for h in hilos):
        time.sleep(0.5)
        t_actual = time.time() - inicio
        if not args.total and t_actual >= args.duracion:
            ctx.parar.set()
        if t_actual - ultimo >= 5:
            ultimo = t_actual
            with ctx.lock:
                ok = sum(v for (t, r), v in ctx.cuenta.items() if r == "OK")
                fallos = sum(v for (t, r), v in ctx.cuenta.items() if r == "FALLO")
            print(f"[{t_actual:6.1f}s] OK={ok}  FALLO={fallos}")
    for h in hilos:
        h.join()
    ctx.f.close()

    dur = time.time() - inicio
    print("\n=== RESUMEN ===")
    print(f"{'terminal':<10}{'OK':>8}{'FALLO':>8}{'ERROR_DATOS':>13}{'DESCARTADA':>12}{'REINTENTO':>11}")
    for t in ctx.terminales:
        c = [ctx.cuenta[(t, r)] for r in ("OK", "FALLO", "ERROR_DATOS", "DESCARTADA", "REINTENTO")]
        print(f"{NOMBRE_TERMINAL[t]:<10}{c[0]:>8}{c[1]:>8}{c[2]:>13}{c[3]:>12}{c[4]:>11}")
    total_ok = sum(v for (t, r), v in ctx.cuenta.items() if r == "OK")
    print(f"Duracion: {dur:.1f}s | OK totales: {total_ok} | {total_ok / dur:.1f} ops/s")
    for t, t0 in ctx.primer_fallo.items():
        if t in ctx.recuperado:
            print(f"{NOMBRE_TERMINAL[t]}: primer fallo -> primera escritura OK en "
                  f"{ctx.recuperado[t] - t0:.1f}s (recuperacion/redireccion)")
        else:
            print(f"{NOMBRE_TERMINAL[t]}: hubo fallos y NO se recupero durante la prueba")


if __name__ == "__main__":
    main()
