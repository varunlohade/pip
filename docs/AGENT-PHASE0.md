# Agent Phase 0 results

Phase 0 of `docs/AGENT-ARCHITECTURE.md` §5: prove the model choices before any product code.

Status on 2026-11-14: **the harness is ready, but no live numbers exist yet.** This machine has no `.env` with
`OPENROUTER_API_KEY` or `TYPESAFE_API_KEY` (the brief named `server/.env`; neither it nor the root `.env` exists).
Every cell marked "not measured" waits for a key.

## Files

| File | What it holds |
|---|---|
| `server/eval/agent-tools.jsonl` | 20 tool-call prompts (task 0.1). Each has the chat so far, fake tool results where needed, and the expected tool plus argument checks. |
| `server/eval/jev-routes.jsonl` | 40 route labels (task 0.3): 10 each of instant, recipe, open, none. |
| `server/scripts/phase0-eval.ts` | The run script for 0.2 and 0.3. |

Case mix in `agent-tools.jsonl`: search_web 5, read_web 4, ask_user 4, finish_job 4, refuse 3.
The read_web and finish_job cases carry fake search and page results in the history, so they test the step after a tool result.

A case passes only when the model's first tool call has the expected name and its arguments pass the checks
(for example, read_web must pick the official URL from fake search results; ask_user must give 2 or more options).
A plain-text answer with no tool call fails.

## How to run

```
cd server
node --env-file=../.env scripts/phase0-eval.ts tools            # Llama 3.3 70B, Qwen3 235B A22B 2507, DeepSeek V3.2
node --env-file=../.env scripts/phase0-eval.ts tools <model ...> # other OpenRouter model ids
node --env-file=../.env scripts/phase0-eval.ts jev
```

- Spend cap: `--cap 3` (default $3). The script keeps a running total in `server/eval/results/spend.json`
  and stops before a call whose worst case could pass the cap.
- Cost per call comes from OpenRouter's `usage.cost` in the response.
- Llama uses Pip's production route (Groq first, `server/src/config.ts`). The others use OpenRouter's default routing.
- `--dry` answers every call locally to test the harness. Dry runs cost nothing and are not results.
- Raw per-case results land in `server/eval/results/tools.json` and `jev.json`.

## 0.2 Tool-call check

| Model | Open weights | List price $/M in / out | Pass (of 20) | p50 latency | p95 latency | Cost per prompt |
|---|---|---|---|---|---|---|
| meta-llama/llama-3.3-70b-instruct | yes | 0.71 / 0.71 | not measured | not measured | not measured | not measured |
| qwen/qwen3-235b-a22b-2507 | yes | 0.14 / 0.80 | not measured | not measured | not measured | not measured |
| deepseek/deepseek-v3.2 | yes | 0.26 / 0.38 | not measured | not measured | not measured | not measured |

List prices come from OpenRouter's public `/api/v1/models` list, read on 2026-11-14. They are not measured spend.

**Pick:** not made. The rule is: the cheapest model with 18 or more passes out of 20.

## 0.3 jev routing

Route criteria sent to jev (`jev-latest`, one choice question per text):

| Label | Criterion |
|---|---|
| instant | One quick thing the keyboard does at once with no web search: rewrite, fix, shorten or translate text, explain a word, or add a reminder, event or note. |
| recipe | A single lookup with a fixed shape: search the web or read one page, then give an answer or a few picks. |
| open | A bigger job with several steps: planning, research across many sources, the person's mail or calendar, watching something over time, or drafting after research. |
| none | Ordinary chat to another person, not a request for Pip at all. |

| Metric | Value |
|---|---|
| Accuracy (of 40) | not measured |
| p50 / p95 latency | not measured |
| Confusion matrix | not measured |
| Cost per call | not measured |

Target from §5: 90% or more, or we add rules.

## Harness check (dry run, no network)

- `tools --dry`: the fake model calls the expected tool with empty arguments. Result: 3/20 for each model.
  Only the 3 refuse cases pass, because every other case checks its arguments. This shows that a right tool name with wrong arguments fails.
- `jev --dry`: the fake returns the expected label. Result: 40/40, and the confusion matrix sums to 10 per label.

## Spend

OpenRouter: $0.00. TypeSafe: $0.00. No live call ran.
