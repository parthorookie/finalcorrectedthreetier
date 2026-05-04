'use strict';

/**
 * Circuit Breaker
 * States: CLOSED (normal) → OPEN (failing) → HALF_OPEN (testing recovery)
 */
class CircuitBreaker {
  constructor(options = {}) {
    this.failureThreshold  = options.failureThreshold  || 5;
    this.successThreshold  = options.successThreshold  || 2;
    this.timeout           = options.timeout           || 60000; // 1 min
    this.name              = options.name              || 'CircuitBreaker';

    this.state          = 'CLOSED';
    this.failureCount   = 0;
    this.successCount   = 0;
    this.lastFailureTime = null;
    this.nextAttemptTime = null;
  }

  async execute(fn) {
    if (this.state === 'OPEN') {
      if (Date.now() < this.nextAttemptTime) {
        const waitMs = this.nextAttemptTime - Date.now();
        throw new Error(
          `[${this.name}] Circuit is OPEN. Retry in ${Math.ceil(waitMs / 1000)}s`
        );
      }
      // Transition to HALF_OPEN to test
      this.state = 'HALF_OPEN';
      console.log(`[${this.name}] Circuit HALF_OPEN — testing recovery`);
    }

    try {
      const result = await fn();
      this._onSuccess();
      return result;
    } catch (err) {
      this._onFailure(err);
      throw err;
    }
  }

  _onSuccess() {
    this.failureCount = 0;
    if (this.state === 'HALF_OPEN') {
      this.successCount++;
      if (this.successCount >= this.successThreshold) {
        this.state        = 'CLOSED';
        this.successCount = 0;
        console.log(`[${this.name}] Circuit CLOSED — service recovered`);
      }
    }
  }

  _onFailure(err) {
    this.failureCount++;
    this.lastFailureTime = Date.now();
    console.warn(`[${this.name}] Failure ${this.failureCount}/${this.failureThreshold}: ${err.message}`);

    if (this.state === 'HALF_OPEN' || this.failureCount >= this.failureThreshold) {
      this.state           = 'OPEN';
      this.successCount    = 0;
      this.nextAttemptTime = Date.now() + this.timeout;
      console.error(
        `[${this.name}] Circuit OPEN — will retry after ${this.timeout / 1000}s`
      );
    }
  }

  getState() {
    return {
      name:            this.name,
      state:           this.state,
      failureCount:    this.failureCount,
      lastFailureTime: this.lastFailureTime,
    };
  }

  reset() {
    this.state           = 'CLOSED';
    this.failureCount    = 0;
    this.successCount    = 0;
    this.lastFailureTime = null;
    this.nextAttemptTime = null;
  }
}

module.exports = CircuitBreaker;
