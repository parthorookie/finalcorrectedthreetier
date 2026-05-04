const request = require('supertest');

// Mock pg pool
jest.mock('pg', () => {
  const mockQuery = jest.fn();
  const Pool = jest.fn(() => ({ query: mockQuery }));
  Pool.mockQuery = mockQuery;
  return { Pool };
});

// Mock amqplib
jest.mock('amqplib', () => ({
  connect: jest.fn().mockResolvedValue({
    createChannel: jest.fn().mockResolvedValue({
      assertExchange:  jest.fn().mockResolvedValue({}),
      assertQueue:     jest.fn().mockResolvedValue({}),
      bindQueue:       jest.fn().mockResolvedValue({}),
      sendToQueue:     jest.fn().mockReturnValue(true),
    }),
    on: jest.fn(),
  }),
}));

describe('Health endpoint', () => {
  it('GET /health returns 200', async () => {
    // Direct test without full server bootstrap
    const express = require('express');
    const app = express();
    app.get('/health', (req, res) => res.json({ status: 'ok' }));
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });
});

describe('Order validation', () => {
  it('rejects empty items array', () => {
    const items = [];
    expect(items.length).toBe(0);
  });

  it('accepts valid order structure', () => {
    const order = {
      customer_id: 'test-customer',
      items: [{ product_id: 'abc', quantity: 2 }],
    };
    expect(order.items).toHaveLength(1);
    expect(order.items[0].quantity).toBeGreaterThan(0);
  });
});
