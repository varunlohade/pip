/** NEP-145 storage views on any NEAR token contract. Tests pass a fake. */
export type NearViews = {
  storageRegistered(contract: string, accountId: string): Promise<boolean>;
  storageMin(contract: string): Promise<bigint>;
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
  return {
    async storageRegistered(contract, accountId) {
      const r = await call(contract, 'storage_balance_of', { account_id: accountId });
      return r !== null && r !== undefined;
    },
    async storageMin(contract) {
      return BigInt(((await call(contract, 'storage_balance_bounds', {})) as { min: string }).min);
    },
  };
}
