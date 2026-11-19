"""Ejecuta un .sql con lotes separados por GO (alternativa a sqlcmd). Uso: python tools/ejecutar_sql.py archivo.sql"""
import pyodbc, re, sys

def run(path, server=r"localhost\SQLEXPRESS"):
    sql = open(path, encoding="utf-8-sig").read()
    batches = [b for b in re.split(r"^\s*GO\s*;?\s*$", sql, flags=re.M | re.I) if b.strip()]
    cn = pyodbc.connect(f"DRIVER={{SQL Server}};SERVER={server};Trusted_Connection=yes;", autocommit=True)
    cur = cn.cursor()
    for b in batches:
        cur.execute(b)
        while True:
            if cur.description:
                cols = [d[0] for d in cur.description]
                print(" | ".join(cols))
                for r in cur.fetchall():
                    print(" | ".join(str(x) for x in r))
                print()
            if not cur.nextset():
                break

if __name__ == "__main__":
    run(sys.argv[1])
