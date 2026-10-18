#!/usr/bin/env python3
"""Carga concurrente con reintento. Uso: PGPASSWORD=postgres python3 estres.py <nodo> <hilos> <segundos>
Conexion multi-host: libpq prueba primario y standby y se queda con el que acepta escrituras."""
import sys, time, random, threading, psycopg2
nodo, hilos, dur = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
import os
HOSTS = os.environ.get("PGHOSTS", "localhost,localhost"); PORTS = f"544{nodo},545{nodo}"   # Docker: puertos publicados del host
DSN = f"host={HOSTS} port={PORTS} dbname=puerto user=postgres target_session_attrs=read-write connect_timeout=3"
base = nodo * 10**9
acked, errores, lock = [], [], threading.Lock()
caidas = []
def worker(t):
    conn = None; fin = time.time() + dur; sin_servicio = None
    while time.time() < fin:
        try:
            if conn is None or conn.closed:
                conn = psycopg2.connect(DSN); conn.autocommit = False
                if sin_servicio:
                    with lock: caidas.append(time.time() - sin_servicio)
                    sin_servicio = None
            cur = conn.cursor()
            cur.execute("""INSERT INTO puerto.inspeccion_transito
                (id_contenedor,id_tipo_inspeccion,id_agente_aduanero,resultado,observaciones)
                VALUES (%s,%s,%s,'CONFORME',%s) RETURNING id_inspeccion_transito""",
                (base + 1 + random.randrange(100), 1 + random.randrange(5), 1 + random.randrange(30), f"estres hilo {t}"))
            rid = cur.fetchone()[0]; conn.commit()          # solo cuenta como confirmada tras COMMIT
            with lock: acked.append(rid)
        except psycopg2.Error as e:
            if sin_servicio is None: sin_servicio = time.time()
            with lock: errores.append(type(e).__name__)
            try: conn.close()
            except Exception: pass
            conn = None; time.sleep(0.2)
ths = [threading.Thread(target=worker, args=(i,)) for i in range(hilos)]
t0 = time.time(); [t.start() for t in ths]; [t.join() for t in ths]
open(f"acked_n{nodo}.txt", "w").write("\n".join(map(str, acked)))
print(f"confirmadas={len(acked)} errores={len(errores)} ({set(errores)}) tps={len(acked)/(time.time()-t0):.0f}")
print("ventana sin servicio por hilo (s):", [round(c,1) for c in caidas])
