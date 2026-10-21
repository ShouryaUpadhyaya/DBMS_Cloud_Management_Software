import type { NextFunction, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import { config } from './config.js';
import { HttpError } from './errors.js';

export type Role = 'admin' | 'manager' | 'developer' | 'viewer';
const ORDER: Role[] = ['viewer', 'developer', 'manager', 'admin'];

export interface AuthUser {
  userId: number;
  email: string;
  name: string;
  role: Role;
}

declare module 'express-serve-static-core' {
  interface Request {
    user?: AuthUser;
  }
}

export const atLeast = (have: Role, need: Role): boolean => ORDER.indexOf(have) >= ORDER.indexOf(need);

export function signToken(u: AuthUser): string {
  return jwt.sign({ sub: String(u.userId), email: u.email, name: u.name, role: u.role }, config.jwtSecret, { expiresIn: config.jwtTtl } as jwt.SignOptions);
}

export function verifyToken(token: string): AuthUser {
  try {
    const p = jwt.verify(token, config.jwtSecret) as jwt.JwtPayload;
    return { userId: Number(p.sub), email: String(p.email), name: String(p.name), role: p.role as Role };
  } catch {
    throw new HttpError(401, 'Invalid or expired token', { error: 'Invalid or expired token' });
  }
}

/** Bearer header, or ?token= (EventSource cannot set headers). */
export function requireAuth(req: Request, _res: Response, next: NextFunction): void {
  const header = req.header('authorization');
  const token = header?.startsWith('Bearer ') ? header.slice(7) : typeof req.query.token === 'string' ? req.query.token : undefined;
  if (!token) return next(new HttpError(401, 'Authentication required', { error: 'Authentication required' }));
  try {
    req.user = verifyToken(token);
    next();
  } catch (e) {
    next(e);
  }
}

export function requireRole(min: Role) {
  return (req: Request, _res: Response, next: NextFunction): void => {
    if (!req.user) return next(new HttpError(401, 'Authentication required', { error: 'Authentication required' }));
    if (!atLeast(req.user.role, min)) {
      return next(new HttpError(403, `Requires role ${min} or higher`, { error: `Requires role ${min} or higher` }));
    }
    next();
  };
}
