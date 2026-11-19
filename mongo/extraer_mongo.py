"""
EXTRACCIÓN MongoDB (clinica_bi) → SQL Server (CLINICABI_DW_Grupo1.stg)

Método elegido: script de Python con pymongo + pyodbc.
Por qué:
  - Reproducible con un solo comando y sin pasos manuales (no hay archivos
    intermedios ni rutas que BULK INSERT deba poder leer desde el servicio SQL).
  - Lee directo de la base viva, así que siempre extrae el estado actual.
  - Extrae CRUDO: cada documento se guarda completo como JSON (sin _id) en una
    fila de stg. No se corrige nada aquí: todas las transformaciones T11–T20
    se hacen en T-SQL (sql/04_ETL_Mongo_Transform.sql), donde se pueden auditar.
  - Es re-ejecutable: vacía la tabla stg antes de cargar (TRUNCATE).

Uso:
  pip install -r mongo/requirements.txt
  python mongo/extraer_mongo.py            (requiere haber corrido sql/01 y sql/02)

Variables opcionales: MONGO_URI (def. mongodb://localhost:27017),
                      SQL_SERVER (def. localhost\\SQLEXPRESS)
"""
import os
import sys

import pyodbc
from bson import json_util
from bson.json_util import JSONOptions, JSONMode
from pymongo import MongoClient

MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017")
SQL_SERVER = os.getenv("SQL_SERVER", r"localhost\SQLEXPRESS")
SQL_DB = "CLINICABI_DW_Grupo1"
COLECCIONES = ["campanas", "perfiles_pacientes", "interacciones_campanas"]

# JSON relajado: números y textos conservan su tipo original; fechas → {"$date": "AAAA-MM-DDThh:mm:ssZ"}
JSON_OPC = JSONOptions(json_mode=JSONMode.RELAXED, tz_aware=True)


def conexion_sql():
    """Usa ODBC Driver 18 si existe; si no, el driver 'SQL Server' que trae Windows."""
    drivers = pyodbc.drivers()
    if "ODBC Driver 18 for SQL Server" in drivers:
        cs = (f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={SQL_SERVER};DATABASE={SQL_DB};"
              "Trusted_Connection=yes;TrustServerCertificate=yes;")
    else:
        cs = f"DRIVER={{SQL Server}};SERVER={SQL_SERVER};DATABASE={SQL_DB};Trusted_Connection=yes;"
    return pyodbc.connect(cs, autocommit=False)


def main():
    mongo = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)["clinica_bi"]
    cn = conexion_sql()
    cur = cn.cursor()
    cur.fast_executemany = True

    for coll in COLECCIONES:
        tabla = f"stg.mongo_{coll}"
        n_origen = mongo[coll].count_documents({})

        filas = []
        for doc in mongo[coll].find().sort("_id", 1):      # orden estable → resultado repetible
            mongo_id = str(doc.pop("_id"))                 # ObjectId → texto (o el código CMP-…)
            filas.append((mongo_id, json_util.dumps(doc, json_options=JSON_OPC, ensure_ascii=False)))

        cur.execute(f"TRUNCATE TABLE {tabla};")
        cur.setinputsizes([(pyodbc.SQL_VARCHAR, 30, 0), (pyodbc.SQL_WVARCHAR, 0, 0)])
        cur.executemany(f"INSERT INTO {tabla} (MongoId, Doc) VALUES (?, ?);", filas)
        n_stg = cur.execute(f"SELECT COUNT(*) FROM {tabla};").fetchval()

        cur.execute("DELETE FROM stg.ControlCarga WHERE Fuente = N'MongoDB' AND Objeto = ?;", coll)
        cur.execute("INSERT INTO stg.ControlCarga (Fuente, Objeto, FilasOrigen, FilasStg) VALUES (N'MongoDB', ?, ?, ?);",
                    coll, n_origen, n_stg)
        cn.commit()
        print(f"{coll:<25} origen={n_origen:>6}  stg={n_stg:>6}  {'OK' if n_origen == n_stg else 'DIFERENCIA'}")
        if n_origen != n_stg:
            sys.exit(1)

    cn.close()


if __name__ == "__main__":
    main()
