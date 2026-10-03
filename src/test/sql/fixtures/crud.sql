CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER);
INSERT INTO items (id, name, qty) VALUES (1, 'a', 10), (2, 'b', 20);
UPDATE items SET qty = qty + 1 WHERE id = 1;
DELETE FROM items WHERE qty < 5;
SELECT * FROM items ORDER BY id;
