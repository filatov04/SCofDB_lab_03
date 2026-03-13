\timing on
\echo '=== AFTER PARTITIONING ==='

SET max_parallel_workers_per_gather = 0;
SET work_mem = '32MB';

ANALYZE orders_partitioned;

-- ============================================================
-- Финальные замеры на партиционированной таблице orders_partitioned.
-- Сравниваем три состояния:
--   1) До оптимизаций      (02_explain_before.sql — таблица orders)
--   2) После индексов      (04_explain_after_indexes.sql — таблица orders + индексы)
--   3) После партиций      (этот файл — таблица orders_partitioned + индексы)
-- ============================================================

\echo '--- Q1: Заказы пользователя (partitioned) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.status, o.total_amount, o.created_at
FROM orders_partitioned o
WHERE o.user_id = (
    SELECT id FROM users WHERE email = 'user00001@example.com'
)
ORDER BY o.created_at DESC;

\echo '--- Q2: Оплаченные заказы за 2025-H1 (partitioned + partition pruning) ---'
-- Ожидаем: Planner задействует только orders_2025_01 … orders_2025_06 (6 из 25 партиций)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, total_amount, created_at
FROM orders_partitioned
WHERE status = 'paid'
  AND created_at >= '2025-01-01'
  AND created_at <  '2025-07-01'
ORDER BY created_at DESC;

\echo '--- Q3: TOP-10 пользователей по выручке (partitioned) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    u.id,
    u.email,
    COUNT(o.id)                        AS order_count,
    ROUND(SUM(o.total_amount)::NUMERIC, 2) AS total_revenue
FROM users u
JOIN orders_partitioned o ON o.user_id = u.id
WHERE o.status IN ('paid', 'completed')
GROUP BY u.id, u.email
ORDER BY total_revenue DESC
LIMIT 10;

\echo '--- Q4: Топ-10 товаров за 2025 год (partitioned) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    oi.product_name,
    COUNT(*)         AS times_ordered,
    SUM(oi.quantity) AS total_qty
FROM order_items oi
JOIN orders_partitioned o ON o.id = oi.order_id
WHERE o.created_at >= '2025-01-01'
  AND o.created_at <  '2026-01-01'
GROUP BY oi.product_name
ORDER BY times_ordered DESC
LIMIT 10;

-- ============================================================
-- Итоговая сводка: размер каждой партиции
-- ============================================================
\echo '--- Размер партиций ---'
SELECT
    inhrelid::regclass                                    AS partition,
    pg_size_pretty(pg_relation_size(inhrelid))            AS size,
    (SELECT COUNT(*) FROM pg_class c
     JOIN pg_inherits i ON i.inhrelid = c.oid
     WHERE c.oid = inhrelid)                              AS sub_parts
FROM pg_inherits
WHERE inhparent = 'orders_partitioned'::regclass
ORDER BY partition;
