const CircuitBreaker = require('./circuitBreaker');

describe('CircuitBreaker', () => {
  let cb;

  beforeEach(() => {
    cb = new CircuitBreaker({ name: 'test', failureThreshold: 3, successThreshold: 2, timeout: 1000 });
  });

  it('starts CLOSED', () => {
    expect(cb.state).toBe('CLOSED');
  });

  it('opens after failureThreshold failures', async () => {
    const failFn = jest.fn().mockRejectedValue(new Error('fail'));
    for (let i = 0; i < 3; i++) {
      try { await cb.execute(failFn); } catch {}
    }
    expect(cb.state).toBe('OPEN');
  });

  it('throws immediately when OPEN', async () => {
    cb.state = 'OPEN';
    cb.nextAttemptTime = Date.now() + 10000;
    await expect(cb.execute(async () => {})).rejects.toThrow('Circuit is OPEN');
  });

  it('resets to CLOSED after successful half-open', async () => {
    cb.state = 'HALF_OPEN';
    const okFn = jest.fn().mockResolvedValue('ok');
    await cb.execute(okFn);
    await cb.execute(okFn);
    expect(cb.state).toBe('CLOSED');
  });
});
