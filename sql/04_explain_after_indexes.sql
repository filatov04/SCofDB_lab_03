\timing on
\echo '=== AFTER INDEXES ==='

SET max_parallel_workers_per_gather = 0;
SET work_mem = '32MB';
ANALYZE;

-- ============================================================
-- Те же запросы, что в 02_explain_before.sql.
-- Ожидаемые изменения в планах:
--   Q1: Seq Scan → Index Scan по idx_orders_user_id
--   Q2: Seq Scan → Index Scan по idx_orders_status_created_at или idx_orders_paid_created_at
--   Q3: Hash Join улучшится за счёт idx_orders_user_id
--   Q4: Seq Scan на order_items → Index Scan по idx_order_items_order_id
-- ============================================================

\echo '--- Q1: Заказы пользователя (после индексов) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.status, o.total_amount, o.created_at
FROM orders o
WHERE o.user_id = (
    SELECT id FROM users WHERE email = 'user00001@example.com'
)
ORDER BY o.created_at DESC;

\echo '--- Q2: Оплаченные заказы за первое полугодие 2025 (после индексов) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, total_amount, created_at
FROM orders
WHERE status = 'paid'
  AND created_at >= '2025-01-01'
  AND created_at <  '2025-07-01'
ORDER BY created_at DESC;

\echo '--- Q3: TOP-10 пользователей по выручке (после индексов) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    u.id,
    u.email,
    COUNT(o.id)                        AS order_count,
    ROUND(SUM(o.total_amount)::NUMERIC, 2) AS total_revenue
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.status IN ('paid', 'completed')
GROUP BY u.id, u.email
ORDER BY total_revenue DESC
LIMIT 10;

\echo '--- Q4: Топ-10 товаров за 2025 год (после индексов) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    oi.product_name,
    COUNT(*)        AS times_ordered,
    SUM(oi.quantity) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.created_at >= '2025-01-01'
  AND o.created_at <  '2026-01-01'
GROUP BY oi.product_name
ORDER BY times_ordered DESC
LIMIT 10;
