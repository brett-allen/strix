CREATE TABLE IF NOT EXISTS items (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  qty INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_items_name ON items (name);
INSERT INTO items (id, name, qty) VALUES (1, 'a', 10), (2, 'b', 20);
SELECT * FROM items WHERE qty > 0 ORDER BY id LIMIT 10;
UPDATE items SET qty = qty + 1 WHERE id = 1;
DELETE FROM items WHERE qty < 5;
SELECT id, name FROM items;
