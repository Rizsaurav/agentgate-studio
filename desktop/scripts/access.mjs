import { timingSafeEqual } from 'node:crypto';
export function authorized(token, supplied) {
  if (
    typeof token !== 'string' ||
    token.length !== 64 ||
    typeof supplied !== 'string'
  )
    return false;
  const left = Buffer.from(token),
    right = Buffer.from(supplied);
  return left.length === right.length && timingSafeEqual(left, right);
}
