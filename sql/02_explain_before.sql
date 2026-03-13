\timing on
\echo '=== BEFORE OPTIMIZATION ==='

-- Отключаем параллелизм и фиксируем work_mem для сравнимых замеров
SET max_parallel_workers_per_gather = 0;
SET work_mem = '32MB';
ANALYZE;

-- ============================================================
-- Q1: Заказы конкретного пользователя, сортировка по дате
-- Узкое место: Sequential Scan по всей таблице orders (100 000 строк)
-- ============================================================
\echo '--- Q1: Заказы пользователя (фильтр по user_id + сортировка) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.status, o.total_amount, o.created_at
FROM orders o
WHERE o.user_id = (
    SELECT id FROM users WHERE email = 'user00001@example.com'
)
ORDER BY o.created_at DESC;

-- ============================================================
-- Q2: Оплаченные заказы за диапазон дат (аналитика/отчётность)
-- Узкое место: Sequential Scan + двойной фильтр (status + created_at)
-- ============================================================
\echo '--- Q2: Оплаченные заказы за первое полугодие 2025 ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, total_amount, created_at
FROM orders
WHERE status = 'paid'
  AND created_at >= '2025-01-01'
  AND created_at <  '2025-07-01'
ORDER BY created_at DESC;

-- ============================================================
-- Q3: TOP-10 пользователей по выручке (JOIN + GROUP BY)
-- Узкое место: Hash Join + Sequential Scan на orders + Sort
-- ============================================================
\echo '--- Q3: TOP-10 пользователей по сумме оплаченных и завершённых заказов ---'
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

-- ============================================================
-- Q4: Популярные товары — JOIN orders + order_items с фильтром дат
-- Узкое место: Seq Scan на обеих таблицах + Nested Loop + GROUP BY
-- ============================================================
\echo '--- Q4 (доп.): Топ-10 товаров по количеству заказов за 2025 год ---'
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
