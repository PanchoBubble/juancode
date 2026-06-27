/**
 * A tiny *headless* VT screen model — just enough of a terminal emulator to
 * reconstruct what is currently rendered on the screen, so callers can read the
 * actual bottom rows instead of guessing from a flattened byte tail. It does NOT
 * render anything; it only tracks the cell grid, cursor, erases, scrolling, and
 * the alternate screen.
 *
 * Why this exists: `claude`/`codex` paint their "esc to interrupt" footer once
 * per turn and then only animate the timer digits via cursor moves — the phrase
 * is never re-emitted. A concatenated, ANSI-stripped tail therefore can't answer
 * "is the footer still on screen *right now*?", which is exactly what determines
 * the session status. A grid model can: the footer occupies real cells until the
 * CLI erases them at turn end. See `ActivityDetector`.
 *
 * Scope: both CLIs are full-screen TUIs on the terminal's *alternate* buffer, so
 * all the interesting content lands in a fixed `cols × rows` grid addressed with
 * absolute cursor moves and line erases — the slice of VT we implement. Wide /
 * combining glyphs are approximated as one cell each; we match *text content*,
 * not pixel layout, so that's fine. Mirrors `JuancodeCore/TerminalScreen.swift`.
 */
class ScreenBuffer {
  grid: string[][];
  row = 0;
  col = 0;
  savedRow = 0;
  savedCol = 0;
  constructor(width: number, height: number) {
    this.grid = Array.from({ length: height }, () =>
      Array.from({ length: width }, () => " "),
    );
  }
}

export class TerminalScreen {
  private width: number;
  private height: number;
  private main: ScreenBuffer;
  private alt: ScreenBuffer;
  private usingAlt = false;
  private autowrap = true;
  /**
   * Trailing chars of an escape sequence split across a `feed` boundary; pty
   * chunks split anywhere, and an un-buffered split is exactly what defeats a
   * naive regex. Prepended to the next feed.
   */
  private pending = "";

  constructor(cols: number, rows: number) {
    this.width = Math.max(1, cols);
    this.height = Math.max(1, rows);
    this.main = new ScreenBuffer(this.width, this.height);
    this.alt = new ScreenBuffer(this.width, this.height);
  }

  private get buf(): ScreenBuffer {
    return this.usingAlt ? this.alt : this.main;
  }

  /** Feed a chunk of decoded pty output, updating the grid. */
  feed(s: string): void {
    if (s.length === 0 && this.pending.length === 0) return;
    // Iterate by code point (Array.from splits surrogate pairs correctly).
    const cp = Array.from(this.pending + s);
    this.pending = "";
    this.process(cp);
  }

  /** Resize the grid, preserving overlapping content best-effort. */
  resize(cols: number, rows: number): void {
    const w = Math.max(1, cols);
    const h = Math.max(1, rows);
    if (w === this.width && h === this.height) return;
    this.main = this.resized(this.main, w, h);
    this.alt = this.resized(this.alt, w, h);
    this.width = w;
    this.height = h;
  }

  /**
   * The active buffer as text: rows joined by "\n", trailing spaces trimmed per
   * row, and trailing blank rows dropped.
   */
  get visibleText(): string {
    const rows = this.buf.grid.map((r) => rowString(r));
    let end = rows.length;
    while (end > 0 && rows[end - 1] === "") end--;
    return rows.slice(0, end).join("\n");
  }

  /**
   * Every row of the active buffer as text (trailing spaces trimmed per row),
   * always exactly `height` entries so callers can address rows by a stable
   * index and diff frame-to-frame. Used to stream the rendered screen to phone
   * clients as cheap per-row diffs (see `Session.onScreen`).
   */
  rows(): string[] {
    return this.buf.grid.map((r) => rowString(r));
  }

  /** The last `n` rows of the active buffer as text (footer / prompt region). */
  bottomText(n: number): string {
    return this.buf.grid
      .slice(Math.max(0, this.height - n))
      .map((r) => rowString(r))
      .join("\n");
  }

  // --- parser ---

  private process(cp: string[]): void {
    let i = 0;
    const n = cp.length;
    while (i < n) {
      const c = cp[i]!;
      if (c === "\x1b") {
        const consumed = this.handleEscape(cp, i);
        if (consumed === null) {
          // Incomplete escape at end of feed — stash and resume next time.
          this.pending = cp.slice(i).join("");
          return;
        }
        i = consumed;
      } else if (c.codePointAt(0)! < 0x20) {
        this.handleControl(c.codePointAt(0)!);
        i += 1;
      } else {
        this.putChar(c);
        i += 1;
      }
    }
  }

  /**
   * Handle an escape sequence starting at `cp[i]` (== ESC). Returns the index
   * just past the sequence, or null if incomplete (needs more input).
   */
  private handleEscape(cp: string[], i: number): number | null {
    const n = cp.length;
    if (i + 1 >= n) return null;
    const kind = cp[i + 1];
    switch (kind) {
      case "[": {
        // CSI: params/intermediates (0x20-0x3F) then a final byte (0x40-0x7E).
        let j = i + 2;
        while (j < n) {
          const v = cp[j]!.codePointAt(0)!;
          if (v < 0x20 || v > 0x3f) break;
          j++;
        }
        if (j >= n) return null;
        this.handleCsi(cp.slice(i + 2, j).join(""), cp[j]!);
        return j + 1;
      }
      case "]":
      case "P":
      case "X":
      case "^":
      case "_": {
        // OSC/DCS/SOS/PM/APC string: runs until ST (ESC \) or BEL.
        let j = i + 2;
        while (j < n) {
          if (cp[j] === "\x07") return j + 1;
          if (cp[j] === "\x1b") {
            if (j + 1 >= n) return null; // maybe ESC \, need more
            if (cp[j + 1] === "\\") return j + 2;
          }
          j++;
        }
        return null; // unterminated string — wait for more
      }
      case "(":
      case ")":
      case "*":
      case "+":
        // Charset designator: ESC ( <one char>. Ignore, but consume the arg.
        if (i + 2 >= n) return null;
        return i + 3;
      case "7":
        this.buf.savedRow = this.buf.row;
        this.buf.savedCol = this.buf.col;
        return i + 2;
      case "8":
        this.buf.row = this.buf.savedRow;
        this.buf.col = this.buf.savedCol;
        return i + 2;
      case "M":
        this.reverseIndex();
        return i + 2;
      default:
        return i + 2; // keypad modes, RIS, unknown 2-byte escapes — skip
    }
  }

  private handleControl(v: number): void {
    switch (v) {
      case 0x0d: // CR
        this.buf.col = 0;
        break;
      case 0x0a: // LF
      case 0x0b: // VT
      case 0x0c: // FF
        this.lineFeed();
        break;
      case 0x08: // BS
        this.buf.col = Math.max(0, this.buf.col - 1);
        break;
      case 0x09: // HT
        this.buf.col = Math.min(this.width - 1, (Math.floor(this.buf.col / 8) + 1) * 8);
        break;
      default:
        break; // BEL etc.
    }
  }

  private handleCsi(raw: string, final: string): void {
    const isPrivate = raw.startsWith("?");
    const nums = raw
      .replace(/^[?>!]+/, "")
      .split(";")
      .map((x) => (x === "" ? null : Number.parseInt(x, 10)));
    const p = (idx: number, def: number): number => {
      const v = nums[idx];
      return v === undefined || v === null || Number.isNaN(v) ? def : v;
    };

    switch (final) {
      case "A":
        this.buf.row = Math.max(0, this.buf.row - Math.max(1, p(0, 1)));
        break;
      case "B":
      case "e":
        this.buf.row = Math.min(this.height - 1, this.buf.row + Math.max(1, p(0, 1)));
        break;
      case "C":
      case "a":
        this.buf.col = Math.min(this.width - 1, this.buf.col + Math.max(1, p(0, 1)));
        break;
      case "D":
        this.buf.col = Math.max(0, this.buf.col - Math.max(1, p(0, 1)));
        break;
      case "E":
        this.buf.row = Math.min(this.height - 1, this.buf.row + Math.max(1, p(0, 1)));
        this.buf.col = 0;
        break;
      case "F":
        this.buf.row = Math.max(0, this.buf.row - Math.max(1, p(0, 1)));
        this.buf.col = 0;
        break;
      case "G":
      case "`":
        this.buf.col = this.clampCol(p(0, 1) - 1);
        break;
      case "d":
        this.buf.row = this.clampRow(p(0, 1) - 1);
        break;
      case "H":
      case "f":
        this.buf.row = this.clampRow(p(0, 1) - 1);
        this.buf.col = this.clampCol(p(1, 1) - 1);
        break;
      case "J":
        this.eraseInDisplay(p(0, 0));
        break;
      case "K":
        this.eraseInLine(p(0, 0));
        break;
      case "S":
        this.scrollUp(Math.max(1, p(0, 1)));
        break;
      case "T":
        this.scrollDown(Math.max(1, p(0, 1)));
        break;
      case "s":
        this.buf.savedRow = this.buf.row;
        this.buf.savedCol = this.buf.col;
        break;
      case "u":
        this.buf.row = this.buf.savedRow;
        this.buf.col = this.buf.savedCol;
        break;
      case "h":
      case "l":
        if (isPrivate) this.setPrivateMode(nums, final === "h");
        break;
      default:
        break; // SGR (m), DECSTBM (r), and the rest don't affect text content
    }
  }

  private setPrivateMode(nums: Array<number | null>, enable: boolean): void {
    for (const v of nums) {
      switch (v) {
        case 1049:
        case 1047:
        case 47:
          if (enable) {
            if (!this.usingAlt) {
              this.usingAlt = true;
              this.clearBuffer(this.alt);
              this.alt.row = 0;
              this.alt.col = 0;
            }
          } else if (this.usingAlt) {
            this.usingAlt = false;
          }
          break;
        case 7:
          this.autowrap = enable;
          break;
        default:
          break;
      }
    }
  }

  // --- grid primitives ---

  private putChar(c: string): void {
    if (this.buf.col >= this.width) {
      if (this.autowrap) {
        this.buf.col = 0;
        this.lineFeed();
      } else {
        this.buf.col = this.width - 1;
      }
    }
    this.buf.grid[this.clampRow(this.buf.row)]![this.clampCol(this.buf.col)] = c;
    this.buf.col += 1;
  }

  private lineFeed(): void {
    if (this.buf.row >= this.height - 1) this.scrollUp(1);
    else this.buf.row += 1;
  }

  private reverseIndex(): void {
    if (this.buf.row <= 0) this.scrollDown(1);
    else this.buf.row -= 1;
  }

  private scrollUp(n: number): void {
    const k = Math.min(n, this.height);
    this.buf.grid.splice(0, k);
    for (let i = 0; i < k; i++) this.buf.grid.push(this.blankRow());
  }

  private scrollDown(n: number): void {
    const k = Math.min(n, this.height);
    this.buf.grid.splice(this.height - k, k);
    for (let i = 0; i < k; i++) this.buf.grid.unshift(this.blankRow());
  }

  private eraseInLine(mode: number): void {
    const r = this.clampRow(this.buf.row);
    const col = this.clampCol(this.buf.col);
    const line = this.buf.grid[r]!;
    if (mode === 1) {
      for (let c = 0; c <= col; c++) line[c] = " ";
    } else if (mode === 2) {
      this.buf.grid[r] = this.blankRow();
    } else {
      for (let c = col; c < this.width; c++) line[c] = " ";
    }
  }

  private eraseInDisplay(mode: number): void {
    const r = this.clampRow(this.buf.row);
    const col = this.clampCol(this.buf.col);
    if (mode === 1) {
      for (let rr = 0; rr < r; rr++) this.buf.grid[rr] = this.blankRow();
      const line = this.buf.grid[r]!;
      for (let c = 0; c <= col; c++) line[c] = " ";
    } else if (mode === 2 || mode === 3) {
      for (let rr = 0; rr < this.height; rr++) this.buf.grid[rr] = this.blankRow();
    } else {
      const line = this.buf.grid[r]!;
      for (let c = col; c < this.width; c++) line[c] = " ";
      for (let rr = r + 1; rr < this.height; rr++) this.buf.grid[rr] = this.blankRow();
    }
  }

  // --- helpers ---

  private blankRow(): string[] {
    return Array.from({ length: this.width }, () => " ");
  }
  private clampRow(r: number): number {
    return Math.min(Math.max(0, r), this.height - 1);
  }
  private clampCol(c: number): number {
    return Math.min(Math.max(0, c), this.width - 1);
  }

  private clearBuffer(b: ScreenBuffer): void {
    for (let r = 0; r < this.height; r++) b.grid[r] = this.blankRow();
  }

  private resized(b: ScreenBuffer, w: number, h: number): ScreenBuffer {
    const out = new ScreenBuffer(w, h);
    for (let r = 0; r < Math.min(h, b.grid.length); r++) {
      const src = b.grid[r]!;
      const dst = out.grid[r]!;
      for (let c = 0; c < Math.min(w, src.length); c++) dst[c] = src[c]!;
    }
    out.row = Math.min(b.row, h - 1);
    out.col = Math.min(b.col, w - 1);
    return out;
  }
}

function rowString(row: string[]): string {
  let end = row.length;
  while (end > 0 && row[end - 1] === " ") end--;
  return row.slice(0, end).join("");
}
