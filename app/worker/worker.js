'use strict';

const amqp        = require('amqplib');
const { Pool }    = require('pg');
const CircuitBreaker = require('./circuitBreaker');

// ── Configuration ────────────────────────────────────────────────────────────
const RABBIT_URL  = process.env.RABBIT_URL || 'amqp://localhost:5672';
const MAX_RETRIES = parseInt(process.env.MAX_RETRIES || '5');

const QUEUES = {
  ORDERS:      'orders',
  ORDERS_DLQ:  'orders.dlq',
  RETRY_5S:    'orders.retry.5s',
  RETRY_30S:   'orders.retry.30s',
  PARKING_LOT: 'orders.parking-lot',
};

// Retry delay schedule (ms) per attempt
const RETRY_DELAYS = [5000, 30000, 60000, 120000, 300000]; // 5s, 30s, 1m, 2m, 5m

// ── DB pool ──────────────────────────────────────────────────────────────────
const pool = new Pool({
  host:     process.env.DB_HOST     || 'localhost',
  port:     parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME     || 'ecommerce',
  user:     process.env.DB_USER     || 'postgres',
  password: process.env.DB_PASS     || 'postgres',
  max:      5,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false,
});

// ── Circuit Breaker (wraps DB writes) ────────────────────────────────────────
const dbBreaker = new CircuitBreaker({
  name:              'DB-Writer',
  failureThreshold:  3,
  successThreshold:  2,
  timeout:           30000,
});

// ── RabbitMQ channel ─────────────────────────────────────────────────────────
let channel;

async function connectRabbit(retries = 10) {
  for (let i = 0; i < retries; i++) {
    try {
      const conn = await amqp.connect(RABBIT_URL);
      channel    = await conn.createChannel();

      channel.prefetch(5); // process up to 5 messages concurrently

      await channel.assertExchange('orders.dlx', 'direct', { durable: true });

      await channel.assertQueue(QUEUES.ORDERS, {
        durable: true,
        arguments: {
          'x-dead-letter-exchange':    'orders.dlx',
          'x-dead-letter-routing-key': QUEUES.ORDERS_DLQ,
        },
      });
      await channel.assertQueue(QUEUES.ORDERS_DLQ,  { durable: true });
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
      await channel.assertQueue(QUEUES.PARKING_LOT, { durable: true });
      await channel.bindQueue(QUEUES.ORDERS_DLQ, 'orders.dlx', QUEUES.ORDERS_DLQ);

      conn.on('error', err => {
        console.error('RabbitMQ connection error:', err);
        setTimeout(() => connectRabbit(), 5000);
      });

      console.log('✅ Worker: RabbitMQ connected');
      return;
    } catch (err) {
      console.warn(`RabbitMQ attempt ${i + 1}/${retries}: ${err.message}`);
      await new Promise(r => setTimeout(r, 3000));
    }
  }
  throw new Error('Worker: Cannot connect to RabbitMQ');
}

// ── Process a single order ───────────────────────────────────────────────────
async function processOrder(order) {
  await dbBreaker.execute(async () => {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      // Deduct stock for each item
      for (const item of order.items) {
        const { rowCount } = await client.query(
          `UPDATE products
              SET stock = stock - $1
            WHERE id = $2 AND stock >= $1`,
          [item.quantity, item.product_id]
        );
        if (rowCount === 0) {
          throw new Error(`Insufficient stock for product ${item.product_id}`);
        }
      }

      // Update order status → confirmed
      await client.query(
        `UPDATE orders SET status = 'confirmed', updated_at = NOW() WHERE id = $1`,
        [order.orderId]
      );

      // Record event
      await client.query(
        `INSERT INTO order_events (order_id, event, payload)
         VALUES ($1, 'ORDER_CONFIRMED', $2)`,
        [order.orderId, JSON.stringify({ processedAt: new Date().toISOString() })]
      );

      await client.query('COMMIT');
      console.log(`✅ Order ${order.orderId} confirmed`);
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  });
}

// ── Retry logic with exponential backoff ─────────────────────────────────────
function scheduleRetry(order, retryCount) {
  const delayMs  = RETRY_DELAYS[Math.min(retryCount, RETRY_DELAYS.length - 1)];
  const queueTarget = retryCount === 0 ? QUEUES.RETRY_5S : QUEUES.RETRY_30S;

  console.warn(
    `⚠️  Order ${order.orderId} failed. Retry ${retryCount + 1}/${MAX_RETRIES} ` +
    `in ${delayMs / 1000}s → ${queueTarget}`
  );

  channel.sendToQueue(
    queueTarget,
    Buffer.from(JSON.stringify(order)),
    {
      persistent: true,
      headers:    { 'x-retry': retryCount + 1, 'x-origin': 'worker-retry' },
    }
  );
}

function sendToParkingLot(order, reason) {
  console.error(
    `🚫 Order ${order.orderId} is a poison message (${reason}). → parking-lot`
  );
  channel.sendToQueue(
    QUEUES.PARKING_LOT,
    Buffer.from(JSON.stringify({ ...order, parkingReason: reason, parkedAt: new Date().toISOString() })),
    { persistent: true }
  );
}

// ── Main consumer ─────────────────────────────────────────────────────────────
async function startConsumer() {
  console.log('🎯 Worker: starting consumer on orders queue');

  channel.consume(QUEUES.ORDERS, async (msg) => {
    if (!msg) return;

    let order;
    try {
      order = JSON.parse(msg.content.toString());
    } catch {
      console.error('Invalid JSON message, discarding');
      channel.ack(msg);
      return;
    }

    const retryCount = parseInt(msg.properties.headers?.['x-retry'] || 0);

    // Circuit breaker open guard → send straight to parking lot if too many retries
    if (retryCount > MAX_RETRIES) {
      sendToParkingLot(order, `exceeded max retries (${MAX_RETRIES})`);
      channel.ack(msg);
      return;
    }

    try {
      await processOrder(order);
      channel.ack(msg);
    } catch (err) {
      console.error(`❌ Order ${order?.orderId} processing error: ${err.message}`);

      // Check circuit breaker state
      const cbState = dbBreaker.getState();
      if (cbState.state === 'OPEN') {
        // DB is down — push to retry queue with delay
        scheduleRetry(order, retryCount);
        channel.ack(msg);
        return;
      }

      if (retryCount < MAX_RETRIES) {
        scheduleRetry(order, retryCount);
        channel.ack(msg);
      } else {
        // Exhausted retries → parking lot
        sendToParkingLot(order, err.message);
        channel.ack(msg);
      }
    }
  }, { noAck: false });

  // Also consume DLQ for visibility/alerting (do not requeue here — Argo CronWorkflow handles this)
  channel.consume(QUEUES.ORDERS_DLQ, (msg) => {
    if (!msg) return;
    const order = JSON.parse(msg.content.toString());
    console.error(`📨 DLQ message detected: order ${order.orderId}`);
    channel.ack(msg); // ack so Argo CronWorkflow manages reprocessing
  }, { noAck: false });
}

// ── Graceful shutdown ─────────────────────────────────────────────────────────
process.on('SIGTERM', async () => {
  console.log('SIGTERM received — closing worker gracefully');
  if (channel) await channel.close();
  await pool.end();
  process.exit(0);
});

// ── Bootstrap ─────────────────────────────────────────────────────────────────
async function main() {
  await connectRabbit();
  await startConsumer();
  console.log('🚀 Worker running');
}

main().catch(err => {
  console.error('Worker startup failed:', err);
  process.exit(1);
});
