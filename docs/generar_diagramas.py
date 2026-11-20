"""Genera las figuras del documento técnico: arquitectura y modelo estrella.
Uso: python docs/generar_diagramas.py  → docs/img/arquitectura.png, docs/img/modelo_estrella.png"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

OUT = os.path.join(os.path.dirname(__file__), "img")
os.makedirs(OUT, exist_ok=True)
AZUL, AZUL_CL, GRIS, NAR = "#1F4E79", "#DCE8F5", "#F2F2F2", "#F4B183"


def caja(ax, x, y, w, h, titulo, cuerpo="", color=AZUL_CL, borde=AZUL, fs=9):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.08",
                                fc=color, ec=borde, lw=1.4, zorder=2))
    ax.text(x + w / 2, y + h - 0.18, titulo, ha="center", va="top", fontsize=fs, weight="bold", color="#111", zorder=3)
    if cuerpo:
        ax.text(x + w / 2, y + h - 0.5, cuerpo, ha="center", va="top", fontsize=fs - 1.5, color="#222", linespacing=1.3, zorder=3)


def flecha(ax, x1, y1, x2, y2, txt=""):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1), arrowprops=dict(arrowstyle="-|>", lw=1.5, color="#444"))
    if txt:
        ax.text((x1 + x2) / 2, (y1 + y2) / 2 + 0.12, txt, ha="center", fontsize=7, color="#444", style="italic")


# ── Arquitectura ──────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(11, 4.2))
ax.set_xlim(0, 15.4); ax.set_ylim(0, 5.6); ax.axis("off")
caja(ax, 0.1, 3.0, 2.8, 2.3, "SQL Server", "CLINICABI_OLTP\n21 tablas\nPacientes, Atenciones,\nDetalle, Pagos…", GRIS, "#666")
caja(ax, 0.1, 0.3, 2.8, 2.3, "MongoDB", "clinica_bi\ncampanas (24)\nperfiles (5.215)\ninteracciones (36.313)", GRIS, "#666")
caja(ax, 3.9, 0.9, 3.3, 4.4, "Staging (stg)", "02 · stg.oltp_*\ncopia 1:1 del OLTP\n(INSERT…SELECT)\n\nextraer_mongo.py\nstg.mongo_*\nMongoId + Doc JSON crudo\n(pymongo + pyodbc)\n\nstg.ControlCarga\n(conteos por paso)")
caja(ax, 8.2, 0.9, 3.4, 4.4, "Transformación (T-SQL)", "03 Dimensiones T1–T5, T10\n04 Mongo T11–T15, T20\n(OPENJSON)\n05 Hechos T6–T9, T16–T19\n06 Atribución T21\n07 Validación\nReporteCalidad\nReporteCumplimiento")
caja(ax, 12.5, 2.9, 2.8, 2.4, "DW estrella", "CLINICABI_DW_Grupo1\n2 hechos\n10 dimensiones\nmiembro -1", "#C5E0B4", "#385723")
caja(ax, 12.5, 0.3, 2.8, 2.2, "Power BI", "BI_Grupo1.pbix\n3 páginas · 33 medidas\nconectado solo al DW", "#FFE699", "#7F6000")
flecha(ax, 2.9, 4.15, 3.9, 4.15, "sqlcmd")
flecha(ax, 2.9, 1.45, 3.9, 1.45, "Python")
flecha(ax, 7.2, 2.8, 8.2, 2.8)
flecha(ax, 11.6, 4.1, 12.5, 4.1)
flecha(ax, 13.9, 2.9, 13.9, 2.5, "")
ax.text(7.7, 5.45, "run_etl.ps1 orquesta todo desde una base vacía (≈ 15 s, sin intervención)",
        ha="center", fontsize=9, color=AZUL, weight="bold")
plt.tight_layout(); fig.savefig(os.path.join(OUT, "arquitectura.png"), dpi=200); plt.close(fig)

# ── Modelo estrella ───────────────────────────────────────────
fig, ax = plt.subplots(figsize=(11, 6.4))
ax.set_xlim(0, 16); ax.set_ylim(0, 9.4); ax.axis("off")
fa = (4.0, 3.0, 3.6, 3.6)   # FACT_Atenciones
fi = (9.4, 3.0, 3.6, 3.6)   # FACT_InteraccionCampana
caja(ax, *fa, "FACT_Atenciones", "1 fila = servicio de una\natención Realizada\n82.448 filas\n\nCantidad, ValorUnitario,\n%Descuento, CostoUnitario,\nValorBruto/Descuento/Neto,\nCostoTotal, Margen,\nValorPaciente/Aseguradora,\nOrdenExterna, NumeroAtencion,\nMedioPagoPrincipal",
     NAR, "#843C0C", fs=9)
caja(ax, *fi, "FACT_InteraccionCampana", "1 fila = documento único\nde interacciones\n36.073 filas\n\nEnviado, Entregado, Rebotado,\nAbierto, Impresion, Clic,\nBajaSuscripcion, CitaAgendada,\nEnviadoSinConsentimiento,\nFueraDeSegmento,\nHorasHastaApertura",
     NAR, "#843C0C", fs=9)
dims_a = {"DIM_Servicio\n(100)": (0.2, 7.4), "DIM_Sede\n(16)": (0.2, 5.5), "DIM_Profesional\n(348)": (0.2, 3.6),
          "DIM_Aseguradora\n(10)": (0.2, 1.7), "DIM_Diagnostico\n(34)": (2.4, 0.1), "DIM_Modalidad\n(5)": (4.6, 0.1)}
dims_c = {"DIM_Tiempo\n(732 días)": (5.4, 7.8), "DIM_Paciente\n(6.001)": (7.6, 7.8), "DIM_Campana\n(25)": (9.8, 7.8)}
dims_i = {"DIM_CanalContacto\n(5)": (13.8, 4.3)}
W, H = 1.9, 1.15
for nombre, (x, y) in {**dims_a, **dims_c, **dims_i}.items():
    conformada = nombre in dims_c
    caja(ax, x, y, W, H, nombre.split("\n")[0], nombre.split("\n")[1] + ("\nconformada" if conformada else ""),
         "#C5E0B4" if conformada else AZUL_CL, "#385723" if conformada else AZUL, fs=8.5)


def linea(x1, y1, x2, y2, txt=""):
    ax.plot([x1, x2], [y1, y2], color="#555", lw=1.1, zorder=1)
    if txt:
        ax.text(x2, y2 + 0.08, txt, fontsize=7.5, ha="center", color="#555")


cfa = (fa[0] + fa[2] / 2, fa[1] + fa[3] / 2)
cfi = (fi[0] + fi[2] / 2, fi[1] + fi[3] / 2)
for _, (x, y) in dims_a.items():
    linea(x + W / 2, y + H / 2, *cfa)
for _, (x, y) in dims_c.items():
    linea(x + W / 2, y, cfa[0], fa[1] + fa[3])
    linea(x + W / 2, y, cfi[0], fi[1] + fi[3])
for _, (x, y) in dims_i.items():
    linea(x, y + H / 2, fi[0] + fi[2], cfi[1])
# redibujar los hechos encima de las líneas
caja(ax, *fa, "FACT_Atenciones", "1 fila = servicio de una\natención Realizada\n82.448 filas\n\nCantidad, ValorUnitario,\n%Descuento, CostoUnitario,\nValorBruto/Descuento/Neto,\nCostoTotal, Margen,\nValorPaciente/Aseguradora,\nOrdenExterna, NumeroAtencion,\nMedioPagoPrincipal",
     NAR, "#843C0C", fs=9)
caja(ax, *fi, "FACT_InteraccionCampana", "1 fila = documento único\nde interacciones\n36.073 filas\n\nEnviado, Entregado, Rebotado,\nAbierto, Impresion, Clic,\nBajaSuscripcion, CitaAgendada,\nEnviadoSinConsentimiento,\nFueraDeSegmento,\nHorasHastaApertura",
     NAR, "#843C0C", fs=9)
ax.text(8.0, 2.2, "Relaciones N:1 de cada hecho a sus dimensiones, filtro en una dirección.\n"
        "Verde = dimensión conformada (compartida por ambos hechos).\n"
        "FACT_Atenciones → DIM_Campana guarda la campaña atribuida (T21).",
        fontsize=8.5, ha="left", va="top", color="#333")
plt.tight_layout(); fig.savefig(os.path.join(OUT, "modelo_estrella.png"), dpi=200); plt.close(fig)
print("Figuras en", OUT)
