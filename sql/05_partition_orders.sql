\timing on
\echo '=== PARTITION ORDERS BY DATE (RANGE by month) ==='

-- ============================================================
-- Стратегия: RANGE-партиционирование по колонке created_at
-- Ключ секционирования: created_at (TIMESTAMP)
-- Гранулярность: месяц (24 партиции + DEFAULT)
-- Данные охватывают период 2024-01-01 — 2026-01-01
-- ============================================================

-- ============================================================
-- Шаг 1: Создаём партиционированную таблицу-замену
-- Структура идентична исходной orders (без партиционирования)
-- ============================================================
CREATE TABLE IF NOT EXISTS orders_partitioned (
    id           UUID          NOT NULL DEFAULT uuid_generate_v4(),
    user_id      UUID          NOT NULL,
    status       VARCHAR(20)   NOT NULL DEFAULT 'created',
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at   TIMESTAMP     NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- ============================================================
-- Шаг 2: Создаём месячные партиции (2024-01 … 2025-12) + DEFAULT
-- ============================================================

-- 2024
CREATE TABLE IF NOT EXISTS orders_2024_01 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE IF NOT EXISTS orders_2024_02 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE IF NOT EXISTS orders_2024_03 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');
CREATE TABLE IF NOT EXISTS orders_2024_04 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');
CREATE TABLE IF NOT EXISTS orders_2024_05 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-05-01') TO ('2024-06-01');
CREATE TABLE IF NOT EXISTS orders_2024_06 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-06-01') TO ('2024-07-01');
CREATE TABLE IF NOT EXISTS orders_2024_07 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-07-01') TO ('2024-08-01');
CREATE TABLE IF NOT EXISTS orders_2024_08 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-08-01') TO ('2024-09-01');
CREATE TABLE IF NOT EXISTS orders_2024_09 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-09-01') TO ('2024-10-01');
CREATE TABLE IF NOT EXISTS orders_2024_10 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-10-01') TO ('2024-11-01');
CREATE TABLE IF NOT EXISTS orders_2024_11 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-11-01') TO ('2024-12-01');
CREATE TABLE IF NOT EXISTS orders_2024_12 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');

-- 2025
CREATE TABLE IF NOT EXISTS orders_2025_01 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE IF NOT EXISTS orders_2025_02 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE IF NOT EXISTS orders_2025_03 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');
CREATE TABLE IF NOT EXISTS orders_2025_04 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-04-01') TO ('2025-05-01');
CREATE TABLE IF NOT EXISTS orders_2025_05 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE IF NOT EXISTS orders_2025_06 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE IF NOT EXISTS orders_2025_07 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE IF NOT EXISTS orders_2025_08 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
CREATE TABLE IF NOT EXISTS orders_2025_09 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');
CREATE TABLE IF NOT EXISTS orders_2025_10 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
CREATE TABLE IF NOT EXISTS orders_2025_11 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');
CREATE TABLE IF NOT EXISTS orders_2025_12 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');

-- DEFAULT-секция для данных вне диапазона (будущее / пересев)
CREATE TABLE IF NOT EXISTS orders_default  PARTITION OF orders_partitioned DEFAULT;

-- ============================================================
-- Шаг 3: Копируем данные из исходной таблицы
-- ============================================================
\echo '--- Копирование данных из orders → orders_partitioned ---'
INSERT INTO orders_partitioned (id, user_id, status, total_amount, created_at)
SELECT id, user_id, status, total_amount, created_at
FROM orders;

-- Проверка: количество строк должно совпасть
\echo '--- Проверка количества строк ---'
SELECT
    'orders'              AS table_name, COUNT(*) AS rows_count FROM orders
UNION ALL
SELECT 'orders_partitioned', COUNT(*) FROM orders_partitioned;

-- ============================================================
-- Шаг 4: Индексы на партиционированной таблице
-- PostgreSQL автоматически создаёт индексы на каждой дочерней партиции
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_oprt_user_id
    ON orders_partitioned USING BTREE (user_id);

CREATE INDEX IF NOT EXISTS idx_oprt_status_created_at
    ON orders_partitioned USING BTREE (status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_oprt_paid_created_at
    ON orders_partitioned USING BTREE (created_at DESC)
    WHERE status = 'paid';

-- ============================================================
-- Шаг 5: ANALYZE и проверка partition pruning
-- ============================================================
ANALYZE orders_partitioned;

\echo '--- Partition pruning: Q2 на orders_partitioned ---'
-- Planner должен обратиться только к партициям 2025_01 … 2025_06
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, total_amount, created_at
FROM orders_partitioned
WHERE status = 'paid'
  AND created_at >= '2025-01-01'
  AND created_at <  '2025-07-01'
ORDER BY created_at DESC;

-- Проверим список задействованных партиций (для отчёта)
\echo '--- Распределение строк по партициям ---'
SELECT
    inhrelid::regclass AS partition_name,
    pg_relation_size(inhrelid) AS size_bytes
FROM pg_inherits
WHERE inhparent = 'orders_partitioned'::regclass
ORDER BY partition_name;
