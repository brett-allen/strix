CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL CHECK (length(name) > 0)
);
CREATE TABLE orders (
  id INTEGER PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),
  FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_orders_user ON orders (user_id);
ALTER TABLE orders ADD COLUMN note TEXT;
INSERT INTO users (id, name) VALUES (1, 'a');
SELECT u.name, CAST(o.id AS TEXT)
  FROM users u
  LEFT JOIN orders o ON u.id = o.user_id
  GROUP BY u.name
  HAVING count(*) >= 1;
