# Ledger — personal accounting app (Rust)

A Digits-style personal bookkeeping app: one Rust binary (Axum + SQLite)
serving a phone-friendly web UI, with the Claude API for reading receipts,
understanding spoken/typed entries, categorizing, Q&A and file reports.

**Decisions:** currency CAD (amounts stored as integer cents, shown as
`$1,234.56`); voice via browser speech recognition first; every Claude-made
entry goes through an editable confirmation screen before it is saved.

## Data entry
1. **Manual form** — date, description, merchant, amount, account, category.
2. **Photo** — receipt, bill or bank screenshot; Claude extracts a draft
   (date, merchant, total, GST, suggested category, optional line items).
3. **Voice (Wispr Flow-style)** — hold-to-talk mic using the browser's
   speech recognition (Chrome/Android, Safari/iOS); the live transcript is
   editable, then Claude turns it into one or more drafts.
4. **Typed shorthand** — e.g. "coffee 5.25 cash", same parser as voice.

### Confirmation screen (all Claude-made entries)
- One editable card per draft: date, description, merchant, amount, money
  in/out, account, category, notes.
- Fields Claude was unsure of are highlighted; the source (photo thumbnail or
  transcript) is shown for reference.
- Per card: **Save**, **Edit**, **Discard**; plus **Save all**.
- Nothing reaches the database until the user taps Save.

### Skills at entry time
- Skills live on the user's Anthropic API account (uploaded once via
  platform.claude.com or the app's Settings); the app lists them live.
- Entry screen shows skill chips to tap per entry, plus an **Auto** option
  (send enabled skills, Claude uses the relevant ones). No chip selected =
  fast plain request.
- Settings can mark a skill "always on" for photo or voice entry.
- A starter custom skill `skills/ledger-entry-rules/SKILL.md` ships in the repo.
- A cheaper **My rules** text box in Settings is sent with every entry request.

## Categorization
- History first: a merchant seen before reuses its last category (free).
- Otherwise Claude suggests one via structured output restricted to the
  user's existing categories. Corrections feed the history rule.

## Dashboard
Monthly income / spending / net, by-category breakdown, 6-month trend, account
balances, net worth, uncategorized queue. Transfers are excluded from income
and spending.

## Ask Claude
Chat over your data with read-only tools plus an add-transaction tool whose
result goes to the same confirmation screen. Enabled Skills (Anthropic
xlsx/docx/pptx/pdf plus custom) can produce downloadable reports.

## Security & config
Env vars: `ANTHROPIC_API_KEY`, `DATABASE_PATH`, `HOST`, `PORT`,
`APP_PASSWORD`. Binds to localhost by default; for phone access set
`HOST=0.0.0.0` together with `APP_PASSWORD` (HTTP Basic auth). Browser
speech recognition needs HTTPS (or localhost) on the phone — README covers a
tunnel option (e.g. Tailscale/Cloudflare Tunnel).

## Phases
| Phase | Scope |
|---|---|
| 1 | Server, accounts, categories, manual entry, dashboard, mobile UI, CAD formatting, auth, tests |
| 2 | Claude categorization, photo entry, voice/typed entry, confirmation screen, skill chips + My rules |
| 3 | Ask Claude chat with data tools + Skills file download, skills settings and upload |
| 4 (optional) | Local Whisper, stored receipt images, CSV export/import, budgets, recurring bills |

## Status
- [x] Cargo project and SQLite layer (`src/db.rs`) with unit tests
- [ ] Phase 1
- [ ] Phase 2
- [ ] Phase 3
