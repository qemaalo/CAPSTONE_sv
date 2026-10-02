-- =============================================================================
-- BARB — MIGRACIÓN 02: INTEGRACIÓN MULTI-ERP + REGISTRO DE FALLAS
-- =============================================================================
--
-- Se ejecuta DESPUÉS de 01_tablas.sql.
--
-- Principios:
--   * Solo AGREGA. No borra, no renombra, no cambia tipos ni restricciones
--     de tablas existentes. Las columnas nuevas en tablas existentes son
--     todas opcionales (NULL), así que el backend y el frontend actuales
--     siguen funcionando igual.
--   * Idempotente: se puede ejecutar varias veces sin error ni duplicados.
--   * Requiere PostgreSQL 15+ (UNIQUE NULLS NOT DISTINCT).
--
-- Contenido:
--   1. Tipos nuevos
--   2. CONECTOR_ERP            conectores configurados por cada empresa
--   3. Columnas nuevas en MAQUINA y ORDEN_TRABAJO
--   4. MAQUINA_ORIGEN          IDs externos de máquinas por conector
--   5. MODO_FALLA / CAUSA_FALLA  catálogos (globales o por empresa)
--   6. MAPEO_CODIGO            traducción de códigos ERP -> Barb
--   7. LOTE_INGESTA / INGESTA_CRUDA / RECHAZO_INGESTA  trazabilidad
--   8. EVENTO_FALLA            registro canónico de fallas
--   9. Semillas
-- =============================================================================


-- =============================================================================
-- 1. TIPOS
-- =============================================================================
DO $$ BEGIN
    CREATE TYPE tipo_erp AS ENUM ('sap', 'oracle', 'csv', 'rest_generico', 'otro');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE estado_conector AS ENUM ('borrador', 'activo', 'pausado', 'error');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE estado_lote AS ENUM ('en_curso', 'ok', 'con_rechazos', 'fallido');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE disparo_lote AS ENUM ('programado', 'manual');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE dominio_mapeo AS ENUM (
        'modo_falla', 'causa_falla', 'tipo_mantenimiento', 'prioridad_ot', 'estado_ot'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- =============================================================================
-- 2. CONECTOR_ERP
-- =============================================================================
--
-- Cada empresa configura sus conectores desde la interfaz.
--
-- SEGURIDAD: las credenciales (usuario/clave SAP, client secret OAuth, etc.)
-- van cifradas por el backend ANTES de llegar aquí, con una llave que vive
-- en variables de entorno (nunca en la BD). El backend jamás devuelve
-- credenciales_cifradas al frontend; solo expone tiene_credenciales.
--
CREATE TABLE IF NOT EXISTS CONECTOR_ERP (
    conector_id           SERIAL PRIMARY KEY,
    empresa_id            INT             NOT NULL,
    planta_id             INT,                          -- NULL = aplica a todas las plantas
    nombre                VARCHAR(120)    NOT NULL,     -- 'SAP PM Planta Norte'
    tipo                  tipo_erp        NOT NULL,
    url_base              VARCHAR(500),
    config                JSONB           NOT NULL DEFAULT '{}'::jsonb,  -- parámetros NO secretos
    credenciales_cifradas BYTEA,                        -- secreto cifrado por el backend
    zona_horaria          VARCHAR(60)     NOT NULL DEFAULT 'America/Santiago',
    frecuencia_sync_min   INT             NOT NULL DEFAULT 60 CHECK (frecuencia_sync_min >= 5),
    estado                estado_conector NOT NULL DEFAULT 'borrador',
    ultima_sync_ok        TIMESTAMPTZ,
    ultimo_error          TEXT,
    creado_por            INT,
    created_at            TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ     NOT NULL DEFAULT now(),
    UNIQUE (empresa_id, nombre),
    CONSTRAINT fk_conector_empresa FOREIGN KEY (empresa_id) REFERENCES EMPRESA(empresa_id),
    CONSTRAINT fk_conector_planta  FOREIGN KEY (planta_id)  REFERENCES PLANTA(planta_id),
    CONSTRAINT fk_conector_creador FOREIGN KEY (creado_por) REFERENCES USUARIO(usuario_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_conector_empresa ON CONECTOR_ERP(empresa_id, estado);


-- =============================================================================
-- 3. COLUMNAS NUEVAS EN TABLAS EXISTENTES (todas opcionales)
-- =============================================================================

-- MAQUINA: datos del activo que necesita la IA (cruzar con el manual correcto,
-- calcular antigüedad, priorizar por criticidad).
ALTER TABLE MAQUINA ADD COLUMN IF NOT EXISTS fabricante          VARCHAR(120);
ALTER TABLE MAQUINA ADD COLUMN IF NOT EXISTS modelo              VARCHAR(120);
ALTER TABLE MAQUINA ADD COLUMN IF NOT EXISTS numero_serie        VARCHAR(120);
ALTER TABLE MAQUINA ADD COLUMN IF NOT EXISTS fecha_puesta_marcha DATE;
ALTER TABLE MAQUINA ADD COLUMN IF NOT EXISTS criticidad          CHAR(1)
    CHECK (criticidad IN ('A', 'B', 'C'));

-- ORDEN_TRABAJO: origen de la OT. NULL = creada en Barb (comportamiento actual).
ALTER TABLE ORDEN_TRABAJO ADD COLUMN IF NOT EXISTS conector_id INT
    REFERENCES CONECTOR_ERP(conector_id);
ALTER TABLE ORDEN_TRABAJO ADD COLUMN IF NOT EXISTS id_externo  VARCHAR(80);

-- Una OT externa se importa una sola vez por conector (upsert idempotente).
CREATE UNIQUE INDEX IF NOT EXISTS uq_ot_origen
    ON ORDEN_TRABAJO(conector_id, id_externo)
    WHERE conector_id IS NOT NULL;


-- =============================================================================
-- 4. MAQUINA_ORIGEN — tabla puente de IDs externos
-- =============================================================================
--
-- La misma máquina puede tener un ID distinto en cada ERP (ej. EQUNR en SAP).
-- Así una máquina que aparece en dos sistemas sigue teniendo UN historial.
--
CREATE TABLE IF NOT EXISTS MAQUINA_ORIGEN (
    conector_id INT         NOT NULL,
    id_externo  VARCHAR(80) NOT NULL,
    maquina_id  INT         NOT NULL,
    PRIMARY KEY (conector_id, id_externo),
    CONSTRAINT fk_mo_conector FOREIGN KEY (conector_id) REFERENCES CONECTOR_ERP(conector_id) ON DELETE CASCADE,
    CONSTRAINT fk_mo_maquina  FOREIGN KEY (maquina_id)  REFERENCES MAQUINA(maquina_id)       ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_maquina_origen_maquina ON MAQUINA_ORIGEN(maquina_id);


-- =============================================================================
-- 5. CATÁLOGOS DE FALLA
-- =============================================================================
--
-- empresa_id NULL = catálogo global de Barb (lo ven todas las empresas).
-- empresa_id con valor = código propio de esa empresa.
--
CREATE TABLE IF NOT EXISTS MODO_FALLA (          -- QUÉ se observó
    modo_falla_id SERIAL PRIMARY KEY,
    empresa_id    INT,
    codigo        VARCHAR(40)  NOT NULL,
    nombre        VARCHAR(120) NOT NULL,
    descripcion   TEXT,
    activo        BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_modo_falla UNIQUE NULLS NOT DISTINCT (empresa_id, codigo),
    CONSTRAINT fk_modo_falla_empresa FOREIGN KEY (empresa_id) REFERENCES EMPRESA(empresa_id)
);

CREATE TABLE IF NOT EXISTS CAUSA_FALLA (         -- POR QUÉ ocurrió
    causa_falla_id SERIAL PRIMARY KEY,
    empresa_id     INT,
    codigo         VARCHAR(40)  NOT NULL,
    nombre         VARCHAR(120) NOT NULL,
    descripcion    TEXT,
    activo         BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_causa_falla UNIQUE NULLS NOT DISTINCT (empresa_id, codigo),
    CONSTRAINT fk_causa_falla_empresa FOREIGN KEY (empresa_id) REFERENCES EMPRESA(empresa_id)
);


-- =============================================================================
-- 6. MAPEO_CODIGO — traducción ERP -> Barb
-- =============================================================================
--
-- valor_barb es el 'codigo' del catálogo (modo/causa) o el valor del enum
-- existente (tipo_mantenimiento, prioridad_ot, estado_ot). El pipeline valida
-- que exista; si no hay mapeo, el registro va a RECHAZO_INGESTA.
--
CREATE TABLE IF NOT EXISTS MAPEO_CODIGO (
    conector_id    INT           NOT NULL,
    dominio        dominio_mapeo NOT NULL,
    codigo_externo VARCHAR(80)   NOT NULL,
    valor_barb     VARCHAR(80)   NOT NULL,
    PRIMARY KEY (conector_id, dominio, codigo_externo),
    CONSTRAINT fk_mapeo_conector FOREIGN KEY (conector_id) REFERENCES CONECTOR_ERP(conector_id) ON DELETE CASCADE
);


-- =============================================================================
-- 7. TRAZABILIDAD DE INGESTA (bronce + lotes + rechazos)
-- =============================================================================
CREATE TABLE IF NOT EXISTS LOTE_INGESTA (
    lote_id              BIGSERIAL    PRIMARY KEY,
    conector_id          INT          NOT NULL,
    disparo              disparo_lote NOT NULL DEFAULT 'programado',
    iniciado_por         INT,                       -- usuario si fue manual
    ventana_desde        TIMESTAMPTZ,
    ventana_hasta        TIMESTAMPTZ,
    iniciado_en          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    terminado_en         TIMESTAMPTZ,
    registros_leidos     INT          NOT NULL DEFAULT 0,
    registros_ok         INT          NOT NULL DEFAULT 0,
    registros_rechazados INT          NOT NULL DEFAULT 0,
    estado               estado_lote  NOT NULL DEFAULT 'en_curso',
    error_detalle        TEXT,
    CONSTRAINT fk_lote_conector FOREIGN KEY (conector_id)  REFERENCES CONECTOR_ERP(conector_id) ON DELETE CASCADE,
    CONSTRAINT fk_lote_usuario  FOREIGN KEY (iniciado_por) REFERENCES USUARIO(usuario_id)       ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_lote_conector ON LOTE_INGESTA(conector_id, iniciado_en DESC);

-- Capa BRONCE: el registro tal cual lo devolvió el ERP.
CREATE TABLE IF NOT EXISTS INGESTA_CRUDA (
    cruda_id    BIGSERIAL   PRIMARY KEY,
    lote_id     BIGINT      NOT NULL,
    entidad     VARCHAR(40) NOT NULL,              -- 'falla', 'orden_trabajo', 'maquina'
    id_externo  VARCHAR(80),
    payload     JSONB       NOT NULL,
    hash        VARCHAR(64) NOT NULL,              -- sha256 del payload
    recibido_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_cruda_lote FOREIGN KEY (lote_id) REFERENCES LOTE_INGESTA(lote_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cruda_lote ON INGESTA_CRUDA(lote_id);

CREATE TABLE IF NOT EXISTS RECHAZO_INGESTA (
    rechazo_id  BIGSERIAL    PRIMARY KEY,
    lote_id     BIGINT       NOT NULL,
    entidad     VARCHAR(40)  NOT NULL,
    id_externo  VARCHAR(80),
    motivo      VARCHAR(255) NOT NULL,             -- 'máquina sin mapeo', 'código de falla desconocido'
    payload     JSONB        NOT NULL,
    resuelto    BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT fk_rechazo_lote FOREIGN KEY (lote_id) REFERENCES LOTE_INGESTA(lote_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_rechazo_pendiente ON RECHAZO_INGESTA(lote_id) WHERE NOT resuelto;


-- =============================================================================
-- 8. EVENTO_FALLA — registro canónico de fallas
-- =============================================================================
--
-- Una fila por falla, venga de un ERP (conector_id con valor) o registrada
-- en Barb (conector_id NULL). Es la base para MTBF y para el modelo predictivo.
--
CREATE TABLE IF NOT EXISTS EVENTO_FALLA (
    evento_id            SERIAL      PRIMARY KEY,
    empresa_id           INT         NOT NULL,
    maquina_id           INT         NOT NULL,
    ot_id                INT,
    modo_falla_id        INT,
    causa_falla_id       INT,
    severidad            nivel_severidad,           -- reutiliza el enum existente
    detectada_en         TIMESTAMPTZ NOT NULL,
    inicio_detencion     TIMESTAMPTZ,
    fin_detencion        TIMESTAMPTZ,
    minutos_detencion    INT GENERATED ALWAYS AS (
                             (EXTRACT(EPOCH FROM (fin_detencion - inicio_detencion)) / 60)::INT
                         ) STORED,
    detuvo_produccion    BOOLEAN,
    descripcion_original TEXT,                      -- texto libre del técnico, sin tocar

    -- Origen y trazabilidad (NULL = registrada en Barb)
    conector_id          INT,
    id_externo           VARCHAR(80),
    lote_id              BIGINT,
    hash_origen          VARCHAR(64),

    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_falla_empresa  FOREIGN KEY (empresa_id)     REFERENCES EMPRESA(empresa_id),
    CONSTRAINT fk_falla_maquina  FOREIGN KEY (maquina_id)     REFERENCES MAQUINA(maquina_id),
    CONSTRAINT fk_falla_ot       FOREIGN KEY (ot_id)          REFERENCES ORDEN_TRABAJO(ot_id) ON DELETE SET NULL,
    CONSTRAINT fk_falla_modo     FOREIGN KEY (modo_falla_id)  REFERENCES MODO_FALLA(modo_falla_id),
    CONSTRAINT fk_falla_causa    FOREIGN KEY (causa_falla_id) REFERENCES CAUSA_FALLA(causa_falla_id),
    CONSTRAINT fk_falla_conector FOREIGN KEY (conector_id)    REFERENCES CONECTOR_ERP(conector_id),
    CONSTRAINT fk_falla_lote     FOREIGN KEY (lote_id)        REFERENCES LOTE_INGESTA(lote_id) ON DELETE SET NULL,
    CONSTRAINT ck_falla_origen   CHECK ((conector_id IS NULL) = (id_externo IS NULL)),
    CONSTRAINT ck_falla_fin_req_inicio CHECK (fin_detencion IS NULL OR inicio_detencion IS NOT NULL),
    CONSTRAINT ck_falla_fin_mayor      CHECK (fin_detencion IS NULL OR fin_detencion >= inicio_detencion)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_falla_origen
    ON EVENTO_FALLA(conector_id, id_externo)
    WHERE conector_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_falla_maquina_fecha ON EVENTO_FALLA(maquina_id, detectada_en);
CREATE INDEX IF NOT EXISTS idx_falla_empresa_fecha ON EVENTO_FALLA(empresa_id, detectada_en DESC);
CREATE INDEX IF NOT EXISTS idx_falla_modo          ON EVENTO_FALLA(modo_falla_id);


-- =============================================================================
-- 9. SEMILLAS
-- =============================================================================

-- Catálogo global de modos de falla
INSERT INTO MODO_FALLA (empresa_id, codigo, nombre) VALUES
    (NULL, 'FALLA_ARRANQUE',     'No arranca o falla al arrancar'),
    (NULL, 'PARADA_INESPERADA',  'Detención no programada'),
    (NULL, 'VIBRACION_ANORMAL',  'Vibración fuera de rango'),
    (NULL, 'SOBRECALENTAMIENTO', 'Temperatura fuera de rango'),
    (NULL, 'FUGA_EXTERNA',       'Fuga de fluido al exterior'),
    (NULL, 'RUIDO_ANORMAL',      'Ruido anormal'),
    (NULL, 'BAJO_RENDIMIENTO',   'Opera bajo su capacidad nominal'),
    (NULL, 'FALLA_SENAL',        'Pérdida o error de señal / comunicación')
ON CONFLICT DO NOTHING;

-- Catálogo global de causas de falla
INSERT INTO CAUSA_FALLA (empresa_id, codigo, nombre) VALUES
    (NULL, 'DESGASTE',          'Desgaste por uso normal'),
    (NULL, 'LUBRICACION',       'Lubricación deficiente o contaminada'),
    (NULL, 'SOBRECARGA',        'Operación sobre la capacidad de diseño'),
    (NULL, 'DESALINEAMIENTO',   'Desalineamiento o desbalance'),
    (NULL, 'FALLA_ELECTRICA',   'Falla de alimentación o componente eléctrico'),
    (NULL, 'CONTAMINACION',     'Suciedad, humedad o partículas'),
    (NULL, 'ERROR_OPERACION',   'Error de operación o procedimiento'),
    (NULL, 'SIN_DETERMINAR',    'Causa aún no determinada')
ON CONFLICT DO NOTHING;

-- Conectores demo para la empresa 1 (sin credenciales)
INSERT INTO CONECTOR_ERP (empresa_id, planta_id, nombre, tipo, url_base, config, estado, frecuencia_sync_min, ultima_sync_ok, creado_por) VALUES
    (1, 1,    'SAP PM Planta Central',   'sap',    'https://sap-demo.local/sap/opu/odata/sap/', '{"cliente_sap": "100", "centro": "SB01"}', 'activo',   60,  now() - INTERVAL '25 minutes', 1),
    (1, 2,    'Oracle EAM Antofagasta',  'oracle', 'https://oracle-demo.local/fscmRestApi/',    '{"organizacion": "ANF"}',                  'error',    120, now() - INTERVAL '2 days',     1),
    (1, NULL, 'Histórico CSV 2020-2025', 'csv',    NULL,                                        '{"separador": ";"}',                       'pausado',  1440, now() - INTERVAL '30 days',   1)
ON CONFLICT (empresa_id, nombre) DO NOTHING;

UPDATE CONECTOR_ERP
   SET ultimo_error = 'Credenciales rechazadas por el servidor (401)'
 WHERE empresa_id = 1 AND nombre = 'Oracle EAM Antofagasta' AND ultimo_error IS NULL;

-- Mapeos demo del conector SAP
INSERT INTO MAPEO_CODIGO (conector_id, dominio, codigo_externo, valor_barb)
SELECT c.conector_id, m.dominio::dominio_mapeo, m.codigo_externo, m.valor_barb
  FROM CONECTOR_ERP c
 CROSS JOIN (VALUES
    ('modo_falla',         'ZVIB', 'VIBRACION_ANORMAL'),
    ('modo_falla',         'ZTMP', 'SOBRECALENTAMIENTO'),
    ('modo_falla',         'ZFUG', 'FUGA_EXTERNA'),
    ('causa_falla',        'C01',  'DESGASTE'),
    ('causa_falla',        'C02',  'LUBRICACION'),
    ('tipo_mantenimiento', 'PM01', 'corrective'),
    ('tipo_mantenimiento', 'PM02', 'preventive')
 ) AS m(dominio, codigo_externo, valor_barb)
 WHERE c.empresa_id = 1 AND c.nombre = 'SAP PM Planta Central'
ON CONFLICT DO NOTHING;

-- Fallas registradas en Barb a partir de las OT correctivas del seed,
-- para que MTBF y el modelo tengan datos desde el primer arranque.
INSERT INTO EVENTO_FALLA (empresa_id, maquina_id, ot_id, severidad, detectada_en,
                          inicio_detencion, fin_detencion, detuvo_produccion, descripcion_original)
SELECT p.empresa_id, ot.maquina_id, ot.ot_id, ot.severity,
       ot.fecha_creacion, ot.fecha_inicio, ot.fecha_cierre,
       ot.severity IN ('high', 'critical'),
       ot.descripcion_problema
  FROM ORDEN_TRABAJO ot
  JOIN MAQUINA m ON m.maquina_id = ot.maquina_id
  JOIN PLANTA  p ON p.planta_id  = m.planta_id
 WHERE ot.tipo = 'corrective'
   AND (ot.fecha_cierre IS NULL OR ot.fecha_inicio IS NOT NULL)
   AND NOT EXISTS (SELECT 1 FROM EVENTO_FALLA f WHERE f.ot_id = ot.ot_id);
