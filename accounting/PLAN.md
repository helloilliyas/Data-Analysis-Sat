# Ledger — personal accounting app (Rust)

A Digits-style personal bookkeeping app: one Rust binary (Axum + SQLite)
serving a phone-friendly web UI, with the Claude API for reading receipts,
understanding spoken/typed entries, categorizing, Q&A and file reports.

## Data entry
1. **Manual form** — date, description, merchant, amount, account, category.
2. **Photo** — receipt, bill or bank screenshot; Claude extracts a draft
   (date, merchant, total, suggested category, optional line items). The user
   confirms before anything is saved.
3. **Voice (Wispr Flow-style)** — hold-to-talk; speech becomes text, then
   Claude turns it into one or more draft transactions to confirm.
   - Phase 1: browser speech recognition (Chrome/Android, Safari/iOS), with
     keyboard dictation as fallback. The Claude API has no audio input.
   - Optional later: local Whisper in the server (`whisper-rs`).
4. **Typed shorthand** — e.g. "coffee 5.25 cash", same parser as voice.

## Categorization
- History first: a merchant seen before reuses its last category (free).
- Otherwise Claude suggests one via structured output restricted to the
  user's existing categories. Corrections feed the history rule.

## Dashboard
Monthly income / spending / net, by-category breakdown, 6-month trend, account
balances, net worth, uncategorized queue. Transfers are excluded from income
and spending.

## Ask Claude
Chat over your data with read-only tools plus a confirm-gated add-transaction
tool. Claude Skills (Anthropic xlsx/docx/pptx/pdf plus custom skills from the
account) can be enabled in Settings to produce downloadable reports.

## Security & config
Env vars: `ANTHROPIC_API_KEY`, `DATABASE_PATH`, `HOST`, `PORT`,
`APP_PASSWORD`. Binds to localhost by default; for phone access set
`HOST=0.0.0.0` together with `APP_PASSWORD` (HTTP Basic auth).

## Phases
| Phase | Scope |
|---|---|
| 1 | Database, accounts, categories, manual entry, dashboard, mobile UI, auth, tests |
| 2 | Claude categorization, photo entry, voice/typed entry with draft confirmation |
| 3 | Ask Claude chat with data tools + Skills (file download), skills settings |
| 4 (optional) | Local Whisper, stored receipt images, CSV export/import, budgets, recurring bills |

## Status
- [x] Cargo project and SQLite layer (`src/db.rs`) with unit tests
- [ ] Everything else above
