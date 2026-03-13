# Статус лабораторной работы №3

## Что уже готово
- ✅ Кодовая база из lab_02 (`backend`, `frontend`, Dockerfile, `.github`)
- ✅ Инфраструктура запуска через Docker (`docker-compose.yml`)
- ✅ Готовый генератор данных на 100k заказов (`sql/01_seed_100k.sql`)
- ✅ Шаблоны SQL для диагностики и оптимизации (`sql/02`...`sql/06`)
- ✅ Шаблон отчёта `REPORT.md`

## Что сделано студентом

### Python-реализация
- ✅ `backend/migrations/001_init.sql` — схема с GENERATED subtotal, исправленным триггером
- ✅ `backend/app/domain/` — `User`, `Order`, `OrderItem`, `OrderStatus`, исключения
- ✅ `backend/app/infrastructure/repositories.py` — UserRepository, OrderRepository
- ✅ `backend/app/infrastructure/db.py` — SQLite/PostgreSQL совместимость, lazy table init
- ✅ `backend/app/application/` — UserService, OrderService, PaymentService
- ✅ `backend/app/main.py` — FastAPI + lifespan

### SQL
- ✅ `sql/02_explain_before.sql` — 4 медленных запроса с EXPLAIN ANALYZE
- ✅ `sql/03_indexes.sql` — 4 индекса (BTREE простой, составной, FK, частичный)
- ✅ `sql/04_explain_after_indexes.sql` — повторные замеры после индексов
- ✅ `sql/05_partition_orders.sql` — RANGE-партиционирование orders по месяцам (24 партиции)
- ✅ `sql/06_explain_after_partition.sql` — финальные замеры на orders_partitioned

### Отчёт
- ✅ `REPORT.md` — все разделы заполнены реальными данными из EXPLAIN ANALYZE
- ✅ Сравнительная таблица до/после индексов/партиций
- ✅ Описание что не удалось ускорить индексами и почему

## Результаты замеров (Execution Time)

| Запрос | До | После индексов | После партиций |
|--------|----|----------------|----------------|
| Q1 (заказы пользователя)   | 2.709 мс | **0.042 мс** (×64) | 0.218 мс |
| Q2 (paid + date range)     | 5.774 мс | 3.836 мс (×1.5) | **2.665 мс** |
| Q3 (JOIN + GROUP BY TOP-10) | 32.574 мс | 27.240 мс | 31.795 мс |
| Q4 (товары за год)         | 75.712 мс | 69.270 мс | 72.942 мс |

## Тесты
- ✅ 33/33 тестов прошли (domain + integration)
- ✅ concurrent-тесты корректно пропускаются при отсутствии отдельного PostgreSQL

## Минимальные требования к сдаче
1. ✅ Выполнен seed на `100k` заказов (10k users, 100k orders, 400k order_items).
2. ✅ Есть `EXPLAIN ANALYZE` до/после индексов и после партиционирования.
3. ✅ Есть 4 индекса с объяснением выбора типа.
4. ✅ Реализовано RANGE-партиционирование `orders` по дате (24 партиции + DEFAULT).
5. ✅ Заполнен `REPORT.md` с выводами и реальными данными замеров.
