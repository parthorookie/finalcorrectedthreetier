'use strict';

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { v4: uuidv4 } = require('uuid');
const amqp = require('amqplib');
const { Pool } = require('pg');

const app = express();
app.use(express.json());
app.use(cors());
app.use(helmet());

// ── DB connection pool ───────────────────────────────────────────────────────
const pool = new Pool({
  host:     process.env.DB_HOST     || 'localhost',
  port:     parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME     || 'ecommerce',
  user:     process.env.DB_USER     || 'postgres',
  password: process.env.DB_PASS     || 'postgres',
  max:      10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false,
});

// ── RabbitMQ state ───────────────────────────────────────────────────────────
let channel;
let connection;
const RABBIT_URL = process.env.RABBIT_URL || 'amqp://localhost:5672';

const QUEUES = {
  ORDERS:       'orders',
  ORDERS_DLQ:   'orders.dlq',
  RETRY_5S:     'orders.retry.5s',
  RETRY_30S:    'orders.retry.30s',
  PARKING_LOT:  'orders.parking-lot',
};

async function connectRabbit(retries = 10) {
  for (let i = 0; i < retries; i++) {
    try {
      connection = await amqp.connect(RABBIT_URL);
      channel    = await connection.createChannel();

      // Dead-letter exchange
      await channel.assertExchange('orders.dlx', 'direct', { durable: true });

      // Main queue with DLX routing
      await channel.assertQueue(QUEUES.ORDERS, {
        durable: true,
        arguments: {
          'x-dead-letter-exchange':    'orders.dlx',
          'x-dead-letter-routing-key': QUEUES.ORDERS_DLQ,
        },
      });

      // DLQ
      await channel.assertQueue(QUEUES.ORDERS_DLQ,  { durable: true });

      // Retry queues (TTL-based re-queue back to main)
      await channel.assertQueue(QUEUES.RETRY_5S, {
        durable: true,
        arguments: {
          'x-dead-letter-exchange':    '',
          'x-dead-letter-routing-key': QUEUES.ORDERS,
          'x-message-ttl':             5000,
        },
      });
      await channel.assertQueue(QUEUES.RETRY_30S, {
        durable: true,
        arguments: {
          'x-dead-letter-exchange':    '',
          'x-dead-letter-routing-key': QUEUES.ORDERS,
          'x-message-ttl':             30000,
        },
      });

      // Parking lot (poison messages)
      await channel.assertQueue(QUEUES.PARKING_LOT, { durable: true });

      // Bind DLQ to DLX
      await channel.bindQueue(QUEUES.ORDERS_DLQ, 'orders.dlx', QUEUES.ORDERS_DLQ);

      console.log('✅ RabbitMQ connected and queues configured');
      connection.on('error', (err) => {
        console.error('RabbitMQ connection error:', err);
        setTimeout(() => connectRabbit(), 5000);
      });
      return;
    } catch (err) {
      console.warn(`RabbitMQ connection attempt ${i + 1}/${retries} failed: ${err.message}`);
      await new Promise(r => setTimeout(r, 3000));
    }
  }
  throw new Error('Could not connect to RabbitMQ after retries');
}

// ── DB schema bootstrap ──────────────────────────────────────────────────────
async function bootstrapDB() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS products (
      id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      name        TEXT NOT NULL,
      description TEXT,
      price       NUMERIC(10,2) NOT NULL,
      stock       INTEGER NOT NULL DEFAULT 0,
      image_url   TEXT,
      created_at  TIMESTAMPTZ DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS orders (
      id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_id UUID,
      items       JSONB NOT NULL,
      total       NUMERIC(10,2) NOT NULL,
      status      TEXT NOT NULL DEFAULT 'pending',
      created_at  TIMESTAMPTZ DEFAULT NOW(),
      updated_at  TIMESTAMPTZ DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS order_events (
      id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      order_id   UUID REFERENCES orders(id),
      event      TEXT NOT NULL,
      payload    JSONB,
      created_at TIMESTAMPTZ DEFAULT NOW()
    );

    -- Seed products if empty
    INSERT INTO products (name, description, price, stock, image_url)
    SELECT * FROM (VALUES
      ('Pixel 10 Pro',    'The best of Google, just got better.',  749.00, 50, '/images/pixel10pro.jpg'),
      ('Pixel Buds Pro',  'Superb sound, delivered wirelessly.',   229.00, 100, '/images/pixelbuds.jpg'),
      ('Pixel Watch 3',   'Health + style on your wrist.',         349.00, 75,  '/images/pixelwatch.jpg'),
      ('Pixel Tablet',    'Productivity meets creativity.',        499.00, 30,  '/images/pixeltablet.jpg')
    ) AS v(name, description, price, stock, image_url)
    WHERE NOT EXISTS (SELECT 1 FROM products LIMIT 1);
  `);
  console.log('✅ Database bootstrapped');
}

// ── Routes ───────────────────────────────────────────────────────────────────

app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// GET all products
app.get('/api/products', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT * FROM products ORDER BY created_at DESC'
    );
    res.json({ products: rows });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch products' });
  }
});

// GET single product
app.get('/api/products/:id', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT * FROM products WHERE id = $1', [req.params.id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Product not found' });
    res.json(rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch product' });
  }
});

// POST /api/orders — place order, publish to RabbitMQ
app.post('/api/orders', async (req, res) => {
  const { customer_id, items } = req.body;

  if (!items || !Array.isArray(items) || items.length === 0) {
    return res.status(400).json({ error: 'Order must have at least one item' });
  }

  try {
    // Calculate total from DB prices (server-side, not client-side)
    const productIds = items.map(i => i.product_id);
    const { rows: products } = await pool.query(
      'SELECT id, price, stock FROM products WHERE id = ANY($1)', [productIds]
    );

    const productMap = Object.fromEntries(products.map(p => [p.id, p]));
    let total = 0;

    for (const item of items) {
      const product = productMap[item.product_id];
      if (!product) return res.status(400).json({ error: `Product ${item.product_id} not found` });
      if (product.stock < item.quantity) {
        return res.status(400).json({ error: `Insufficient stock for product ${item.product_id}` });
      }
      total += parseFloat(product.price) * item.quantity;
    }

    // Insert order as pending
    const orderId = uuidv4();
    await pool.query(
      'INSERT INTO orders (id, customer_id, items, total, status) VALUES ($1, $2, $3, $4, $5)',
      [orderId, customer_id || null, JSON.stringify(items), total.toFixed(2), 'pending']
    );

    // Publish to RabbitMQ
    const message = {
      orderId,
      customer_id,
      items,
      total: total.toFixed(2),
      timestamp: new Date().toISOString(),
    };

    channel.sendToQueue(
      QUEUES.ORDERS,
      Buffer.from(JSON.stringify(message)),
      {
        persistent: true,
        headers: { 'x-retry': 0, 'x-origin': 'api' },
        messageId: orderId,
        timestamp: Math.floor(Date.now() / 1000),
      }
    );

    console.log(`📦 Order ${orderId} queued for processing`);
    res.status(202).json({
      status:  'queued',
      orderId,
      total:   total.toFixed(2),
      message: 'Order accepted and queued for processing',
    });
  } catch (err) {
    console.error('Order creation error:', err);
    res.status(500).json({ error: 'Failed to create order' });
  }
});

// GET order status
app.get('/api/orders/:id', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT * FROM orders WHERE id = $1', [req.params.id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Order not found' });
    res.json(rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch order' });
  }
});

// GET all orders (admin)
app.get('/api/orders', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT * FROM orders ORDER BY created_at DESC LIMIT 100'
    );
    res.json({ orders: rows });
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch orders' });
  }
});

// ── Start ────────────────────────────────────────────────────────────────────
const PORT = parseInt(process.env.PORT || '3000');

async function main() {
  await bootstrapDB();
  await connectRabbit();
  app.listen(PORT, () => {
    console.log(`🚀 Backend API listening on port ${PORT}`);
  });
}

main().catch(err => {
  console.error('Startup failed:', err);
  process.exit(1);
});

module.exports = { app, pool };
