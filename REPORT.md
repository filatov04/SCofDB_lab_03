# Отчёт по лабораторной работе №3
## Диагностика и оптимизация маркетплейса

**Студент:** Филатов Илья  
**Группа:** БПМ-22-ПО-2  
**Дата:** 13.03.2026

---

## 1. Исходные данные

### 1.1 Использованная схема

Схема взята из `backend/migrations/001_init.sql` (lab_03).  
Ключевые изменения по сравнению с lab_01/lab_02:

- Колонка `order_items.subtotal` объявлена как `GENERATED ALWAYS AS (price * quantity) STORED` — значение вычисляется СУБД автоматически. Это позволяет seed-скрипту `01_seed_100k.sql` не передавать `subtotal` явно.
- Триггер `check_order_not_already_paid` исправлен: проверка выполняется только при **смене** статуса на `'paid'` (условие `OLD.status != 'paid'`), что позволяет обновлять другие поля (например, `total_amount`) без ложных срабатываний.
- Вспомогательные автоматические триггеры (пересчёт `total_amount`, авто-запись истории) не включены — они конфликтуют с массовой загрузкой через seed.

### 1.2 Объём данных (после `01_seed_100k.sql`)

| Таблица               | Строк   |
|-----------------------|---------|
| users                 | 10 000  |
| orders                | 100 000 |
| order_items           | 400 000 |
| order_status_history  | 199 904 |

---

## 2. Найденные медленные запросы (до оптимизации)

Замеры выполнены при `max_parallel_workers_per_gather = 0` и `work_mem = 32MB`.  
PostgreSQL 16, таблица `orders` без каких-либо дополнительных индексов.

---

### Запрос №1 — Заказы конкретного пользователя (фильтр по `user_id`, сортировка)

```sql
SELECT o.id, o.status, o.total_amount, o.created_at
FROM orders o
WHERE o.user_id = (
    SELECT id FROM users WHERE email = 'user00001@example.com'
)
ORDER BY o.created_at DESC;
```

**EXPLAIN ANALYZE:**
```
Sort  (cost=3314.47..3314.49 rows=10 width=37)
      (actual time=2.692..2.693 rows=11 loops=1)
  Sort Key: o.created_at DESC
  Sort Method: quicksort  Memory: 25kB
  ->  Seq Scan on orders o
        (cost=0.00..3306.00 rows=10 width=37)
        (actual time=0.307..2.687 rows=11 loops=1)
        Filter: (user_id = $0)
        Rows Removed by Filter: 99989
Buffers: shared hit=2059
Planning Time: 0.081 ms
Execution Time: 2.709 ms
```

**Почему медленно:**  
Seq Scan по всей таблице `orders` (100 000 строк). Из 100 000 строк подошли только 11 — это фильтрация с эффективностью 0,01%, но PostgreSQL вынужден читать все страницы таблицы (2059 буферов).

---

### Запрос №2 — Оплаченные заказы за диапазон дат

```sql
SELECT id, user_id, total_amount, created_at
FROM orders
WHERE status = 'paid'
  AND created_at >= '2025-01-01'
  AND created_at <  '2025-07-01'
ORDER BY created_at DESC;
```

**EXPLAIN ANALYZE:**
```
Sort  (cost=4651.41..4682.49 rows=12431 width=46)
      (actual time=5.187..5.562 rows=12399 loops=1)
  Sort Key: created_at DESC
  Sort Method: quicksort  Memory: 1257kB
  ->  Seq Scan on orders
        (actual time=0.148..3.938 rows=12399 loops=1)
        Filter: (created_at >= '2025-01-01' AND created_at < '2025-07-01'
                 AND status = 'paid')
        Rows Removed by Filter: 87601
Buffers: shared hit=2056
Planning Time: 0.024 ms
Execution Time: 5.774 ms
```

**Почему медленно:**  
Двойной фильтр (по `status` и диапазону `created_at`) без подходящего индекса → Seq Scan 100k строк. Дополнительно сортировка 12 399 результатов занимает 1257 kB памяти.

---

### Запрос №3 — TOP-10 пользователей по выручке (JOIN + GROUP BY)

```sql
SELECT u.id, u.email,
       COUNT(o.id)                        AS order_count,
       ROUND(SUM(o.total_amount)::NUMERIC, 2) AS total_revenue
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.status IN ('paid', 'completed')
GROUP BY u.id, u.email
ORDER BY total_revenue DESC
LIMIT 10;
```

**EXPLAIN ANALYZE:**
```
Limit  (actual time=32.488..32.491 rows=10 loops=1)
  ->  Sort  (actual time=32.488..32.490 rows=10 loops=1)
        Sort Key: (round(sum(o.total_amount), 2)) DESC
        ->  HashAggregate  (actual time=30.434..31.764 rows=9995 loops=1)
              Group Key: u.id  Memory Usage: 6545kB
              ->  Hash Join  (actual time=1.121..18.517 rows=87620 loops=1)
                    Hash Cond: (o.user_id = u.id)
                    ->  Seq Scan on orders o
                          (actual time=0.190..6.315 rows=87620 loops=1)
                          Filter: status IN ('paid','completed')
                          Rows Removed by Filter: 12380
                    ->  Hash on users (rows=10000)
Buffers: shared hit=2160
Planning Time: 0.105 ms
Execution Time: 32.574 ms
```

**Почему медленно:**  
Seq Scan на `orders` (87620 строк после фильтра) + Hash Join по 10k пользователей + HashAggregate по 9995 группам + Sort. Последовательность тяжёлых операций.

---

### Запрос №4 — Популярные товары за год (JOIN + GROUP BY)

```sql
SELECT oi.product_name, COUNT(*) AS times_ordered, SUM(oi.quantity) AS total_qty
FROM order_items oi
JOIN orders o ON o.id = oi.order_id
WHERE o.created_at >= '2025-01-01' AND o.created_at < '2026-01-01'
GROUP BY oi.product_name
ORDER BY times_ordered DESC
LIMIT 10;
```

**EXPLAIN ANALYZE:**
```
Limit  (actual time=75.689..75.691 rows=10 loops=1)
  ->  HashAggregate  (actual time=75.481..75.592 rows=2000 loops=1)
        ->  Hash Join  (actual time=7.448..57.264 rows=201444 loops=1)
              ->  Seq Scan on order_items oi  (rows=400000)
              ->  Hash  (Seq Scan on orders o, rows=50361 after date filter)
Buffers: shared hit=6605
Execution Time: 75.712 ms
```

**Почему медленно:**  
Два Seq Scan (400k + 100k строк), Hash Join 200k результатов, HashAggregate по 2000 товарам.

---

## 3. Добавленные индексы и обоснование типа

### Индекс №1

```sql
CREATE INDEX idx_orders_user_id ON orders USING BTREE (user_id);
```

- **Ускоряет:** Q1 (заказы по пользователю), Q3 (JOIN users ↔ orders)
- **Тип BTREE:** фильтр по равенству `user_id = ?`. 10k уникальных пользователей при 100k заказов → среднее ~10 строк на пользователя. Index Scan находит их без чтения всей таблицы.

### Индекс №2

```sql
CREATE INDEX idx_orders_status_created_at
    ON orders USING BTREE (status, created_at DESC);
```

- **Ускоряет:** Q2 (WHERE status = 'paid' AND created_at BETWEEN …)
- **Тип BTREE составной:** колонка равенства стоит первой (`status`), затем диапазон (`created_at`). PostgreSQL обрабатывает оба условия одним Index Scan. Порядок `DESC` совпадает с `ORDER BY created_at DESC`, устраняя этап сортировки.

### Индекс №3

```sql
CREATE INDEX idx_order_items_order_id
    ON order_items USING BTREE (order_id);
```

- **Ускоряет:** Q4 (JOIN orders ↔ order_items)
- **Тип BTREE:** `order_id` — внешний ключ; PostgreSQL **не** создаёт индексы по FK автоматически. Без него JOIN на 400k строках — всегда Seq Scan.

### Индекс №4 (частичный)

```sql
CREATE INDEX idx_orders_paid_created_at
    ON orders USING BTREE (created_at DESC)
    WHERE status = 'paid';
```

- **Ускоряет:** Q2 при условии `status = 'paid'`
- **Тип — частичный BTREE:** покрывает только ~50k строк (статус `'paid'`) вместо 100k. Размер индекса вдвое меньше полного. Планировщик выбирает именно его для запросов с фиксированным `status = 'paid'` и диапазоном дат — что и подтвердил EXPLAIN.

---

## 4. Замеры до/после индексов

Реальные значения `Execution Time` из EXPLAIN ANALYZE:

| Запрос | До (мс) | После индексов (мс) | Ускорение |
|--------|---------|---------------------|-----------|
| Q1 (заказы пользователя)   | 2.709 | 0.042 | ×64    |
| Q2 (paid + date range)     | 5.774 | 3.836 | ×1.5   |
| Q3 (JOIN + GROUP BY)       | 32.574 | 27.240 | ×1.2  |
| Q4 (товары за год)         | 75.712 | 69.270 | ×1.1  |

**Наблюдения:**

- **Q1** — максимальное ускорение (×64): запрос высоко-селективен (11 строк из 100k). Seq Scan 2059 буферов → Bitmap Index Scan 16 буферов.
- **Q2** — умеренное улучшение (×1.5): частичный индекс `idx_orders_paid_created_at` использован планировщиком (`Bitmap Index Scan on idx_orders_paid_created_at`). Сортировка 12k строк по-прежнему занимает время.
- **Q3 и Q4** — минимальный эффект (×1.1–1.2): индекс `idx_orders_user_id` помог Join, но **HashAggregate остался** доминирующей операцией — сканирование агрегируемых данных нельзя пропустить.

---

## 5. Партиционирование `orders` по дате

### 5.1 Выбранная стратегия

**RANGE-партиционирование** по колонке `created_at`, гранулярность **1 месяц**.

Обоснование:
- Данные охватывают 2024-01 — 2026-01 (24 месяца) → 24 партиции + DEFAULT (для данных вне диапазона).
- Самый частый аналитический паттерн — `WHERE created_at BETWEEN ...`, поэтому ключ партиции совпадает с фильтром.
- ~4200 строк на партицию — достаточно мало для Index Scan, достаточно велико чтобы не создавать тысячи мелких файлов.

### 5.2 Реализация

1. Создана таблица `orders_partitioned` с `PARTITION BY RANGE (created_at)`.
2. Созданы 24 дочерних партиции (`orders_2024_01` … `orders_2025_12`) + `orders_default`.
3. Данные скопированы: `INSERT INTO orders_partitioned SELECT ... FROM orders` — 100 000 строк за **41 мс**.
4. На `orders_partitioned` созданы три индекса (`user_id`, составной `status+created_at`, частичный по `paid`). PostgreSQL автоматически реплицировал их на все 24 дочерних партиции.

```sql
-- Пример: секция для января 2025
CREATE TABLE orders_2025_01 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
```

### 5.3 Проверка эффекта (partition pruning)

Q2 на `orders_partitioned` (`WHERE status='paid' AND created_at >= '2025-01-01' AND < '2025-07-01'`):

```
Append  (actual rows=12399 loops=1)
  ->  Index Scan on orders_2025_06  (rows=1978)
  ->  Index Scan on orders_2025_05  (rows=2087)
  ->  Index Scan on orders_2025_04  (rows=2106)
  ->  Index Scan on orders_2025_03  (rows=2089)
  ->  Index Scan on orders_2025_02  (rows=2019)
  ->  Index Scan on orders_2025_01  (rows=2120)
Execution Time: 2.665 ms
```

Из 25 секций планировщик обратился только к **6 нужным** — остальные 19 исключены на этапе планирования (partition pruning).

---

## 6. Итоговые замеры (три состояния)

Реальные значения `Execution Time` из EXPLAIN ANALYZE:

| Запрос | До оптимизаций | После индексов | После партиций |
|--------|---------------|----------------|----------------|
| Q1 (заказы пользователя)     | 2.709 мс | **0.042 мс** | 0.218 мс  |
| Q2 (paid + date range 6 мес) | 5.774 мс | 3.836 мс     | **2.665 мс** |
| Q3 (JOIN + GROUP BY TOP-10)  | 32.574 мс | 27.240 мс   | 31.795 мс |
| Q4 (товары за год)           | 75.712 мс | 69.270 мс   | 72.942 мс |

**Ключевые выводы:**

- **Q1**: лучший результат даёт вариант «только индексы» (0.042 мс). После партиционирования — 0.218 мс: планировщик выполняет 24 Index Scan по одной на каждую партицию, что создаёт overhead (план — 88 строк вместо 19).
- **Q2**: лучший результат после партиционирования (2.665 мс). Partition pruning сократил набор до 6 партиций (~25k строк вместо 100k).
- **Q3 и Q4**: партиционирование **не улучшило** результат по сравнению с индексами — HashAggregate по всем периодам требует сканирования всех партиций.

---

## 7. Что удалось исправить

| Проблема | Решение | Результат |
|----------|---------|-----------|
| Seq Scan при поиске заказов пользователя | `idx_orders_user_id` BTREE | ×64 ускорение Q1 |
| Seq Scan при date range + status фильтре | `idx_orders_paid_created_at` partial BTREE | ×1.5 ускорение Q2 |
| Seq Scan на 400k строк `order_items` при JOIN | `idx_order_items_order_id` BTREE | Улучшение Q4 |
| Полное сканирование таблицы при date range | RANGE-партиционирование по месяцам | Partition pruning: 6 из 25 партиций для Q2 |
| Отсутствие индексов по FK | Явное создание индексов по `user_id`, `order_id` | Обязательный шаг для FK в PostgreSQL |

---

## 8. Что не удалось исправить только индексами

### 8.1 HashAggregate в Q3 и Q4

Q3 и Q4 содержат `GROUP BY` по большому числу уникальных значений:
- Q3: 9995 уникальных пользователей → HashAggregate использует 6545 kB памяти
- Q4: 2000 уникальных товаров → 369 kB

Индексы ускоряют **доступ к строкам**, но агрегацию не устраняют — все подходящие строки всё равно читаются и группируются. Это подтверждается данными: ускорение Q3 от индексов лишь ×1.2.

**Правильные решения для этих запросов:**
- Материализованное представление: `REFRESH MATERIALIZED VIEW CONCURRENTLY` раз в N минут — агрегация предвычислена.
- Переписывание запроса: вместо `SUM(total_amount)` по всем заказам — хранить денормализованное поле.

### 8.2 High-selectivity Seq Scan в Q4

Q4 выбирает ~50% строк `orders` (весь 2025 год из двух). При доле выборки >15–20% PostgreSQL **намеренно** предпочитает Seq Scan: последовательное чтение дешевле, чем random page I/O через B-tree индекс.

Партиционирование частично решило эту проблему (scan только 12 партиций 2025 года), однако HashAggregate над ними остался тяжёлым.

### 8.3 Partition pruning не работает для Q1

Q1 фильтрует по `user_id` — это не ключ партиции (`created_at`). Планировщик не может отсечь ни одну партицию и выполняет 24 Index Scan параллельно, что создаёт overhead (Planning Time 0.928 мс против 0.114 мс для непартиционированной таблицы).

Вывод: партиционировать нужно по тому же полю, что является наиболее частым предикатом.

### 8.4 Сортировка результатов агрегации

`ORDER BY total_revenue DESC` после HashAggregate не опирается ни на один индекс — значение `total_revenue` является вычисляемым агрегатом, а не хранимой колонкой.

---

## 9. Выводы

1. **Индексы по внешним ключам создавать обязательно.** PostgreSQL не делает это автоматически. `order_items.order_id` без индекса — классическая причина медленных JOIN на больших таблицах.

2. **Порядок колонок в составном индексе критичен.** Для паттерна `WHERE col1 = ? AND col2 BETWEEN ?` оптимален индекс `(col1, col2)`: сначала равенство, затем диапазон. Обратный порядок не даст аналогичного ускорения.

3. **Частичные индексы — эффективный инструмент.** Индекс `WHERE status = 'paid'` покрывает 50% строк вместо 100%, занимает вдвое меньше места на диске и обновляется реже. Для специфических аналитических запросов он может быть предпочтительнее полного.

4. **Partition pruning эффективен только если фильтр совпадает с ключом партиции.** RANGE-партиционирование по `created_at` даёт ×1.4 на Q2 (date range), но не помогает Q1 (фильтр по `user_id`) и усугубляет его за счёт planning overhead.

5. **Тяжёлую агрегацию индексами и партиционированием не устранить.** `GROUP BY` по тысячам групп требует чтения и хеширования всех подходящих строк. Для OLAP-нагрузки правильный ответ — материализованные представления, периодически обновляемые агрегаты или отдельный аналитический слой (ClickHouse, DuckDB и т.д.).
