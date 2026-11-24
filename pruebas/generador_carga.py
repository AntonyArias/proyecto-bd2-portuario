#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
generador_carga.py | Carga masiva y concurrente para la prueba de estres (Rol 1).

Que hace
  * Lee infra/enrutamiento.json (Rol 2): para cada terminal, su primario y su standby.
  * Conecta a cada terminal con host=primario,standby + target_session_attrs=read-write:
    libpq elige solo el nodo que acepta escrituras, asi que tras un failover (standby
    promovido) basta con reconectar; no hay que editar el archivo.
  * Ejecuta movimientos logisticos en paralelo (un grupo de hilos por terminal):
      ingresar  -> CALL puerto.sp_ingresar_manifiesto(...)   (Rol 3)
      despachar -> CALL puerto.sp_despachar_mercancia(...)   (Rol 3)
      retener / liberar / revisar -> INSERT en "InspeccionTransito"; los triggers del
                   Rol 3 aplican el efecto sobre contenedor e inventario (no hay
                   procedimiento para estos movimientos).
  * Registra cada intento (marca de tiempo, hilo, terminal, operacion, resultado, SQLSTATE,
    ms) en un CSV y, al final, el tiempo entre la caida detectada y la primera escritura
    exitosa de cada terminal.

Clasificacion de errores
  OK / OK_VERIFICADO  escritura confirmada
  REINTENTO           deadlock o fallo de serializacion (40P01 / 40001): se reintenta en el mismo nodo
  FALLO_CONEXION      nodo caido o sin promover: se reconecta con espera creciente (hasta --espera-max)
  RECHAZADA           el procedimiento rechazo por regla de negocio (SQLSTATE P0xxx, 23xxx); NO se reintenta
  DESCARTADA          se agoto --espera-max sin lograr escribir
  ERROR_OTRO          cualquier otro error (se registra, no se reintenta)
  SIN_CANDIDATO       no habia contenedor elegible para esa operacion

Uso
  pip install -r requirements.txt
  export GEN_CLAVE=...                     # clave del usuario (por defecto operador_user)
  python3 pruebas/generador_carga.py --hilos 6 --duracion 120
  python3 pruebas/generador_carga.py --total 20000 --pesos 3,2,1
  python3 pruebas/generador_carga.py --solo-ejemplo     # muestra la configuracion y un ejemplo, sin conectar

Variables de entorno
  GEN_USUARIO  usuario de conexion (por defecto operador_user)
  GEN_CLAVE    su clave; si falta se prueba OPERADOR_PASS y, si el usuario es postgres,
               POSTGRES_PASSWORD; si tampoco existe, libpq usa PGPASSWORD o ~/.pgpass.

Supuesto: se ejecuta UN solo generador a la vez (los numeros de manifiesto y de contenedor
se toman a partir del maximo existente en cada nodo).
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
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

try:
    import psycopg2
except ImportError:          # permite --solo-ejemplo y las pruebas sin el driver
    psycopg2 = None

RAIZ = Path(__file__).resolve().parent.parent
ENRUTAMIENTO_DEFECTO = RAIZ / "infra" / "enrutamiento.json"
NOMBRE_TERMINAL = {1: "Moin", 2: "Limon", 3: "Caldera"}
PREFIJO_ISO = {1: "MOIU", 2: "LIMU", 3: "CALU"}
PUERTOS_ORIGEN = ["Shanghai", "Rotterdam", "Miami", "Cartagena", "Colon", "Veracruz", "Santos", "Valencia"]

# id_tipo_contenedor -> (es_refrigerado, es_de_20_pies); coincide con el catalogo TipoContenedor
TIPOS_CONTENEDOR = {1: (False, True), 2: (False, False), 3: (False, False),
                    4: (True, True), 5: (True, False)}
PARTIDAS_REFRIGERADAS = (1, 2)            # el trigger de cadena de frio exige estas partidas
PARTIDAS_SECAS = tuple(range(3, 17))      # y prohibe usarlas en contenedores secos
TEMPERATURAS = (-18.0, 4.0, 2.0)

# estados de EstadoContenedor
ESTADOS_ACTIVOS = (2, 3, 4, 6)            # se puede despachar o retener
ESTADOS_REVISION = (1, 2, 3)              # se puede pasar a EN_INSPECCION
ESTADO_RETENIDO = 5

MEZCLA_DEFECTO = "ingresar=30,despachar=30,retener=15,liberar=10,revisar=15"
RESULTADOS_EXITO = {"OK", "OK_VERIFICADO"}

CODIGOS_REINTENTABLES = {"40001", "40P01"}
CODIGOS_RECONECTAR = {"25006", "57P01", "57P02", "57P03", "57014", "53300"}

SQL_CANDIDATO = ('SELECT "CI_IdContenedor" FROM puerto."Contenedor" '
                 'WHERE "CI_IdEstadoContenedor" = ANY(%s) '
                 'ORDER BY random() LIMIT 1 FOR UPDATE SKIP LOCKED')
SQL_INSPECCION = ('INSERT INTO puerto."InspeccionTransito" '
                  '("CI_IdContenedor", "CI_IdTipoInspeccion", "CI_IdAgenteAduanero", '
                  '"CT_Resultado", "CT_Observaciones") '
                  'VALUES (%s, %s, %s, %s, %s) RETURNING "CI_IdInspeccionTransito"')
SQL_INGRESAR = ("CALL puerto.sp_ingresar_manifiesto(%s::smallint, %s::char(7), %s::varchar, "
                "%s::varchar, %s::varchar, %s::timestamptz, %s::jsonb, NULL::bigint)")
SQL_DESPACHAR = "CALL puerto.sp_despachar_mercancia(%s::bigint, %s::varchar, %s::text, NULL::bigint)"


# --------------------------------------------------------------------------------------
# Clasificacion de errores
# --------------------------------------------------------------------------------------
def clasificar(exc):
    """REINTENTAR | RECONECTAR | DUPLICADO | NEGOCIO | OTRO"""
    codigo = getattr(exc, "pgcode", None) or ""
    if codigo in CODIGOS_REINTENTABLES:
        return "REINTENTAR"
    if codigo in CODIGOS_RECONECTAR or codigo.startswith("08"):
        return "RECONECTAR"
    if not codigo and psycopg2 is not None and isinstance(
            exc, (psycopg2.OperationalError, psycopg2.InterfaceError)):
        return "RECONECTAR"
    if codigo == "23505":
        return "DUPLICADO"
    if codigo.startswith("P0") or codigo.startswith("23"):
        return "NEGOCIO"
    return "OTRO"


def resumen_error(exc):
    texto = (str(exc).strip().splitlines() or [type(exc).__name__])[0]
    return texto[:160]


# --------------------------------------------------------------------------------------
# Generacion de datos (respeta las reglas de los triggers del Rol 3)
# --------------------------------------------------------------------------------------
class Contadores:
    """Numeracion unica por terminal para manifiestos y numeros ISO, segura entre hilos."""

    def __init__(self):
        self._lock = threading.Lock()
        self._sig = {}

    def iniciar(self, terminal, ultimo_manifiesto, ultimo_iso):
        self._sig[(terminal, "m")] = ultimo_manifiesto + 1
        self._sig[(terminal, "i")] = ultimo_iso + 1

    def siguiente(self, terminal, clase):
        with self._lock:
            n = self._sig[(terminal, clase)]
            if n > 999999:
                raise RuntimeError("Se agoto la numeracion de 6 digitos en la terminal %d" % terminal)
            self._sig[(terminal, clase)] = n + 1
            return n


def generar_contenedor(terminal, serie, rng):
    tipo = rng.choice(list(TIPOS_CONTENEDOR))
    refrigerado, veinte_pies = TIPOS_CONTENEDOR[tipo]
    base = "%s%06d" % (PREFIJO_ISO[terminal], serie)
    detalles = []
    for k in range(rng.randint(1, 3)):
        partida = rng.choice(PARTIDAS_REFRIGERADAS) if refrigerado else rng.choice(PARTIDAS_SECAS)
        detalles.append({
            "id_partida_arancelaria": partida,
            "descripcion": "Carga generada %06d-%d" % (serie, k + 1),
            "cantidad": rng.randint(1, 500),
            "peso_kg": round(rng.uniform(200, 5200), 2),      # 3 lineas <= 15 600 kg: nunca hay sobrepeso
            "valor_declarado": round(rng.uniform(500, 50000), 2),
        })
    return {
        "numero_iso": base + str(serie % 10),
        "id_tipo_contenedor": tipo,
        "requiere_refrigeracion": refrigerado,
        "temperatura_c": rng.choice(TEMPERATURAS) if refrigerado else None,
        "id_estado_contenedor": rng.choice((1, 2, 3)),          # el procedimiento solo acepta 1, 2 o 3
        "tara_kg": round(rng.uniform(2200, 2450) if veinte_pies else rng.uniform(3800, 4100), 2),
        "peso_max_kg": 30480 if veinte_pies else 32500,
        "detalles": detalles,
    }


def generar_manifiesto(terminal, contadores, rng, imos, licencias):
    """Argumentos de sp_ingresar_manifiesto (sin el INOUT final)."""
    numero = contadores.siguiente(terminal, "m")
    contenedores = [generar_contenedor(terminal, contadores.siguiente(terminal, "i"), rng)
                    for _ in range(rng.randint(1, 4))]
    return (terminal, rng.choice(imos), rng.choice(licencias), "MAN-T%d-%06d" % (terminal, numero),
            rng.choice(PUERTOS_ORIGEN), datetime.now(timezone.utc), json.dumps(contenedores))


# --------------------------------------------------------------------------------------
# Contexto compartido: registro, conteos, episodios de caida
# --------------------------------------------------------------------------------------
class Contexto:
    def __init__(self, args, dsn, mezcla, escritor, archivo):
        self.args, self.dsn, self.mezcla = args, dsn, mezcla
        self.escritor, self.archivo = escritor, archivo
        self.parar = threading.Event()
        self.lock = threading.Lock()
        self.cuenta = Counter()                    # (terminal, resultado)
        self.por_operacion = Counter()             # (operacion, resultado)
        self.caida_desde = {}                      # terminal -> instante del primer fallo
        self.episodios = defaultdict(list)         # terminal -> [(inicio, fin)]
        self.restantes = args.total
        self.contadores = Contadores()
        self.datos = {}                            # terminal -> {"imos", "licencias", "agentes"}
        self.t0 = time.time()

    def conectar(self, terminal):
        return psycopg2.connect(**self.dsn[terminal])

    def tomar_operacion(self):
        if self.parar.is_set():
            return False
        if self.restantes is None:
            return True
        with self.lock:
            if self.restantes <= 0:
                return False
            self.restantes -= 1
            return True

    def registrar(self, hilo, terminal, operacion, intento, resultado, sqlstate, ms, id_generado, detalle):
        ahora = time.time()
        with self.lock:
            self.cuenta[(terminal, resultado)] += 1
            self.por_operacion[(operacion, resultado)] += 1
            if resultado == "FALLO_CONEXION":
                self.caida_desde.setdefault(terminal, ahora)
            elif resultado in RESULTADOS_EXITO and terminal in self.caida_desde:
                self.episodios[terminal].append((self.caida_desde.pop(terminal), ahora))
            self.escritor.writerow([datetime.fromtimestamp(ahora).isoformat(timespec="milliseconds"),
                                    hilo, terminal, operacion, intento, resultado, sqlstate,
                                    "%.1f" % ms, id_generado if id_generado is not None else "", detalle])
            self.archivo.flush()


# --------------------------------------------------------------------------------------
# Operaciones
# --------------------------------------------------------------------------------------
def _candidato(cur, estados):
    cur.execute(SQL_CANDIDATO, (list(estados),))
    fila = cur.fetchone()
    return fila[0] if fila else None


def ejecutar(conn, operacion, datos, rng, args_ingreso):
    """Una operacion completa en una transaccion. Devuelve (resultado, id_generado, detalle)."""
    cur = conn.cursor()
    try:
        if operacion == "ingresar":
            cur.execute(SQL_INGRESAR, args_ingreso)
            id_gen = cur.fetchone()[0]
            conn.commit()
            return "OK", id_gen, args_ingreso[3]

        estados = {"despachar": ESTADOS_ACTIVOS, "retener": ESTADOS_ACTIVOS,
                   "revisar": ESTADOS_REVISION, "liberar": (ESTADO_RETENIDO,)}[operacion]
        contenedor = _candidato(cur, estados)       # la fila queda bloqueada hasta el commit
        if contenedor is None:
            conn.rollback()
            return "SIN_CANDIDATO", None, operacion

        if operacion == "despachar":
            cur.execute(SQL_DESPACHAR, (contenedor, rng.choice(datos["licencias"]),
                                        "Despacho generado por prueba de carga"))
            id_gen = cur.fetchone()[0]
        else:
            tipo, resultado = {"retener": (3, "RETENIDO"), "liberar": (4, "AUTORIZADO"),
                               "revisar": (2, "CONFORME")}[operacion]
            cur.execute(SQL_INSPECCION, (contenedor, tipo, rng.choice(datos["agentes"]), resultado,
                                         "%s generado por prueba de carga" % operacion))
            id_gen = cur.fetchone()[0]
        conn.commit()
        return "OK", id_gen, "contenedor %s" % contenedor
    finally:
        cur.close()


def _rollback(conn):
    try:
        if conn is not None and not getattr(conn, "closed", 0):
            conn.rollback()
    except Exception:
        pass


def _cerrar(conn):
    try:
        if conn is not None:
            conn.close()
    except Exception:
        pass


def hilo_trabajo(numero, terminal, ctx):
    a = ctx.args
    rng = random.Random(a.semilla * 1000 + numero) if a.semilla is not None else random.Random()
    datos = ctx.datos[terminal]
    operaciones, pesos = zip(*ctx.mezcla.items())
    conn = None
    while ctx.tomar_operacion():
        operacion = rng.choices(operaciones, weights=pesos)[0]
        args_ingreso = (generar_manifiesto(terminal, ctx.contadores, rng, datos["imos"], datos["licencias"])
                        if operacion == "ingresar" else None)    # se genera UNA vez: los reintentos repiten el mismo manifiesto
        inicio_op = time.monotonic()
        intento, incierto = 0, False
        while True:
            intento += 1
            t_ini = time.perf_counter()
            try:
                if conn is None or getattr(conn, "closed", 0):
                    conn = ctx.conectar(terminal)
                resultado, id_gen, detalle = ejecutar(conn, operacion, datos, rng, args_ingreso)
                ctx.registrar(numero, terminal, operacion, intento, resultado, "",
                              (time.perf_counter() - t_ini) * 1000, id_gen, detalle)
                if resultado == "SIN_CANDIDATO":
                    time.sleep(0.2)
                break
            except Exception as exc:        # noqa: BLE001 - se clasifica abajo
                ms = (time.perf_counter() - t_ini) * 1000
                _rollback(conn)
                tipo, codigo, detalle = clasificar(exc), getattr(exc, "pgcode", None) or "", resumen_error(exc)
                agotado = ctx.parar.is_set() or (time.monotonic() - inicio_op) > a.espera_max
                if tipo == "REINTENTAR":
                    ctx.registrar(numero, terminal, operacion, intento, "REINTENTO", codigo, ms, None, detalle)
                    if agotado:
                        ctx.registrar(numero, terminal, operacion, intento, "DESCARTADA", codigo, ms, None, detalle)
                        break
                    time.sleep(min(0.05 * intento, 0.5))
                    continue
                if tipo == "RECONECTAR":
                    incierto = True             # puede haberse confirmado antes de perder la conexion
                    _cerrar(conn)
                    conn = None
                    ctx.registrar(numero, terminal, operacion, intento, "FALLO_CONEXION", codigo, ms, None, detalle)
                    if agotado:
                        ctx.registrar(numero, terminal, operacion, intento, "DESCARTADA", codigo, ms, None, detalle)
                        break
                    time.sleep(min(0.5 * intento, 3.0))
                    continue
                if tipo == "DUPLICADO" and operacion == "ingresar" and incierto:
                    # el numero de manifiesto es unico por construccion: el duplicado es nuestro intento anterior
                    ctx.registrar(numero, terminal, operacion, intento, "OK_VERIFICADO", codigo, ms, None, args_ingreso[3])
                    break
                resultado = "RECHAZADA" if tipo in ("NEGOCIO", "DUPLICADO") else "ERROR_OTRO"
                ctx.registrar(numero, terminal, operacion, intento, resultado, codigo, ms, None, detalle)
                break
    _cerrar(conn)


# --------------------------------------------------------------------------------------
# Configuracion
# --------------------------------------------------------------------------------------
def cargar_enrutamiento(ruta):
    with open(ruta, encoding="utf-8") as f:
        enr = json.load(f)
    if not enr.get("terminales"):
        raise ValueError("El archivo de enrutamiento no define 'terminales'")
    return enr


def construir_dsn(enr, terminal, usuario, clave, usar_rls):
    nodos = enr["terminales"][str(terminal)]["nodos"]
    partes = [n.rsplit(":", 1) for n in nodos]
    opciones = "-c statement_timeout=15000"
    if usar_rls:
        opciones += " -c app.terminal_asignada=%d" % terminal       # lo usa la politica RLS de ManifiestoCarga
    dsn = dict(host=",".join(p[0] for p in partes), port=",".join(p[1] for p in partes),
               dbname=enr.get("base_datos", "puerto"), user=usuario,
               target_session_attrs="read-write", connect_timeout=3,
               keepalives=1, keepalives_idle=5, keepalives_interval=2, keepalives_count=3,
               tcp_user_timeout=8000, application_name="generador_T%d" % terminal, options=opciones)
    if clave:
        dsn["password"] = clave
    return dsn


def parsear_mezcla(texto):
    mezcla = {}
    for par in texto.split(","):
        nombre, peso = par.split("=")
        nombre = nombre.strip()
        if nombre not in ("ingresar", "despachar", "retener", "liberar", "revisar"):
            raise ValueError("Operacion desconocida en --mezcla: %s" % nombre)
        if float(peso) > 0:
            mezcla[nombre] = float(peso)
    if not mezcla:
        raise ValueError("--mezcla no tiene operaciones con peso > 0")
    return mezcla


def repartir_hilos(total, terminales, pesos):
    suma = sum(pesos[t] for t in terminales)
    return {t: max(1, round(total * pesos[t] / suma)) for t in terminales if pesos[t] > 0}


def clave_desde_entorno(usuario):
    for nombre in ("GEN_CLAVE", "OPERADOR_PASS") + (("POSTGRES_PASSWORD",) if usuario == "postgres" else ()):
        if os.environ.get(nombre):
            return os.environ[nombre]
    return None


def cargar_datos_terminal(ctx, terminal):
    """Catalogos y numeracion de partida, leidos del nodo de la terminal (reintenta hasta --espera-max)."""
    limite = time.monotonic() + ctx.args.espera_max
    while True:
        try:
            conn = ctx.conectar(terminal)
            break
        except Exception as exc:            # noqa: BLE001
            if time.monotonic() > limite:
                raise RuntimeError("No se pudo conectar a la terminal %d: %s" % (terminal, resumen_error(exc)))
            time.sleep(1)
    try:
        cur = conn.cursor()
        cur.execute('SELECT "CT_NumeroImo" FROM puerto."Buque"')
        imos = [f[0].strip() for f in cur.fetchall()]
        cur.execute('SELECT "CI_IdAgenteAduanero", "CT_CodigoLicencia" FROM puerto."AgenteAduanero" WHERE "CB_Activo"')
        filas = cur.fetchall()
        cur.execute("""SELECT COALESCE(max(substring("CT_NumeroManifiesto" from '[0-9]+$')::int), 0)
                         FROM puerto."ManifiestoCarga" """)
        ult_m = cur.fetchone()[0]
        cur.execute("""SELECT COALESCE(max(substring("CT_NumeroIso" from 5 for 6)::int), 0)
                         FROM puerto."Contenedor" """)
        ult_i = cur.fetchone()[0]
        conn.rollback()
    finally:
        conn.close()
    if not imos or not filas:
        raise RuntimeError("La terminal %d no tiene buques o agentes activos: cargue los datos primero" % terminal)
    ctx.datos[terminal] = {"imos": imos, "agentes": [f[0] for f in filas], "licencias": [f[1] for f in filas]}
    ctx.contadores.iniciar(terminal, ult_m, ult_i)


def mostrar_ejemplo(enr, terminales, usuario, clave, a, mezcla, hilos):
    print("Enrutamiento:", a.enrutamiento)
    for t in terminales:
        d = dict(construir_dsn(enr, t, usuario, clave, not a.sin_rls))
        if "password" in d:
            d["password"] = "********"
        print("  Terminal %d (%s) hilos=%s: %s" % (t, NOMBRE_TERMINAL.get(t, "?"), hilos.get(t, 0), d))
    print("Mezcla de operaciones:", mezcla)
    c, rng = Contadores(), random.Random(1)
    c.iniciar(1, 300, 1800)
    args = generar_manifiesto(1, c, rng, ["9000031"], ["AA-00001"])
    print("\nEjemplo de llamada (parametros 1 a 7; el 8.o es el INOUT del identificador generado):")
    print(SQL_INGRESAR)
    print(json.dumps({"p_id_terminal": args[0], "p_numero_imo": args[1], "p_licencia_agente": args[2],
                      "p_numero_manifiesto": args[3], "p_puerto_origen": args[4],
                      "p_fecha_arribo": args[5].isoformat(), "p_contenedores": json.loads(args[6])},
                     indent=2, ensure_ascii=False))
    print("\nOtras sentencias:\n ", SQL_DESPACHAR, "\n ", SQL_CANDIDATO, "\n ", SQL_INSPECCION)


def imprimir_resumen(ctx, terminales, duracion, ruta_log):
    columnas = ["OK", "OK_VERIFICADO", "RECHAZADA", "REINTENTO", "FALLO_CONEXION", "DESCARTADA",
                "ERROR_OTRO", "SIN_CANDIDATO"]
    print("\n=== RESUMEN (%.1f s) ===" % duracion)
    print("%-9s" % "terminal" + "".join("%15s" % c for c in columnas))
    for t in terminales:
        print("%-9s" % NOMBRE_TERMINAL.get(t, t) + "".join("%15d" % ctx.cuenta[(t, c)] for c in columnas))
    exitos = sum(ctx.cuenta[(t, c)] for t in terminales for c in RESULTADOS_EXITO)
    print("\nEscrituras confirmadas: %d (%.1f por segundo)" % (exitos, exitos / duracion if duracion else 0))
    print("Por operacion (confirmadas):",
          {op: ctx.por_operacion[(op, "OK")] + ctx.por_operacion[(op, "OK_VERIFICADO")] for op in ctx.mezcla})
    hubo = False
    for t in terminales:
        for ini, fin in ctx.episodios[t]:
            hubo = True
            print("Terminal %s: caida detectada %s -> primera escritura OK %s (%.1f s)" % (
                NOMBRE_TERMINAL.get(t, t), datetime.fromtimestamp(ini).strftime("%H:%M:%S"),
                datetime.fromtimestamp(fin).strftime("%H:%M:%S"), fin - ini))
        if t in ctx.caida_desde:
            hubo = True
            print("Terminal %s: caida detectada %s y SIN recuperacion al terminar" % (
                NOMBRE_TERMINAL.get(t, t), datetime.fromtimestamp(ctx.caida_desde[t]).strftime("%H:%M:%S")))
    if not hubo:
        print("No se detectaron caidas de conexion.")
    print("Registro detallado:", ruta_log)
    print("Compare las 'Escrituras confirmadas' con el conteo de filas en el nodo tras el failover.")


def main(argv=None):
    p = argparse.ArgumentParser(description="Generador de carga concurrente para la prueba de estres")
    p.add_argument("--enrutamiento", default=str(ENRUTAMIENTO_DEFECTO), help="JSON del Rol 2 (infra/enrutamiento.json)")
    p.add_argument("--usuario", default=os.environ.get("GEN_USUARIO", "operador_user"))
    p.add_argument("--hilos", type=int, default=6, help="hilos en total, repartidos segun --pesos")
    p.add_argument("--pesos", default="3,2,1", help="peso de las terminales 1,2,3 (reparto de hilos)")
    p.add_argument("--duracion", type=float, default=None, help="segundos (por defecto 60 si no se da --total)")
    p.add_argument("--total", type=int, default=None, help="operaciones totales (alternativa a --duracion)")
    p.add_argument("--mezcla", default=MEZCLA_DEFECTO)
    p.add_argument("--espera-max", dest="espera_max", type=float, default=90.0,
                   help="segundos que se insiste en una operacion antes de descartarla")
    p.add_argument("--semilla", type=int, default=None)
    p.add_argument("--log", default=None)
    p.add_argument("--sin-rls", dest="sin_rls", action="store_true", help="no fijar app.terminal_asignada")
    p.add_argument("--solo-ejemplo", dest="solo_ejemplo", action="store_true")
    a = p.parse_args(argv)

    enr = cargar_enrutamiento(a.enrutamiento)
    terminales = sorted(int(k) for k in enr["terminales"])
    pesos = dict(zip(terminales, [float(x) for x in a.pesos.split(",")]))
    mezcla = parsear_mezcla(a.mezcla)
    hilos = repartir_hilos(a.hilos, terminales, pesos)
    terminales = [t for t in terminales if t in hilos]
    clave = clave_desde_entorno(a.usuario)
    if a.total is None and a.duracion is None:
        a.duracion = 60.0

    if a.solo_ejemplo:
        mostrar_ejemplo(enr, terminales, a.usuario, clave, a, mezcla, hilos)
        return 0
    if psycopg2 is None:
        print("Falta el driver: pip install -r requirements.txt", file=sys.stderr)
        return 2

    ruta_log = a.log or str(RAIZ / "pruebas" / ("log_generador_%s.csv" % datetime.now().strftime("%Y%m%d_%H%M%S")))
    with open(ruta_log, "w", newline="", encoding="utf-8") as archivo:
        escritor = csv.writer(archivo)
        escritor.writerow(["timestamp", "hilo", "terminal", "operacion", "intento", "resultado",
                           "sqlstate", "ms", "id_generado", "detalle"])
        dsn = {t: construir_dsn(enr, t, a.usuario, clave, not a.sin_rls) for t in terminales}
        ctx = Contexto(a, dsn, mezcla, escritor, archivo)
        signal.signal(signal.SIGINT, lambda *_: ctx.parar.set())
        try:
            for t in terminales:
                cargar_datos_terminal(ctx, t)
        except RuntimeError as exc:
            print("ERROR:", exc, file=sys.stderr)
            return 1

        print("Generador iniciado: hilos=%s mezcla=%s log=%s" % (hilos, mezcla, ruta_log))
        trabajadores, n = [], 0
        for t in terminales:
            for _ in range(hilos[t]):
                n += 1
                th = threading.Thread(target=hilo_trabajo, args=(n, t, ctx), daemon=True)
                th.start()
                trabajadores.append(th)

        ctx.t0 = time.time()
        siguiente_aviso = ctx.t0 + 5
        while any(th.is_alive() for th in trabajadores) and not ctx.parar.is_set():
            time.sleep(0.2)
            ahora = time.time()
            if a.duracion is not None and ahora - ctx.t0 >= a.duracion:
                ctx.parar.set()
            if ahora >= siguiente_aviso:
                siguiente_aviso += 5
                ok = {t: ctx.cuenta[(t, "OK")] + ctx.cuenta[(t, "OK_VERIFICADO")] for t in terminales}
                fallos = {t: ctx.cuenta[(t, "FALLO_CONEXION")] for t in terminales}
                print("[%5.0fs] OK=%s FALLO_CONEXION=%s" % (ahora - ctx.t0, ok, fallos))
        ctx.parar.set()
        for th in trabajadores:
            th.join(timeout=a.espera_max + 5)
        imprimir_resumen(ctx, terminales, time.time() - ctx.t0, ruta_log)
    return 0


if __name__ == "__main__":
    sys.exit(main())
