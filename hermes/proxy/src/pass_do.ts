import { DurableObject } from "cloudflare:workers";

export interface PassState {
  exists: boolean;
  status: "active" | "revoked";
  budgetMicros: number;
  budgetTotalMicros: number;
}

export class PassDO extends DurableObject {
  sql = this.ctx.storage.sql;

  constructor(ctx: DurableObjectState, env: any) {
    super(ctx, env);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS pass (
      id INTEGER PRIMARY KEY,
      budget_micros INTEGER NOT NULL,
      budget_total_micros INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'active',
      email TEXT,
      created_at INTEGER,
      updated_at INTEGER
    );`);
  }

  init(budgetMicros: number, email: string): void {
    const now = Date.now();
    this.sql.exec(
      `INSERT INTO pass (id, budget_micros, budget_total_micros, status, email, created_at, updated_at)
       VALUES (1, ?, ?, 'active', ?, ?, ?)
       ON CONFLICT(id) DO NOTHING;`,
      budgetMicros, budgetMicros, email, now, now);
  }

  state(): PassState {
    const row = this.sql.exec(`SELECT budget_micros, budget_total_micros, status FROM pass WHERE id = 1`).toArray()[0] as any;
    if (!row) return { exists: false, status: "active", budgetMicros: 0, budgetTotalMicros: 0 };
    return {
      exists: true,
      status: row.status,
      budgetMicros: row.budget_micros,
      budgetTotalMicros: row.budget_total_micros,
    };
  }

  // Single-threaded DO => atomic. Returns the balance after debit.
  debit(costMicros: number): number {
    this.sql.exec(
      `UPDATE pass SET budget_micros = budget_micros - ?, updated_at = ? WHERE id = 1`,
      costMicros, Date.now());
    const row = this.sql.exec(`SELECT budget_micros FROM pass WHERE id = 1`).toArray()[0] as any;
    return row ? row.budget_micros : 0;
  }

  revoke(): void {
    this.sql.exec(`UPDATE pass SET status = 'revoked', updated_at = ? WHERE id = 1`, Date.now());
  }
}
