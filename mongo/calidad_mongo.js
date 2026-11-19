/* ════════════════════════════════════════════════════════════════════
   PARTE 1 · Exploración de calidad y cumplimiento — MongoDB clinica_bi
   Ejecutar:  mongosh clinica_bi --quiet --file mongo/calidad_mongo.js
   Cada problema (Q##) imprime cuántos documentos afecta y la regla del
   ETL que lo resuelve. Las cifras de Mongo son iguales para todos los grupos.
   ════════════════════════════════════════════════════════════════════ */
const P = db.perfiles_pacientes, I = db.interacciones_campanas, C = db.campanas;
const OFICIALES = ["Consulta externa","Laboratorio clínico","Imágenes diagnósticas",
                   "Odontología","Promoción y prevención","Cirugía ambulatoria"];
const show = (id, desc, n, regla) => print(`${id} | ${desc} | ${JSON.stringify(n)} | ${regla}`);
print("ID | Problema | Afectados | Regla ETL");

/* ── perfiles_pacientes ─────────────────────────────────────────── */
show("Q01","perfiles: pacienteId guardado como texto",
  P.countDocuments({ pacienteId: { $type: "string" } }), "T11 → entero");

// Solo se detectan bien después de convertir a entero (5 casos mezclan "123" y 123)
show("Q02","perfiles: pacientes con más de un perfil (pacientes / documentos)",
  P.aggregate([{ $group: { _id: { $toInt: "$pacienteId" }, n: { $sum: 1 } } },
               { $match: { n: { $gt: 1 } } },
               { $group: { _id: null, pacientes: { $sum: 1 }, docs: { $sum: "$n" } } },
               { $project: { _id: 0 } }]).toArray(), "T12 → perfil con fechaActualizacion más reciente");

show("Q03","perfiles: lineasInteres con valores no oficiales (docs)",
  P.countDocuments({ lineasInteres: { $elemMatch: { $nin: OFICIALES } } }), "T13 → tabla de equivalencias");
show("Q03b","perfiles: variantes distintas de lineasInteres no oficiales",
  P.distinct("lineasInteres").filter(x => !OFICIALES.includes(x)).length, "T13");

show("Q04","perfiles: sin programaRiesgo",
  P.countDocuments({ programaRiesgo: { $exists: false } }), "T14 → 'Sin programa' / 'No aplica'");
show("Q05","perfiles: nivelRiesgo con mayúsculas/minúsculas inconsistentes",
  P.countDocuments({ "programaRiesgo.nivelRiesgo": { $exists: true, $nin: ["Alto","Medio","Bajo"] } }), "T14 → Alto/Medio/Bajo");
show("Q06","perfiles: adherencia como texto '85%' o decimal 0.85",
  P.countDocuments({ "programaRiesgo.adherencia": { $type: ["string","double"] } }), "T14 → entero 0-100");
show("Q07","perfiles: consentimientos como texto 'SI'/'NO'",
  P.countDocuments({ $or: [{ "consentimientos.email": { $type: "string" } },
                           { "consentimientos.sms": { $type: "string" } },
                           { "consentimientos.whatsapp": { $type: "string" } }] }), "T14 → 1/0");
show("Q08","perfiles: sin encuestasSatisfaccion",
  P.countDocuments({ encuestasSatisfaccion: { $exists: false } }), "T15 → NPS NULL, TipoNPS 'Sin encuesta'");
show("Q09","perfiles: encuestas con puntaje como texto (respuestas)",
  P.aggregate([{ $unwind: "$encuestasSatisfaccion" },
               { $match: { "encuestasSatisfaccion.puntaje": { $type: "string" } } },
               { $count: "n" }]).toArray(), "T15 → entero");

/* ── interacciones_campanas ─────────────────────────────────────── */
show("Q10","interacciones: duplicados exactos (copias sobrantes)",
  I.aggregate([{ $group: { _id: { p: "$pacienteId", c: "$campanaId", ca: "$canal", d: "$dispositivo",
                                  e: "$eventos", ci: "$citaAgendada" }, n: { $sum: 1 } } },
               { $match: { n: { $gt: 1 } } },
               { $group: { _id: null, sobrantes: { $sum: { $subtract: ["$n", 1] } } } },
               { $project: { _id: 0 } }], { allowDiskUse: true }).toArray(), "T16 → eliminar");
show("Q11","interacciones: canal fuera de email/sms/whatsapp/app",
  I.countDocuments({ canal: { $nin: ["email","sms","whatsapp","app"] } }), "T16 → estandarizar");
show("Q11b","interacciones: variantes de canal",
  I.distinct("canal"), "T16");
show("Q12","interacciones: campanaId con espacios o minúsculas",
  I.countDocuments({ campanaId: { $not: /^CMP-\d{4}-\d{2}$/ } }), "T16 → TRIM + UPPER");
show("Q13","interacciones: documentos con fechas de evento en texto dd/mm/aaaa hh:mm",
  I.countDocuments({ "eventos.fecha": { $type: "string" } }), "T18 → convertir (UTC)");
show("Q14","interacciones: pacienteId que no existe en el OLTP (> 6000)",
  I.countDocuments({ pacienteId: { $gt: 6000 } }), "T19 → PacienteKey -1");
show("Q15","interacciones: citaAgendada ausente (solo existe si hubo clic)",
  I.countDocuments({ citaAgendada: { $exists: false } }), "T17 → CitaAgendada 0");
show("Q16","interacciones: canal app sin evento 'enviado' (solo impresión)",
  I.countDocuments({ canal: { $in: ["app","App","APP","push"] }, "eventos.tipo": { $ne: "enviado" } }), "T17 → Enviado 0, Impresion 1");
show("Q17","interacciones: abierto y leido son dos tipos para la misma métrica",
  I.countDocuments({ "eventos.tipo": { $in: ["abierto","leido"] } }), "T17 → Abierto = abierto o leido");

/* ── campanas ───────────────────────────────────────────────────── */
show("Q18","campanas: presupuesto como texto ('9.200.000', '$22.500.000')",
  C.find({ presupuesto: { $type: "string" } }, { presupuesto: 1 }).toArray(), "T20 → número");
show("Q19","campanas: responsable faltante o vacío",
  C.countDocuments({ $or: [{ responsable: { $exists: false } }, { responsable: "" }] }), "T20 → 'Sin asignar'");
show("Q20","campanas: lineasPromocionadas no estandarizadas",
  C.countDocuments({ lineasPromocionadas: { $elemMatch: { $nin: OFICIALES } } }), "T20 + T13");
show("Q21","campanas: sin segmentoObjetivo (campaña abierta) / sin sexo en el segmento",
  [C.countDocuments({ segmentoObjetivo: { $exists: false } }),
   C.countDocuments({ segmentoObjetivo: { $exists: true }, "segmentoObjetivo.sexo": { $exists: false } })],
  "T20 → SexoObjetivo 'Todos', EdadMin/Max NULL");
show("Q22","campanas: sin codigoBeneficio",
  C.countDocuments({ codigoBeneficio: { $exists: false } }), "T20 → 'Sin código'");

/* ════════════════════════════════════════════════════════════════════
   HALLAZGO DE CUMPLIMIENTO 1 · Envíos por canal no autorizado (Ley 1581/2012)
   Perfil vigente = el más reciente del paciente (T11 + T12). App no requiere
   autorización. Paciente sin perfil = sin autorización registrada.
   (Cuenta antes de quitar duplicados de T16; la cifra final sale del DW.)
   ════════════════════════════════════════════════════════════════════ */
P.createIndex({ pacienteId: 1 });   // solo acelera el $lookup; no cambia datos
const lc = { $toLower: { $trim: { input: "$canal" } } };
const canalStd = { $switch: { branches: [
  { case: { $in: [lc, ["email","e-mail","correo"]] }, then: "email" },
  { case: { $eq:  [lc, "sms"] }, then: "sms" },
  { case: { $in: [lc, ["whatsapp","wa"]] }, then: "whatsapp" },
  { case: { $in: [lc, ["app","push"]] }, then: "app" }], default: "?" } };
const autoriza = v => ({ $in: [v, [true, "SI"]] });
print("\nCUMPLIMIENTO 1 · envíos por canal no autorizado");
I.aggregate([
  { $set: { canalStd: canalStd, pidStr: { $toString: "$pacienteId" } } },
  { $match: { canalStd: { $ne: "app" } } },
  { $lookup: { from: "perfiles_pacientes", localField: "pacienteId", foreignField: "pacienteId", as: "p1" } },
  { $lookup: { from: "perfiles_pacientes", localField: "pidStr",     foreignField: "pacienteId", as: "p2" } },
  { $set: { pf: { $first: { $sortArray: { input: { $concatArrays: ["$p1","$p2"] }, sortBy: { fechaActualizacion: -1 } } } } } },
  { $set: { estado: { $cond: [{ $eq: [{ $type: "$pf" }, "missing"] }, "Sin perfil",
      { $cond: [autoriza({ $switch: { branches: [
          { case: { $eq: ["$canalStd","email"] }, then: "$pf.consentimientos.email" },
          { case: { $eq: ["$canalStd","sms"] },   then: "$pf.consentimientos.sms" }],
          default: "$pf.consentimientos.whatsapp" } }), "Autorizado", "NO autorizado"] }] } } },
  { $group: { _id: { estado: "$estado", canal: "$canalStd" }, envios: { $sum: 1 } } },
  { $sort: { "_id.estado": 1, "_id.canal": 1 } }
]).forEach(x => print(JSON.stringify(x)));

/* HALLAZGO DE CUMPLIMIENTO 2 · Envíos fuera de segmentoObjetivo (edad o sexo)
   Requiere sexo y fecha de nacimiento del OLTP, así que se calcula en SQL sobre
   stg (ver sql/07_Validacion.sql, reporte de cumplimiento). Aquí: campañas dirigidas. */
print("\nCUMPLIMIENTO 2 · campañas con segmentoObjetivo (se cruzan con el OLTP en SQL)");
C.find({ segmentoObjetivo: { $exists: true } }, { nombre: 1, segmentoObjetivo: 1 })
 .forEach(c => print(c._id, c.nombre, JSON.stringify(c.segmentoObjetivo)));
