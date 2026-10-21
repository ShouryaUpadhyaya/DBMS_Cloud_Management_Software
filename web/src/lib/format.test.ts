import { describe, expect, it } from 'vitest';
import { ago, diffJson, money, num } from './format';

describe('format helpers', () => {
  it('formats money and numbers, tolerating junk', () => {
    expect(money('12.5')).toContain('12.50');
    expect(money(null)).toContain('0.00');
    expect(money('abc')).toBe('—');
    expect(num('3.14159', 2)).toBe('3.14');
    expect(num(undefined)).toBe('—');
  });

  it('formats relative times', () => {
    const now = Date.parse('2026-01-01T12:00:00Z');
    expect(ago('2026-01-01T11:59:30Z', now)).toBe('30s ago');
    expect(ago('2026-01-01T11:00:00Z', now)).toBe('1h ago');
    expect(ago('2025-12-30T12:00:00Z', now)).toBe('2d ago');
  });
});

describe('diffJson', () => {
  it('classifies added, removed, changed and unchanged keys', () => {
    const d = diffJson({ a: 1, b: 2, c: 3 }, { a: 1, b: 5, d: 4 });
    const by = Object.fromEntries(d.map((x) => [x.key, x.kind]));
    expect(by).toEqual({ a: 'same', b: 'changed', c: 'removed', d: 'added' });
  });
  it('handles inserts and deletes (one side null)', () => {
    expect(diffJson(null, { x: 1 }).every((c) => c.kind === 'added')).toBe(true);
    expect(diffJson({ x: 1 }, null).every((c) => c.kind === 'removed')).toBe(true);
  });
  it('compares nested values structurally', () => {
    expect(diffJson({ n: { a: 1 } }, { n: { a: 1 } })[0].kind).toBe('same');
  });
});
