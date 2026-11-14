// Web search for agent tasks ("hotels near BKC"). Adapted from OpenMuse apps/server/src/web-search.ts
// (MIT, Copyright (c) 2026 OpenMuse contributors): the Brave Search adapter, with its result cleaning and link checks.
export type SearchResult = { title: string; url: string; snippet: string };
export type SearchProvider = (query: string, signal?: AbortSignal) => Promise<SearchResult[]>;

const plain = (value: unknown) =>
  typeof value === 'string'
    ? value.replace(/<[^>]*>/g, '').replace(/&quot;/g, '"').replace(/&#x27;|&#39;/g, "'").replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim()
    : '';

/** Only http(s) links. */
function httpUrl(href: unknown): string {
  if (typeof href !== 'string') return '';
  try {
    const u = new URL(href);
    return u.protocol === 'http:' || u.protocol === 'https:' ? u.href : '';
  } catch {
    return '';
  }
}

/** Maps a Brave Search web response to results, keeping only http(s) links. */
export function parseBrave(body: unknown, limit = 6): SearchResult[] {
  const results = (body as { web?: { results?: unknown } })?.web?.results;
  if (!Array.isArray(results)) return [];
  return results
    .map((item: { title?: unknown; url?: unknown; description?: unknown }) => ({
      title: plain(item.title).slice(0, 200), url: httpUrl(item.url), snippet: plain(item.description).slice(0, 300),
    }))
    .filter((r) => r.url && r.title)
    .slice(0, limit);
}

export function braveSearch(apiKey: string): SearchProvider {
  return async (query, signal) => {
    const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=8`;
    const timeout = AbortSignal.timeout(10_000);
    const r = await fetch(url, {
      headers: { Accept: 'application/json', 'X-Subscription-Token': apiKey },
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    });
    if (!r.ok) throw new Error(`search failed: ${r.status}`);
    return parseBrave(await r.json());
  };
}

/** The live provider, or undefined when BRAVE_SEARCH_API_KEY is not set. */
export const defaultSearch = (env = process.env): SearchProvider | undefined =>
  env.BRAVE_SEARCH_API_KEY ? braveSearch(env.BRAVE_SEARCH_API_KEY) : undefined;
