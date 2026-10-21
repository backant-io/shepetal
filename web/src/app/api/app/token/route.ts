import { redeemCode } from '@/lib/app-login';

// POST /api/app/token (API.md): {code, code_verifier, redirect_uri} -> {access_token, email}.
export async function POST(req: Request) {
  const b = (await req.json().catch(() => null)) as Record<string, unknown> | null;
  const { code, code_verifier, redirect_uri } = b ?? {};
  if (typeof code !== 'string' || typeof code_verifier !== 'string' || typeof redirect_uri !== 'string') {
    return Response.json({ error: 'invalid_request' }, { status: 400 });
  }
  const r = await redeemCode(code, code_verifier, redirect_uri);
  if (!r) return Response.json({ error: 'invalid_grant' }, { status: 400 });
  return Response.json(r, { headers: { 'cache-control': 'no-store' } });
}
