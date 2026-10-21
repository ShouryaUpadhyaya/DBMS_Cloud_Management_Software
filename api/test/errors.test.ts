import { describe, expect, it } from 'vitest';
import { mapPgError } from '../src/errors.js';
import { retrying } from '../src/db.js';

describe('SQLSTATE mapping', () => {
  it('P0001 -> 400 with the message as-is', () => {
    const e = mapPgError({ code: 'P0001', message: 'Quota exceeded: 6 of 6 VMs used' })!;
    expect(e.status).toBe(400);
    expect(e.body.error).toBe('Quota exceeded: 6 of 6 VMs used');
  });

  it('23505 -> 409 naming the field from the key detail', () => {
    const e = mapPgError({ code: '23505', message: 'duplicate key', detail: 'Key (email)=(a@b.c) already exists.', constraint: 'users_email_key' })!;
    expect(e.status).toBe(409);
    expect(e.body.field).toBe('email');
    expect(e.body.fields).toEqual({ email: 'duplicate key' });
  });

  it('composite unique keys report the last column', () => {
    const e = mapPgError({ code: '23505', message: 'dup', detail: 'Key (project_id, name)=(2, pgdata) already exists.' })!;
    expect(e.body.field).toBe('name');
  });

  it('23514 -> 409 deriving the column from the constraint name', () => {
    const e = mapPgError({ code: '23514', message: 'violates check constraint', table: 'storage_volumes', constraint: 'storage_volumes_size_gb_check' })!;
    expect(e.status).toBe(409);
    expect(e.body.field).toBe('size_gb');
  });

  it('23P01 -> 409', () => {
    expect(mapPgError({ code: '23P01', message: 'conflicting key value violates exclusion constraint', constraint: 'allocations_resource_id_period_excl', table: 'allocations' })!.status).toBe(409);
  });

  it('42501 -> 403, 22P02 -> 400, unknown -> null', () => {
    expect(mapPgError({ code: '42501', message: 'Permission denied' })!.status).toBe(403);
    expect(mapPgError({ code: '22P02', message: 'invalid input syntax' })!.status).toBe(400);
    expect(mapPgError({ code: 'XX000', message: 'boom' })).toBeNull();
  });
});

describe('serialization retry (40001)', () => {
  it('retries up to 3 attempts, then succeeds', async () => {
    let calls = 0;
    const r = await retrying(async () => {
      calls += 1;
      if (calls < 3) throw Object.assign(new Error('could not serialize'), { code: '40001' });
      return 'ok';
    });
    expect(r).toBe('ok');
    expect(calls).toBe(3);
  });

  it('gives up after 3 attempts and rethrows', async () => {
    let calls = 0;
    await expect(retrying(async () => { calls += 1; throw Object.assign(new Error('x'), { code: '40001' }); })).rejects.toMatchObject({ code: '40001' });
    expect(calls).toBe(3);
  });

  it('does not retry other errors', async () => {
    let calls = 0;
    await expect(retrying(async () => { calls += 1; throw Object.assign(new Error('x'), { code: '23505' }); })).rejects.toMatchObject({ code: '23505' });
    expect(calls).toBe(1);
  });
});
