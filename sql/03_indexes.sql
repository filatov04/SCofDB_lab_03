\timing on
\echo '=== APPLY INDEXES ==='

-- ============================================================
-- Индекс 1: orders(user_id) — BTREE
--
-- Ускоряет: Q1 (заказы конкретного пользователя), Q3 (JOIN users ↔ orders)
-- Тип BTREE: поиск по равенству (WHERE user_id = ?) — стандартный выбор.
-- Кардинальность: 10 000 уникальных пользователей при 100 000 заказов
-- → в среднем 10 строк на пользователя → index scan намного дешевле seq scan.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_orders_user_id
    ON orders USING BTREE (user_id);

-- ============================================================
-- Индекс 2: orders(status, created_at) — BTREE составной
--
-- Ускоряет: Q2 (WHERE status = 'paid' AND created_at BETWEEN ...)
-- Порядок колонок: сначала равенство (status), затем диапазон (created_at).
-- PostgreSQL может использовать индекс для обоих условий одновременно:
-- Index Scan с условием (status = 'paid') AND (created_at >= ... AND < ...).
-- Без первой колонки по равенству индекс по created_at одному менее эффективен
-- при наличии фильтра по статусу.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_orders_status_created_at
    ON orders USING BTREE (status, created_at DESC);

-- ============================================================
-- Индекс 3: order_items(order_id) — BTREE
--
-- Ускоряет: Q4 (JOIN orders ↔ order_items по order_id),
--           а также запросы по деталям заказа.
-- Без этого индекса каждый JOIN вызывает Seq Scan на ~250 000 строк.
-- order_id — внешний ключ: PostgreSQL НЕ создаёт индексы по FK автоматически,
-- поэтому его необходимо добавить явно.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_order_items_order_id
    ON order_items USING BTREE (order_id);

-- ============================================================
-- Индекс 4 (частичный): orders(created_at) WHERE status = 'paid' — BTREE
--
-- Ускоряет: Q2 при частых запросах только по оплаченным заказам.
-- Тип: частичный (partial) индекс — индексируется только ~50% строк
-- (те, где status = 'paid'), что уменьшает размер индекса вдвое
-- по сравнению с полным индексом по created_at.
-- Когда WHERE status = 'paid' AND created_at BETWEEN — PostgreSQL может
-- выбрать именно этот частичный индекс вместо составного.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_orders_paid_created_at
    ON orders USING BTREE (created_at DESC)
    WHERE status = 'paid';

-- Обновляем статистику после создания индексов
ANALYZE orders;
ANALYZE order_items;
