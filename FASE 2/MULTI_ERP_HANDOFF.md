# Barb — Fase multi-ERP: contexto y plan de trabajo

## Objetivo de la fase

Convertir Barb en una plataforma multi-ERP: consumir registros de fallas, OT y activos desde ERP externos (SAP, Oracle, CSV u otros) y dejarlos en un formato único para que la IA prediga fallas y el troubleshooting cruce esos datos con los manuales de las máquinas.

Los conectores los configura **el cliente desde la interfaz**, no el equipo de Barb.

**Restricción principal:** cambios mínimos al funcionamiento y al modelo de datos existentes. Solo se agregan tablas y columnas opcionales (NULL). No se renombra, no se borra, no se cambian tipos ni restricciones existentes sin consultarlo antes.

## Arquitectura acordada

```
ERP (SAP / Oracle / CSV)
   -> Conector (uno por tipo de ERP, interfaz común)
   -> Bronce: INGESTA_CRUDA (payload tal cual llegó)
   -> Plata: tablas existentes de Barb extendidas (MAQUINA, ORDEN_TRABAJO) + EVENTO_FALLA
   -> Oro: vistas / tablas de KPI (MTBF, MTTR, historial por máquina)  [pendiente]
   -> Consumidores: modelo predictivo, dashboards, Debug, DocChat
```

- Cada conector es el único lugar donde vive el conocimiento de su ERP. Todos cumplen el mismo contrato (por ejemplo `extraer_fallas(desde, hasta)`, `extraer_activos()`).
- `MAQUINA` es el activo canónico y `ORDEN_TRABAJO` la OT canónica. Las OT de Barb y las importadas conviven en la misma tabla, diferenciadas por `conector_id` (NULL = creada en Barb).
- Los IDs externos viven en tablas puente (`MAQUINA_ORIGEN`) o en columnas `conector_id` + `id_externo`, nunca reemplazan los IDs de Barb.
- Los códigos de cada ERP se traducen con filas en `MAPEO_CODIGO`, no con código. Un registro sin mapeo va a `RECHAZO_INGESTA`, no se pierde ni entra mal clasificado.
- La carga es idempotente: upsert por `(conector_id, id_externo)` y `hash_origen` para detectar cambios.
- Los manuales siguen su propio camino (RAG existente del DocChat).
- Orquestación: un job programado en Python basta por ahora. Nada de Data Factory ni Airflow en esta etapa.

## Lo que ya está hecho

### `initScripts/02_integracion_erp.sql`

Migración aditiva e idempotente (probada en PostgreSQL 16 sobre `01_tablas.sql`, ejecutada dos veces sin errores ni duplicados).

- **Tablas nuevas:** `CONECTOR_ERP`, `MAQUINA_ORIGEN`, `MODO_FALLA`, `CAUSA_FALLA`, `MAPEO_CODIGO`, `LOTE_INGESTA`, `INGESTA_CRUDA`, `RECHAZO_INGESTA`, `EVENTO_FALLA`.
- **Columnas nuevas (todas NULL):** `MAQUINA` (fabricante, modelo, numero_serie, fecha_puesta_marcha, criticidad A/B/C) y `ORDEN_TRABAJO` (conector_id, id_externo, con índice único parcial).
- **Semillas:** catálogos globales de modos y causas de falla (`empresa_id` NULL = global), tres conectores demo para la empresa 1 (activo, error y pausado), mapeos demo del conector SAP y eventos de falla derivados de las OT correctivas del seed.
- Requiere PostgreSQL 15+ (`UNIQUE NULLS NOT DISTINCT`).

### `frontend/src/components/ConnectorSwitcher.tsx`

Botón pequeño abajo a la derecha del selector de módulos (`Menu.tsx`). Muestra el conector activo y al pincharlo despliega hacia arriba la lista de conectores de la empresa.

- Primera opción "Todas las fuentes" (`conector_id = null`).
- Cada conector muestra tipo, planta y última sincronización; si está en error, el mensaje en rojo. Los conectores en `borrador` aparecen deshabilitados.
- Cierre con clic fuera o Escape, navegación con flechas, modo oscuro.
- "Gestionar conectores" solo si `canManage`.
- **Supuestos por verificar:** `useApp()` expone `api.get` / `api.put`; el contenedor del selector en `Menu.tsx` es `relative`. Sintaxis verificada, pero no se probó contra el código real.

## Decisiones tomadas

- **Selección del conector activo:** se guarda en `USUARIO.preferencias.conector_activo_id` (la columna JSONB ya existe). El backend valida que el conector pertenezca a la empresa del usuario.
- **Credenciales de los ERP:** el backend las cifra antes de guardarlas en `CONECTOR_ERP.credenciales_cifradas`, con una llave en variable de entorno (por ejemplo `CONNECTOR_ENCRYPTION_KEY`, con Fernet). El backend **nunca** devuelve credenciales al frontend; solo un booleano `tiene_credenciales`.
- **OT importadas:** `ORDEN_TRABAJO.tecnico_id` y `creado_por` son NOT NULL. Para no tocar el modelo, al crear un conector el backend crea un usuario de integración por empresa, inactivo (no puede iniciar sesión), y lo usa en ambos campos.
- **Permisos por rol:**
  - Administrador: seleccionar, crear, editar, eliminar, configurar credenciales.
  - Gerente: seleccionar y lanzar sincronización manual.
  - Técnico y Visualizador: solo seleccionar (es una preferencia de vista, no modifica datos).
  - Los permisos se definen en `permisos.py` y se reflejan en `utils/permissions.ts`.

## Tareas pendientes (en este orden)

1. **Ejecutar la migración.** Hoy `main.py` solo ejecuta `01_tablas.sql`, y `/api/force-reset-db` hace `DROP SCHEMA public`, lo que también borraría las tablas nuevas. Cambiar `main.py` para que ejecute todos los `.sql` de `initScripts/` en orden alfabético, tanto en el auto-seeding como en el reset. La 02 es idempotente, así que puede correr en cada arranque.
   - Criterio: base limpia y base existente terminan con las tablas nuevas; reiniciar el backend no falla ni duplica semillas.
2. **Integrar `ConnectorSwitcher`.** Ajustarlo a la firma real de `services/api.ts`, `AppContext.tsx` y `utils/permissions.ts`, y montarlo en `Menu.tsx`. Textos a `i18n.ts` (ES/EN).
   - Criterio: `npm run build` sin errores de TypeScript; el botón se ve en claro y oscuro y en móvil.
3. **Endpoints de lectura y selección.**
   - `GET /api/connectors` -> `{ conectores: [...], activo_id }`, filtrado por la empresa del usuario, sin credenciales.
   - `PUT /api/connectors/active` <- `{ conector_id | null }`, valida pertenencia a la empresa y guarda en `preferencias`.
   - Registrar ambas acciones en `SYSTEM_AUDIT_LOG` siguiendo el patrón existente.
4. **CRUD de conectores (solo admin):** crear, editar, pausar, eliminar, cifrado de credenciales, creación del usuario de integración y un endpoint "probar conexión".
5. **Pantalla "Gestionar conectores"** en el frontend, a la que lleva el botón del selector.
6. **Primer conector real:** empezar por CSV o por una API simulada que imite SAP PM, cargando bronce -> `EVENTO_FALLA` con rechazos y lotes.
7. **Capa oro:** vistas de MTBF/MTTR por máquina a partir de `EVENTO_FALLA`.

## Deuda técnica detectada (no corregir sin consultar)

Encontrada al revisar `01_tablas.sql`. Queda fuera del alcance de esta fase, pero conviene tenerla presente:

- **Aislamiento multi-tenant incompleto:** `documento`, `chat_debug_attachment` y `chat_feedback` no tienen `empresa_id`. En `documento` es serio: el RAG podría devolver manuales de una empresa a otra.
- `numero_ot`, `report_number` y `SENSOR.codigo` son únicos globalmente; deberían ser únicos por empresa.
- `DROP SCHEMA public CASCADE` al inicio de `01_tablas.sql` y en `/api/force-reset-db`: nunca debe llegar a producción. A futuro, migraciones con Alembic.
- Estados de OT: el enum (`pending, assigned, in_progress, completed, cancelled, overdue`) no calza con los seis estados definidos para el proyecto (creado, asignado, en progreso, en espera, completado, cerrado). `overdue` es una condición derivada, no un estado.
- `ORDEN_TRABAJO.tecnico_id` NOT NULL choca con OT `pending` sin asignar.
- Mezcla de `TIMESTAMP` y `TIMESTAMPTZ`.
- `LECTURA_SENSOR`: `SERIAL` e índice faltante por `(sensor_id, timestamp)`; `SENSOR` sin unidad ni umbrales.
- Roles: la documentación define Administrador, Gerente, Técnico y Visualizador, pero las semillas usan `admin, gerente, tecnico, engineer, supervisor, operador` y no existe `visualizador`.

## Reglas de trabajo

- Toda llamada del frontend al backend pasa por `services/api.ts`. Nada de `fetch()` crudo.
- Todo endpoint nuevo se protege con las dependencias de `permisos.py` y se refleja en `permissions.ts`.
- Todo lo nuevo en la base lleva `empresa_id` (directo o por relación) y se filtra por la empresa del usuario.
- No leer, mostrar ni modificar archivos `.env`.
- No ejecutar `/api/force-reset-db` ni scripts destructivos sin confirmación explícita.
- Proponer el plan antes de cambios que toquen más de unos pocos archivos.
