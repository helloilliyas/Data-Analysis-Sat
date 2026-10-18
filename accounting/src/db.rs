//! SQLite storage: accounts, categories, transactions, settings and reports.
//!
//! Money is stored as integer cents. A positive amount is money coming in
//! (income, refunds), a negative amount is money going out (spending).

use anyhow::{Context, Result, anyhow, bail};
use rusqlite::{Connection, OptionalExtension, params, params_from_iter, types::Value};
use serde::{Deserialize, Serialize};

pub const ACCOUNT_KINDS: &[&str] = &["checking", "savings", "credit_card", "cash", "investment", "loan"];
pub const CATEGORY_KINDS: &[&str] = &["income", "expense", "transfer"];

const DEFAULT_CATEGORIES: &[(&str, &str)] = &[
    ("Salary", "income"),
    ("Other Income", "income"),
    ("Interest & Dividends", "income"),
    ("Groceries", "expense"),
    ("Dining Out", "expense"),
    ("Rent & Mortgage", "expense"),
    ("Utilities", "expense"),
    ("Phone & Internet", "expense"),
    ("Transportation", "expense"),
    ("Fuel", "expense"),
    ("Insurance", "expense"),
    ("Healthcare", "expense"),
    ("Shopping", "expense"),
    ("Entertainment", "expense"),
    ("Subscriptions", "expense"),
    ("Travel", "expense"),
    ("Education", "expense"),
    ("Gifts & Donations", "expense"),
    ("Fees & Charges", "expense"),
    ("Taxes", "expense"),
    ("Other Expense", "expense"),
    ("Transfer", "transfer"),
];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Account {
    pub id: i64,
    pub name: String,
    pub kind: String,
    pub opening_balance_cents: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewAccount {
    pub name: String,
    pub kind: String,
    #[serde(default)]
    pub opening_balance_cents: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Category {
    pub id: i64,
    pub name: String,
    pub kind: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewCategory {
    pub name: String,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Transaction {
    pub id: i64,
    pub date: String,
    pub description: String,
    pub merchant: Option<String>,
    pub amount_cents: i64,
    pub account_id: i64,
    pub account_name: String,
    pub category_id: Option<i64>,
    pub category_name: Option<String>,
    pub notes: Option<String>,
    pub categorized_by: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewTransaction {
    pub date: String,
    pub description: String,
    #[serde(default)]
    pub merchant: Option<String>,
    pub amount_cents: i64,
    pub account_id: i64,
    #[serde(default)]
    pub category_id: Option<i64>,
    #[serde(default)]
    pub notes: Option<String>,
    /// "manual", "history" or "claude".
    #[serde(default)]
    pub categorized_by: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct TransactionFilter {
    /// "YYYY-MM"
    pub month: Option<String>,
    pub account_id: Option<i64>,
    pub category_id: Option<i64>,
    /// Matched case-insensitively against category name.
    pub category: Option<String>,
    /// Free-text search over description, merchant and notes.
    pub q: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct CategoryTotal {
    pub category_id: Option<i64>,
    pub name: String,
    pub kind: String,
    pub total_cents: i64,
    pub count: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct MonthTotal {
    pub month: String,
    pub income_cents: i64,
    pub expense_cents: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct AccountBalance {
    pub id: i64,
    pub name: String,
    pub kind: String,
    pub balance_cents: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Summary {
    pub month: String,
    /// Money in, excluding transfers.
    pub income_cents: i64,
    /// Money out as a positive number, excluding transfers.
    pub expense_cents: i64,
    pub net_cents: i64,
    pub transaction_count: i64,
    pub uncategorized_count: i64,
    pub by_category: Vec<CategoryTotal>,
    pub trend: Vec<MonthTotal>,
    pub balances: Vec<AccountBalance>,
    pub net_worth_cents: i64,
}

pub struct Db {
    conn: Connection,
}

impl Db {
    pub fn open(path: &str) -> Result<Self> {
        let conn = Connection::open(path).with_context(|| format!("opening database {path}"))?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS accounts (
                 id INTEGER PRIMARY KEY,
                 name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                 kind TEXT NOT NULL,
                 opening_balance_cents INTEGER NOT NULL DEFAULT 0,
                 created_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE TABLE IF NOT EXISTS categories (
                 id INTEGER PRIMARY KEY,
                 name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                 kind TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS transactions (
                 id INTEGER PRIMARY KEY,
                 date TEXT NOT NULL,
                 description TEXT NOT NULL,
                 merchant TEXT,
                 amount_cents INTEGER NOT NULL,
                 account_id INTEGER NOT NULL REFERENCES accounts(id),
                 category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
                 notes TEXT,
                 categorized_by TEXT,
                 created_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE INDEX IF NOT EXISTS idx_tx_date ON transactions(date);
             CREATE INDEX IF NOT EXISTS idx_tx_merchant ON transactions(lower(merchant));
             CREATE TABLE IF NOT EXISTS settings (
                 key TEXT PRIMARY KEY,
                 value TEXT NOT NULL
             );",
        )?;
        let db = Db { conn };
        let count: i64 = db.conn.query_row("SELECT COUNT(*) FROM categories", [], |r| r.get(0))?;
        if count == 0 {
            for (name, kind) in DEFAULT_CATEGORIES {
                db.conn.execute("INSERT INTO categories (name, kind) VALUES (?1, ?2)", params![name, kind])?;
            }
        }
        Ok(db)
    }

    // ---- accounts -------------------------------------------------------

    pub fn list_accounts(&self) -> Result<Vec<Account>> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, name, kind, opening_balance_cents FROM accounts ORDER BY name")?;
        let rows = stmt.query_map([], |r| {
            Ok(Account { id: r.get(0)?, name: r.get(1)?, kind: r.get(2)?, opening_balance_cents: r.get(3)? })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn create_account(&self, a: &NewAccount) -> Result<Account> {
        let name = a.name.trim();
        if name.is_empty() {
            bail!("account name is required");
        }
        if !ACCOUNT_KINDS.contains(&a.kind.as_str()) {
            bail!("account kind must be one of {}", ACCOUNT_KINDS.join(", "));
        }
        self.conn
            .execute(
                "INSERT INTO accounts (name, kind, opening_balance_cents) VALUES (?1, ?2, ?3)",
                params![name, a.kind, a.opening_balance_cents],
            )
            .map_err(|e| unique_err(e, "an account with that name already exists"))?;
        Ok(Account {
            id: self.conn.last_insert_rowid(),
            name: name.to_string(),
            kind: a.kind.clone(),
            opening_balance_cents: a.opening_balance_cents,
        })
    }

    pub fn delete_account(&self, id: i64) -> Result<()> {
        let used: i64 =
            self.conn.query_row("SELECT COUNT(*) FROM transactions WHERE account_id = ?1", [id], |r| r.get(0))?;
        if used > 0 {
            bail!("account has {used} transactions; delete or move them first");
        }
        self.conn.execute("DELETE FROM accounts WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn find_account_by_name(&self, name: &str) -> Result<Option<Account>> {
        Ok(self
            .conn
            .query_row(
                "SELECT id, name, kind, opening_balance_cents FROM accounts WHERE name = ?1 COLLATE NOCASE",
                [name.trim()],
                |r| Ok(Account { id: r.get(0)?, name: r.get(1)?, kind: r.get(2)?, opening_balance_cents: r.get(3)? }),
            )
            .optional()?)
    }

    // ---- categories -----------------------------------------------------

    pub fn list_categories(&self) -> Result<Vec<Category>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, kind FROM categories
             ORDER BY CASE kind WHEN 'income' THEN 0 WHEN 'expense' THEN 1 ELSE 2 END, name",
        )?;
        let rows = stmt.query_map([], |r| Ok(Category { id: r.get(0)?, name: r.get(1)?, kind: r.get(2)? }))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn create_category(&self, c: &NewCategory) -> Result<Category> {
        let name = c.name.trim();
        if name.is_empty() {
            bail!("category name is required");
        }
        if !CATEGORY_KINDS.contains(&c.kind.as_str()) {
            bail!("category kind must be one of {}", CATEGORY_KINDS.join(", "));
        }
        self.conn
            .execute("INSERT INTO categories (name, kind) VALUES (?1, ?2)", params![name, c.kind])
            .map_err(|e| unique_err(e, "a category with that name already exists"))?;
        Ok(Category { id: self.conn.last_insert_rowid(), name: name.to_string(), kind: c.kind.clone() })
    }

    pub fn delete_category(&self, id: i64) -> Result<()> {
        self.conn.execute("DELETE FROM categories WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn find_category_by_name(&self, name: &str) -> Result<Option<Category>> {
        Ok(self
            .conn
            .query_row(
                "SELECT id, name, kind FROM categories WHERE name = ?1 COLLATE NOCASE",
                [name.trim()],
                |r| Ok(Category { id: r.get(0)?, name: r.get(1)?, kind: r.get(2)? }),
            )
            .optional()?)
    }

    // ---- transactions ---------------------------------------------------

    pub fn create_transaction(&self, t: &NewTransaction) -> Result<Transaction> {
        validate_tx(t)?;
        self.conn.execute(
            "INSERT INTO transactions
                (date, description, merchant, amount_cents, account_id, category_id, notes, categorized_by)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                t.date,
                t.description.trim(),
                clean(&t.merchant),
                t.amount_cents,
                t.account_id,
                t.category_id,
                clean(&t.notes),
                categorized_by(t),
            ],
        )?;
        self.get_transaction(self.conn.last_insert_rowid())
    }

    pub fn update_transaction(&self, id: i64, t: &NewTransaction) -> Result<Transaction> {
        validate_tx(t)?;
        let changed = self.conn.execute(
            "UPDATE transactions SET date = ?1, description = ?2, merchant = ?3, amount_cents = ?4,
                account_id = ?5, category_id = ?6, notes = ?7, categorized_by = ?8
             WHERE id = ?9",
            params![
                t.date,
                t.description.trim(),
                clean(&t.merchant),
                t.amount_cents,
                t.account_id,
                t.category_id,
                clean(&t.notes),
                categorized_by(t),
                id,
            ],
        )?;
        if changed == 0 {
            bail!("transaction {id} not found");
        }
        self.get_transaction(id)
    }

    pub fn delete_transaction(&self, id: i64) -> Result<()> {
        self.conn.execute("DELETE FROM transactions WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn get_transaction(&self, id: i64) -> Result<Transaction> {
        let sql = format!("{TX_SELECT} WHERE t.id = ?1");
        self.conn.query_row(&sql, [id], tx_from_row).optional()?.ok_or_else(|| anyhow!("transaction {id} not found"))
    }

    pub fn list_transactions(&self, f: &TransactionFilter) -> Result<Vec<Transaction>> {
        let mut sql = format!("{TX_SELECT} WHERE 1 = 1");
        let mut args: Vec<Value> = Vec::new();
        if let Some(month) = f.month.as_deref().filter(|m| !m.is_empty()) {
            check_month(month)?;
            sql.push_str(" AND substr(t.date, 1, 7) = ?");
            args.push(month.to_string().into());
        }
        if let Some(id) = f.account_id {
            sql.push_str(" AND t.account_id = ?");
            args.push(id.into());
        }
        if let Some(id) = f.category_id {
            sql.push_str(" AND t.category_id = ?");
            args.push(id.into());
        }
        if let Some(name) = f.category.as_deref().filter(|c| !c.is_empty()) {
            if name.eq_ignore_ascii_case("uncategorized") {
                sql.push_str(" AND t.category_id IS NULL");
            } else {
                sql.push_str(" AND c.name = ? COLLATE NOCASE");
                args.push(name.to_string().into());
            }
        }
        if let Some(q) = f.q.as_deref().map(str::trim).filter(|q| !q.is_empty()) {
            sql.push_str(
                " AND (t.description LIKE ? ESCAPE '\\' OR t.merchant LIKE ? ESCAPE '\\' OR t.notes LIKE ? ESCAPE '\\')",
            );
            let pattern = format!("%{}%", q.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
            for _ in 0..3 {
                args.push(pattern.clone().into());
            }
        }
        sql.push_str(" ORDER BY t.date DESC, t.id DESC LIMIT ?");
        args.push(f.limit.unwrap_or(200).clamp(1, 2000).into());
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args), tx_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// The category most recently used for this merchant (or, failing that,
    /// this exact description). Lets repeat purchases skip the Claude call.
    pub fn category_from_history(&self, merchant: Option<&str>, description: &str) -> Result<Option<Category>> {
        let sql = "SELECT c.id, c.name, c.kind FROM transactions t JOIN categories c ON c.id = t.category_id
                   WHERE lower(trim(t.{field})) = lower(trim(?1))
                   ORDER BY t.date DESC, t.id DESC LIMIT 1";
        let candidates = [("merchant", merchant.unwrap_or("")), ("description", description)];
        for (field, value) in candidates {
            if value.trim().is_empty() {
                continue;
            }
            let found = self
                .conn
                .query_row(&sql.replace("{field}", field), [value], |r| {
                    Ok(Category { id: r.get(0)?, name: r.get(1)?, kind: r.get(2)? })
                })
                .optional()?;
            if found.is_some() {
                return Ok(found);
            }
        }
        Ok(None)
    }

    // ---- reports --------------------------------------------------------

    pub fn summary(&self, month: &str, trend_months: u32) -> Result<Summary> {
        check_month(month)?;
        let (income_cents, expense_cents, transaction_count, uncategorized_count): (i64, i64, i64, i64) =
            self.conn.query_row(
                "SELECT
                    COALESCE(SUM(CASE WHEN t.amount_cents > 0 AND COALESCE(c.kind, '') <> 'transfer' THEN t.amount_cents END), 0),
                    COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND COALESCE(c.kind, '') <> 'transfer' THEN -t.amount_cents END), 0),
                    COUNT(*),
                    COALESCE(SUM(CASE WHEN t.category_id IS NULL THEN 1 END), 0)
                 FROM transactions t LEFT JOIN categories c ON c.id = t.category_id
                 WHERE substr(t.date, 1, 7) = ?1",
                [month],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )?;

        let mut stmt = self.conn.prepare(
            "SELECT c.id, COALESCE(c.name, 'Uncategorized'), COALESCE(c.kind, 'expense'),
                    SUM(t.amount_cents), COUNT(*)
             FROM transactions t LEFT JOIN categories c ON c.id = t.category_id
             WHERE substr(t.date, 1, 7) = ?1
             GROUP BY c.id
             ORDER BY ABS(SUM(t.amount_cents)) DESC",
        )?;
        let by_category = stmt
            .query_map([month], |r| {
                Ok(CategoryTotal {
                    category_id: r.get(0)?,
                    name: r.get(1)?,
                    kind: r.get(2)?,
                    total_cents: r.get(3)?,
                    count: r.get(4)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;

        let mut trend = Vec::new();
        for m in previous_months(month, trend_months)? {
            let (inc, exp): (i64, i64) = self.conn.query_row(
                "SELECT
                    COALESCE(SUM(CASE WHEN t.amount_cents > 0 AND COALESCE(c.kind, '') <> 'transfer' THEN t.amount_cents END), 0),
                    COALESCE(SUM(CASE WHEN t.amount_cents < 0 AND COALESCE(c.kind, '') <> 'transfer' THEN -t.amount_cents END), 0)
                 FROM transactions t LEFT JOIN categories c ON c.id = t.category_id
                 WHERE substr(t.date, 1, 7) = ?1",
                [&m],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            trend.push(MonthTotal { month: m, income_cents: inc, expense_cents: exp });
        }

        let balances = self.balances()?;
        let net_worth_cents = balances.iter().map(|b| b.balance_cents).sum();
        Ok(Summary {
            month: month.to_string(),
            income_cents,
            expense_cents,
            net_cents: income_cents - expense_cents,
            transaction_count,
            uncategorized_count,
            by_category,
            trend,
            balances,
            net_worth_cents,
        })
    }

    /// Current balance of every account: opening balance plus all transactions.
    pub fn balances(&self) -> Result<Vec<AccountBalance>> {
        let mut stmt = self.conn.prepare(
            "SELECT a.id, a.name, a.kind, a.opening_balance_cents + COALESCE(SUM(t.amount_cents), 0)
             FROM accounts a LEFT JOIN transactions t ON t.account_id = a.id
             GROUP BY a.id ORDER BY a.name",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(AccountBalance { id: r.get(0)?, name: r.get(1)?, kind: r.get(2)?, balance_cents: r.get(3)? })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    // ---- settings -------------------------------------------------------

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        Ok(self.conn.query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0)).optional()?)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

const TX_SELECT: &str = "SELECT t.id, t.date, t.description, t.merchant, t.amount_cents, t.account_id, a.name,
        t.category_id, c.name, t.notes, t.categorized_by
     FROM transactions t
     JOIN accounts a ON a.id = t.account_id
     LEFT JOIN categories c ON c.id = t.category_id";

fn tx_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Transaction> {
    Ok(Transaction {
        id: r.get(0)?,
        date: r.get(1)?,
        description: r.get(2)?,
        merchant: r.get(3)?,
        amount_cents: r.get(4)?,
        account_id: r.get(5)?,
        account_name: r.get(6)?,
        category_id: r.get(7)?,
        category_name: r.get(8)?,
        notes: r.get(9)?,
        categorized_by: r.get(10)?,
    })
}

fn validate_tx(t: &NewTransaction) -> Result<()> {
    chrono::NaiveDate::parse_from_str(&t.date, "%Y-%m-%d").context("date must be YYYY-MM-DD")?;
    if t.description.trim().is_empty() {
        bail!("description is required");
    }
    if t.amount_cents == 0 {
        bail!("amount must not be zero");
    }
    Ok(())
}

fn categorized_by(t: &NewTransaction) -> Option<String> {
    t.category_id?;
    Some(t.categorized_by.clone().unwrap_or_else(|| "manual".into()))
}

fn clean(s: &Option<String>) -> Option<&str> {
    s.as_deref().map(str::trim).filter(|s| !s.is_empty())
}

fn unique_err(e: rusqlite::Error, msg: &str) -> anyhow::Error {
    match e {
        rusqlite::Error::SqliteFailure(f, _) if f.code == rusqlite::ErrorCode::ConstraintViolation => anyhow!("{msg}"),
        other => other.into(),
    }
}

pub fn check_month(month: &str) -> Result<()> {
    chrono::NaiveDate::parse_from_str(&format!("{month}-01"), "%Y-%m-%d").context("month must be YYYY-MM")?;
    Ok(())
}

/// `count` months ending with `month`, oldest first.
fn previous_months(month: &str, count: u32) -> Result<Vec<String>> {
    check_month(month)?;
    let year: i32 = month[..4].parse()?;
    let mon: i32 = month[5..7].parse()?;
    let end = year * 12 + (mon - 1);
    Ok((0..count as i32)
        .rev()
        .map(|back| {
            let idx = end - back;
            format!("{:04}-{:02}", idx.div_euclid(12), idx.rem_euclid(12) + 1)
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> (Db, Account) {
        let db = Db::open_in_memory().unwrap();
        let acct = db
            .create_account(&NewAccount { name: "Chequing".into(), kind: "checking".into(), opening_balance_cents: 100_000 })
            .unwrap();
        (db, acct)
    }

    fn tx(db: &Db, acct: i64, date: &str, desc: &str, merchant: Option<&str>, cents: i64, cat: Option<&str>) -> Transaction {
        let category_id = cat.map(|c| db.find_category_by_name(c).unwrap().unwrap().id);
        db.create_transaction(&NewTransaction {
            date: date.into(),
            description: desc.into(),
            merchant: merchant.map(Into::into),
            amount_cents: cents,
            account_id: acct,
            category_id,
            notes: None,
            categorized_by: None,
        })
        .unwrap()
    }

    #[test]
    fn seeds_default_categories_once() {
        let db = Db::open_in_memory().unwrap();
        let n = db.list_categories().unwrap().len();
        assert_eq!(n, DEFAULT_CATEGORIES.len());
        let db2 = Db::init(db.conn).unwrap();
        assert_eq!(db2.list_categories().unwrap().len(), n);
    }

    #[test]
    fn rejects_bad_input() {
        let (db, acct) = setup();
        let mut t = NewTransaction {
            date: "2026-13-01".into(),
            description: "x".into(),
            merchant: None,
            amount_cents: 100,
            account_id: acct.id,
            category_id: None,
            notes: None,
            categorized_by: None,
        };
        assert!(db.create_transaction(&t).is_err());
        t.date = "2026-10-01".into();
        t.amount_cents = 0;
        assert!(db.create_transaction(&t).is_err());
        assert!(db.create_account(&NewAccount { name: "chequing".into(), kind: "checking".into(), opening_balance_cents: 0 }).is_err());
        assert!(db.create_account(&NewAccount { name: "X".into(), kind: "piggy".into(), opening_balance_cents: 0 }).is_err());
    }

    #[test]
    fn summary_excludes_transfers_and_computes_balances() {
        let (db, acct) = setup();
        tx(&db, acct.id, "2026-10-01", "Paycheque", None, 500_000, Some("Salary"));
        tx(&db, acct.id, "2026-10-03", "Weekly shop", Some("Safeway"), -12_345, Some("Groceries"));
        tx(&db, acct.id, "2026-10-04", "Dinner", None, -4_000, None);
        tx(&db, acct.id, "2026-10-05", "To savings", None, -50_000, Some("Transfer"));
        tx(&db, acct.id, "2026-09-15", "Old shop", None, -1_000, Some("Groceries"));

        let s = db.summary("2026-10", 3).unwrap();
        assert_eq!(s.income_cents, 500_000);
        assert_eq!(s.expense_cents, 16_345);
        assert_eq!(s.net_cents, 500_000 - 16_345);
        assert_eq!(s.transaction_count, 4);
        assert_eq!(s.uncategorized_count, 1);
        assert_eq!(s.trend.iter().map(|m| m.month.as_str()).collect::<Vec<_>>(), ["2026-08", "2026-09", "2026-10"]);
        assert_eq!(s.trend[1].expense_cents, 1_000);
        assert_eq!(s.balances[0].balance_cents, 100_000 + 500_000 - 12_345 - 4_000 - 50_000 - 1_000);
        let groceries = s.by_category.iter().find(|c| c.name == "Groceries").unwrap();
        assert_eq!((groceries.total_cents, groceries.count), (-12_345, 1));
        assert!(s.by_category.iter().any(|c| c.name == "Uncategorized"));
    }

    #[test]
    fn filters_and_history_lookup() {
        let (db, acct) = setup();
        tx(&db, acct.id, "2026-10-03", "Weekly shop", Some("Safeway"), -12_345, Some("Groceries"));
        tx(&db, acct.id, "2026-10-04", "50% off_sale", None, -500, Some("Shopping"));
        tx(&db, acct.id, "2026-09-04", "Coffee", Some("Starbucks"), -500, None);

        let f = |q: &str| TransactionFilter { q: Some(q.into()), ..Default::default() };
        assert_eq!(db.list_transactions(&f("safe")).unwrap().len(), 1);
        assert_eq!(db.list_transactions(&f("%")).unwrap().len(), 1, "% is matched literally");
        let oct = TransactionFilter { month: Some("2026-10".into()), ..Default::default() };
        assert_eq!(db.list_transactions(&oct).unwrap().len(), 2);
        let unc = TransactionFilter { category: Some("uncategorized".into()), ..Default::default() };
        assert_eq!(db.list_transactions(&unc).unwrap()[0].description, "Coffee");

        let hit = db.category_from_history(Some("SAFEWAY "), "something else").unwrap().unwrap();
        assert_eq!(hit.name, "Groceries");
        assert_eq!(db.category_from_history(None, "50% OFF_SALE").unwrap().unwrap().name, "Shopping");
        assert!(db.category_from_history(Some("Starbucks"), "Coffee").unwrap().is_none());
    }

    #[test]
    fn previous_months_wraps_years() {
        assert_eq!(previous_months("2026-02", 3).unwrap(), ["2025-12", "2026-01", "2026-02"]);
    }

    #[test]
    fn account_with_transactions_cannot_be_deleted() {
        let (db, acct) = setup();
        tx(&db, acct.id, "2026-10-03", "x", None, -1, None);
        assert!(db.delete_account(acct.id).is_err());
    }
}
