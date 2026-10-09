-- Strix comprehensive execute smoke script (executed subset only).
--
-- Run against a fresh DB:
--   ./build.sh
--   rm -f examples/demo.strix
--   ./strix init examples/demo
--   ./strix sql examples/demo examples/comprehensive.sql
--
-- Or in the shell:
--   ./strix shell examples/demo
--   .read examples/comprehensive.sql
--
-- Stays within what Strix execute supports today (see docs/sql-dialect.md
-- "Executed vs parsed only"). Includes S2 CAST, S3 UNIQUE / TEXT PK,
-- S4 whole-query aggregates, S5 GROUP BY / HAVING, and S6 INNER/CROSS JOIN.
-- Intentionally omits LEFT OUTER JOIN, DISTINCT, CHECK/FK, ALTER,
-- INSERT…SELECT, OR REPLACE/IGNORE, composite PK.

-- ---------------------------------------------------------------------------
-- Clean slate (idempotent-ish: drop children before parents)
-- ---------------------------------------------------------------------------
DROP INDEX IF EXISTS idx_orders_customer;
DROP INDEX IF EXISTS idx_orders_sku;
DROP INDEX IF EXISTS idx_customers_email;
DROP INDEX IF EXISTS idx_products_name;
DROP INDEX IF EXISTS idx_tags_label;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS scratch;
DROP TABLE IF EXISTS tags;

-- ---------------------------------------------------------------------------
-- Schema: tables
-- ---------------------------------------------------------------------------
CREATE TABLE customers (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL DEFAULT 'anonymous',
  active INTEGER DEFAULT 1
);

CREATE TABLE products (
  id INT PRIMARY KEY,
  name TEXT NOT NULL,
  price REAL NOT NULL,
  sku TEXT UNIQUE,
  note TEXT
);

-- Non-IPK TEXT PRIMARY KEY (S3): NOT NULL + system unique index
CREATE TABLE tags (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL
);

CREATE TABLE orders (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL,
  product_id INTEGER NOT NULL,
  qty INTEGER NOT NULL DEFAULT 1,
  paid INTEGER DEFAULT 0,
  tag TEXT
);

CREATE TABLE IF NOT EXISTS scratch (
  id INTEGER PRIMARY KEY,
  blob_col BLOB,
  text_col TEXT
);

-- ---------------------------------------------------------------------------
-- Schema: indexes (DESC is catalog-only; keys are ASC)
-- ---------------------------------------------------------------------------
-- email/sku already have UNIQUE system indexes; keep a non-unique name index
CREATE INDEX IF NOT EXISTS idx_products_name ON products (name);
CREATE INDEX idx_orders_customer ON orders (customer_id);
CREATE INDEX idx_orders_sku ON orders (tag DESC);
CREATE UNIQUE INDEX idx_tags_label ON tags (label);

-- ---------------------------------------------------------------------------
-- INSERT: named columns, multi-row, NULL, defaults, blob, auto rowid
-- ---------------------------------------------------------------------------
INSERT INTO customers (id, email, name, active) VALUES
  (1, 'alice@example.com', 'Alice', 1),
  (2, 'bob@example.com', 'Bob', 1),
  (3, 'cara@example.com', 'Cara', 0);

-- Omit name → DEFAULT 'anonymous'; omit active → DEFAULT 1
INSERT INTO customers (id, email) VALUES (4, 'dave@example.com');

INSERT INTO products (id, name, price, sku, note) VALUES
  (10, 'Widget', 9.99, 'W-10', 'basic'),
  (20, 'Gadget', 19.50, 'G-20', NULL),
  (30, 'Doohickey', 0.5, 'D-30', 'cheap'),
  (40, 'Thingamajig', 100.0, 'T-40', 'premium');

-- Auto-allocate IPK (omit id)
INSERT INTO products (name, price, sku) VALUES ('Spare', 1.25, 'S-auto');

INSERT INTO orders (id, customer_id, product_id, qty, paid, tag) VALUES
  (100, 1, 10, 2, 1, 'retail'),
  (101, 1, 20, 1, 1, 'retail'),
  (102, 2, 10, 5, 0, 'wholesale'),
  (103, 2, 30, 3, 1, 'retail'),
  (104, 3, 40, 1, 0, 'vip'),
  (105, 4, 20, 2, 1, 'retail');

INSERT INTO scratch (id, blob_col, text_col) VALUES
  (1, X'DEADBEEF', 'hex blob'),
  (2, X'00', 'nul byte'),
  (3, NULL, 'no blob');

INSERT INTO tags (id, label) VALUES
  ('tag-retail', 'retail'),
  ('tag-vip', 'vip');

-- ---------------------------------------------------------------------------
-- SELECT: projection, alias, WHERE, exprs, IN, IS NULL, ORDER/LIMIT/OFFSET
-- ---------------------------------------------------------------------------
SELECT * FROM customers ORDER BY id;
SELECT id, label FROM tags WHERE id = 'tag-vip';

SELECT c.id, c.email, c.name
  FROM customers AS c
 WHERE c.active = 1
 ORDER BY c.email;

SELECT id, name, price, price * 2 AS double_price
  FROM products
 WHERE price >= 9.99 AND name != 'Spare'
 ORDER BY price DESC, id ASC;

SELECT id, name, note
  FROM products
 WHERE note IS NULL OR note = 'basic'
 ORDER BY id;

SELECT id, customer_id, qty
  FROM orders
 WHERE customer_id IN (1, 2)
   AND qty > 1
 ORDER BY qty DESC
 LIMIT 3 OFFSET 1;

SELECT id, name
  FROM products
 WHERE NOT (price < 1.0)
 ORDER BY id
 LIMIT 10;

SELECT id, email
  FROM customers
 WHERE email = 'alice@example.com';

-- Boolean context is strict (S1): use a comparison / IS NOT NULL, not bare text
SELECT id, name FROM customers WHERE name IS NOT NULL ORDER BY id;

-- Arithmetic + string concat in projection
SELECT id, tag || '-paid' AS label, qty * 10 AS scaled
  FROM orders
 WHERE paid = 1
 ORDER BY id;

SELECT * FROM scratch ORDER BY id;

-- Scalar CAST (S2): projection, WHERE, SET — no affinity; Text↔numeric needs CAST
SELECT id, CAST(price AS TEXT) AS price_text, CAST(price AS INTEGER) AS price_int
  FROM products
 ORDER BY id;

SELECT id, name FROM products WHERE CAST(CAST(price AS INTEGER) AS TEXT) = '19';

-- ---------------------------------------------------------------------------
-- UPDATE / DELETE (index-maintained)
-- ---------------------------------------------------------------------------
UPDATE products SET price = price + 0.01, note = 'touched' WHERE id = 10;
UPDATE products SET note = CAST(id AS TEXT) WHERE id = 30;
UPDATE orders SET paid = 1, qty = qty + 1 WHERE tag = 'wholesale';
UPDATE customers SET active = 0 WHERE email = 'dave@example.com';

DELETE FROM orders WHERE paid = 0 AND tag = 'vip';
DELETE FROM scratch WHERE text_col = 'nul byte';

SELECT id, name, price, note FROM products WHERE id = 10;
SELECT id, customer_id, qty, paid, tag FROM orders ORDER BY id;
SELECT id, email, active FROM customers ORDER BY id;
SELECT id, text_col FROM scratch ORDER BY id;

-- Whole-query aggregates (S4; no GROUP BY)
SELECT COUNT(*) AS n_products, SUM(price), AVG(price), MIN(price), MAX(price) FROM products;
SELECT COUNT(*) FROM orders WHERE paid = 1;

-- GROUP BY / HAVING (S5; single table; strict select list)
SELECT tag, COUNT(*) AS n, SUM(qty) FROM orders GROUP BY tag ORDER BY tag;
SELECT tag, COUNT(*) AS n FROM orders GROUP BY tag HAVING COUNT(*) >= 1 ORDER BY COUNT(*) DESC;

-- INNER JOIN (S6; two tables; qualified names / aliases)
SELECT c.name, o.id AS order_id, o.qty
  FROM customers AS c
  INNER JOIN orders AS o ON c.id = o.customer_id
  WHERE o.paid = 1
  ORDER BY c.name, o.id;
SELECT c.name, COUNT(*) AS n_orders
  FROM customers AS c
  JOIN orders AS o ON c.id = o.customer_id
  GROUP BY c.name
  ORDER BY c.name;

-- ---------------------------------------------------------------------------
-- Explicit transactions
-- ---------------------------------------------------------------------------
BEGIN;
INSERT INTO customers (id, email, name) VALUES (5, 'erin@example.com', 'Erin');
UPDATE products SET note = 'in txn' WHERE id = 20;
COMMIT;

SELECT id, email FROM customers WHERE id = 5;
SELECT note FROM products WHERE id = 20;

BEGIN TRANSACTION;
INSERT INTO customers (id, email, name) VALUES (6, 'frank@example.com', 'Frank');
ROLLBACK;

-- Frank must not appear (empty result)
SELECT id, email FROM customers WHERE id = 6;
SELECT id, email FROM customers ORDER BY id;

-- ---------------------------------------------------------------------------
-- Index lifecycle + DROP TABLE policy (indexes must go first)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_products_sku ON products (sku);
SELECT id, sku FROM products WHERE sku = 'W-10';

DROP INDEX IF EXISTS idx_orders_sku;
DROP INDEX IF EXISTS idx_orders_customer;
DROP INDEX IF EXISTS idx_products_sku;
DROP INDEX IF EXISTS idx_products_name;
DROP INDEX IF EXISTS idx_customers_email;
DROP INDEX IF EXISTS idx_tags_label;

DROP TABLE orders;
DROP TABLE products;
DROP TABLE customers;
DROP TABLE IF EXISTS scratch;
DROP TABLE IF EXISTS tags;

-- Recreate a tiny durable footprint so a reopen still shows something useful
CREATE TABLE smoke (
  id INTEGER PRIMARY KEY,
  label TEXT NOT NULL
);
INSERT INTO smoke (id, label) VALUES (1, 'comprehensive.sql ok');
SELECT * FROM smoke;
