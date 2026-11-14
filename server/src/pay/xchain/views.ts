/** NEP-145 storage views on any NEAR token contract. Tests pass a fake. */
export type NearViews = {
  storageRegistered(contract: string, accountId: string): Promise<boolean>;
  storageMin(contract: string): Promise<bigint>;
  accountExists(accountId: string): Promise<boolean>;
  /** Native NEAR (`contract` null) or a NEP-141 balance in base units. A missing account holds 0. */
  balance(contract: string | null, accountId: string): Promise<bigint>;
};

export function createNearViews(rpcUrl: string): NearViews {
  const call = async (contract: string, method: string, args: object): Promise<unknown> => {
    const r = await fetch(rpcUrl, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(8_000),
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'query', params: { request_type: 'call_function', finality: 'final', account_id: contract, method_name: method, args_base64: Buffer.from(JSON.stringify(args)).toString('base64') } }),
    });
    const body = (await r.json()) as { result?: { result?: number[] }; error?: unknown };
    if (!r.ok || body.error || !body.result?.result) throw new Error(`${method} on ${contract} failed`);
    return JSON.parse(Buffer.from(body.result.result).toString());
  };
  const viewAccount = async (accountId: string) => {
    const r = await fetch(rpcUrl, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(8_000),
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'query', params: { request_type: 'view_account', finality: 'final', account_id: accountId } }),
    });
    const body = (await r.json()) as { result?: { amount?: string; error?: string }; error?: { cause?: { name?: string } } };
    if (body.error?.cause?.name === 'UNKNOWN_ACCOUNT' || /does not exist/.test(body.result?.error ?? '')) return null;
    if (r.ok && typeof body.result?.amount === 'string') return BigInt(body.result.amount);
    throw new Error('view_account failed');
  };
  return {
    async accountExists(accountId) {
      return (await viewAccount(accountId)) !== null;
    },
    async balance(contract, accountId) {
      if (contract === null) return (await viewAccount(accountId)) ?? 0n;
      if ((await viewAccount(accountId)) === null) return 0n;
      return BigInt(((await call(contract, 'ft_balance_of', { account_id: accountId })) as string | null) ?? '0');
    },
    async storageRegistered(contract, accountId) {
      const r = await call(contract, 'storage_balance_of', { account_id: accountId });
      return r !== null && r !== undefined;
    },
    async storageMin(contract) {
      return BigInt(((await call(contract, 'storage_balance_bounds', {})) as { min: string }).min);
    },
  };
}
