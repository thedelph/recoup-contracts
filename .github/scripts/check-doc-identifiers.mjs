#!/usr/bin/env node
/**
 * check-doc-identifiers.mjs - every code name printed in the published documentation
 * must still exist in the published source.
 *
 * WHY THIS EXISTS
 * ---------------
 * On 2026-08-31 this repository's Solidity was replaced wholesale while its risk register was
 * not. KNOWN_RISKS.md went on naming `netDeposits` and `QueueHeldByReserve`, neither of which
 * exists in the source that shipped beside it, and three findings stood published as live
 * activation blockers against a pool that had been deleted. The prose was corrected by hand.
 * Nothing prevented it, and nothing would have caught it: no check in this repository reads
 * README.md, REVIEW.md, AUDITS.md or KNOWN_RISKS.md at all.
 *
 * This is that check. It is deliberately narrow. It does not verify that a document's claim is
 * TRUE - a mechanism can be described wrongly in terms that all resolve. It verifies the weaker
 * property that is nonetheless the one that failed: that every name the documentation prints as
 * code is a name the source still uses. A reader who greps for a symbol this repository told them
 * about will find it.
 *
 * Run: node .github/scripts/check-doc-identifiers.mjs
 * Node builtins only, no dependencies, no build step. It must stay runnable on a bare checkout,
 * because it runs on documentation-only pull requests where nothing else is installed.
 *
 * WHAT COUNTS AS AN IDENTIFIER
 * ----------------------------
 * The documents wrap many things in backticks that are not identifiers, and a checker that
 * demanded all of them resolve would be un-passable, while one that skipped anything awkward
 * would be vacuous. Every span is therefore sorted into a class by its SHAPE, and the classes
 * that are not identifiers are named here rather than hidden in a list of exceptions. Shape is
 * used in preference to a list of allowed words on purpose: a list of words can be extended to
 * silence a real failure and the diff looks like maintenance, whereas a shape rule cannot be bent
 * around one name.
 *
 *   literal      `0x30B9...`, `0x791d1a9e`, `2^128`, `:95`   - addresses, hashes, selectors,
 *                exponents and the `:NNN` line citations in REVIEW.md. Not names. The line
 *                citations are deliberately NOT checked for being in range: every citation this
 *                project has seen rot pointed at a wrong line that existed, so a range check
 *                would have passed on all of them and reported diligence it had not done.
 *   shell        `forge test`, `--recursive`, `grep -c ... test/*.invariants.t.sol` - a command
 *                line, recognised by its first word or a leading dash.
 *   hyphenated   `erc4626-tests`, `halmos-cheatcodes` - a Solidity identifier cannot contain a
 *                hyphen, so a hyphenated word is naming something else (here, two submodule
 *                directories under lib/, which this repository does not compile).
 *   prose        `Security hardening` - letters and spaces only. An English phrase in backticks.
 *   path         anything containing a slash, ending in a repository file extension, or named
 *                LICENSE. Checked, but as a PATH: the file or directory must exist. A bare
 *                basename such as `Config.sol` resolves anywhere in the tree; a glob such as
 *                `test/*.invariants.t.sol` must match at least one real path.
 *   pattern      `invariant_*`, `*For` - a wildcard over names. Checked: at least one real
 *                identifier must match it. `*For` passing means some `...For` function exists.
 *   code         everything else. Tokenised, and every token must resolve.
 *
 * Within a `code` span, tokens that are part of the Solidity language are skipped: keywords,
 * the built-in globals (`msg`, `abi`, `block`, ...) and the elementary types (`address`,
 * `bytes32`, `uint256`, ...). That list is the language definition, not a project allowlist -
 * it cannot be extended to excuse a project name without the diff saying so out loud.
 *
 * A qualified reference such as `LenderPool.claim` is checked more tightly than its two halves:
 * if a file named LenderPool.sol exists, `claim` must appear IN THAT FILE. Known limit: a member
 * inherited from a base in lib/ would fail this, and the fix in that case is to name the type
 * that defines it.
 *
 * WHAT THE SOURCE MEANS
 * ---------------------
 * A name resolves if it appears in executable Solidity under src/, script/ or test/.
 * Comments are stripped first, and that is the single most load-bearing decision here.
 * `QueueHeldByReserve` - one of the two names that actually rotted - still appears twice in this
 * tree, in two comments in test/CreditManager.t.sol and nowhere else. A checker that read
 * comments would have passed on it. Documentation must not be validated against documentation.
 *
 * String literals are kept, but only when the whole literal is one identifier-shaped word:
 * `bytes32("DEXFI")` is a code-level fact about a reserved referral code and is the only place
 * that name exists, whereas a revert message is a sentence and would otherwise dump every
 * English word in the suite into the set of things a document is allowed to claim.
 *
 * DELIBERATELY ABSENT NAMES
 * -------------------------
 * A document that correctly records a REMOVAL has to name the thing it removed, so a small
 * register of such names is kept below. It is the one part of this script that is a list of
 * words, and three rules stop it becoming the usual dead allowlist:
 *
 *   1. a registered name that resolves again is a FAILURE, not a pass - the entry is stale and
 *      must be deleted, so the list cannot quietly accumulate;
 *   2. a registered name no documentation mentions is a FAILURE - dead entries are removed;
 *   3. the paragraph printing it must say it is gone. A name cannot be registered and then
 *      asserted as a live mechanism, which is exactly what happened with `netDeposits`.
 *
 * It remains true that somebody could add a name to this register and write "removed" beside it.
 * That is a visible edit to a published document that would then be false in prose, which is a
 * different and much louder failure than the silent one this script exists to stop.
 *
 * KNOWN GAPS, stated rather than left to be found
 * -----------------------------------------------
 *   - Fenced code blocks are not read. README.md's architecture diagram is one, so the contract
 *     names drawn in it are unchecked. Reading them would mean parsing shell out of the two ```sh
 *     blocks beside it.
 *   - Resolution is by name, not by kind. A document calling a state variable a function, or
 *     naming a real symbol in a false sentence, passes.
 *   - lib/ is not searched. An OpenZeppelin symbol the documentation names must also be used by
 *     this repository's own source, which every one of them currently is.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, basename } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = process.argv[2] || join(fileURLToPath(new URL(".", import.meta.url)), "..", "..");

const DOCS = ["README.md", "REVIEW.md", "AUDITS.md", "KNOWN_RISKS.md"];
const SOURCE_DIRS = ["src", "script", "test"];
const SKIP_DIRS = new Set([".git", "lib", "out", "cache", "broadcast", "node_modules"]);

/**
 * Names the documentation prints while recording that they no longer exist.
 * Each entry states why. See "DELIBERATELY ABSENT NAMES" above for the three rules that keep
 * this honest; all three are enforced below, so an entry cannot rot silently in either direction.
 */
const ACKNOWLEDGED_ABSENT = {
  registerFor:
    "The delegated referral writer, deleted when the registry moved to partner self-registration. " +
    "README.md and KNOWN_RISKS.md both record its removal, and KNOWN_RISKS.md additionally records " +
    "that the stale Sepolia deployment still exposes it.",
};

/** Words that make a paragraph a record of an absence rather than a claim of a mechanism. */
const REMOVAL_WORDS =
  /\b(removed|remove|removal|deleted|delete|former|formerly|no longer|gone|retired|superseded|replaced|absent|dropped)\b/i;

// ---------------------------------------------------------------------------
// Solidity language tokens. The language definition, not a project allowlist.
// ---------------------------------------------------------------------------
const KEYWORDS = new Set(
  [
    "abstract", "anonymous", "as", "assembly", "assert", "break", "calldata", "catch", "constant",
    "constructor", "continue", "contract", "delete", "do", "else", "emit", "enum", "error", "event",
    "external", "fallback", "for", "function", "if", "immutable", "import", "indexed", "interface",
    "internal", "is", "let", "library", "mapping", "memory", "modifier", "new", "override",
    "payable", "pragma", "private", "public", "pure", "receive", "require", "return", "returns",
    "revert", "solidity", "storage", "struct", "super", "this", "throw", "true", "false", "try",
    "unchecked", "using", "view", "virtual", "while",
  ]
);

const GLOBALS = new Set(
  [
    "abi", "addmod", "block", "blockhash", "ecrecover", "gasleft", "keccak256", "msg", "mulmod",
    "now", "ripemd160", "selfdestruct", "sha256", "tx", "type",
  ]
);

function isElementaryType(t) {
  if (/^(address|bool|string|bytes|fixed|ufixed)$/.test(t)) return true;
  if (/^u?int([0-9]+)?$/.test(t)) return true;
  if (/^bytes([1-9]|[12][0-9]|3[0-2])$/.test(t)) return true;
  if (/^u?fixed[0-9]+x[0-9]+$/.test(t)) return true;
  return false;
}

/** First words that make a backticked span a command line rather than a name. */
const COMMANDS = new Set(
  [
    "forge", "cast", "anvil", "git", "grep", "rg", "node", "pnpm", "npm", "npx", "sh", "bash",
    "make", "curl", "find", "ls", "sed", "awk", "cat", "echo", "export", "RUN_FORK_TESTS",
  ]
);

const IDENT = "[A-Za-z_$][A-Za-z0-9_$]*";

// ---------------------------------------------------------------------------
// The source corpus.
// ---------------------------------------------------------------------------

/**
 * Remove comments. Replace each string literal by its content when that content is a single
 * identifier-shaped word, and by a space otherwise. See the header for why.
 */
function executableSolidity(src) {
  let out = "";
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    const d = i + 1 < n ? src[i + 1] : "";
    if (c === "/" && d === "/") {
      while (i < n && src[i] !== "\n") i += 1;
      continue;
    }
    if (c === "/" && d === "*") {
      i += 2;
      while (i < n && !(src[i] === "*" && src[i + 1] === "/")) i += 1;
      i += 2;
      continue;
    }
    if (c === '"' || c === "'") {
      const quote = c;
      i += 1;
      let body = "";
      while (i < n && src[i] !== quote) {
        if (src[i] === "\\") {
          i += 1;
          if (i < n) i += 1;
          continue;
        }
        body += src[i];
        i += 1;
      }
      i += 1;
      out += new RegExp("^" + IDENT + "$").test(body) ? " " + body + " " : " ";
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}

function walk(dir, out) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (SKIP_DIRS.has(entry)) continue;
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

function rel(p) {
  return relative(ROOT, p).split("\\").join("/");
}

const solFiles = [];
for (const dir of SOURCE_DIRS) walk(join(ROOT, dir), solFiles);

const sourceTokens = new Set();
const tokensByFile = new Map();
const solByBasename = new Map();
for (const p of solFiles) {
  if (!p.endsWith(".sol")) continue;
  const code = executableSolidity(readFileSync(p, "utf8"));
  const found = new Set(code.match(new RegExp(IDENT, "g")) || []);
  const r = rel(p);
  tokensByFile.set(r, found);
  for (const t of found) sourceTokens.add(t);
  const b = basename(p);
  if (!solByBasename.has(b)) solByBasename.set(b, []);
  solByBasename.get(b).push(r);
}

// Every path in the repository, for the path class.
const repoPaths = new Set();
const repoBasenames = new Map();
(function walkRepo(dir) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }
  for (const entry of entries) {
    if (SKIP_DIRS.has(entry)) continue;
    const p = join(dir, entry);
    const r = rel(p);
    repoPaths.add(r);
    if (!repoBasenames.has(entry)) repoBasenames.set(entry, []);
    repoBasenames.get(entry).push(r);
    if (statSync(p).isDirectory()) {
      repoPaths.add(r + "/");
      walkRepo(p);
    }
  }
})(ROOT);

// ---------------------------------------------------------------------------
// Reading the documents.
// ---------------------------------------------------------------------------

/**
 * Inline code spans, with fenced blocks skipped. Paragraph index is recorded alongside so the
 * absent-name register can ask what the surrounding paragraph says.
 *
 * A stray backtick that pairs with nothing would silently drop every span after it on the line,
 * so the residue of each line is inspected and an unpaired backtick is a failure. A check that
 * reads less than it thinks it does is the failure mode this file is arguing against.
 */
function readSpans(doc) {
  const text = readFileSync(join(ROOT, doc), "utf8");
  const lines = text.split(/\r?\n/);
  const spans = [];
  const unpaired = [];
  const paragraphs = [];
  let current = [];
  let fenced = false;
  const paragraphOfLine = new Map();

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^\s*```/.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (line.trim() === "") {
      if (current.length) paragraphs.push(current);
      current = [];
      continue;
    }
    current.push(line);
    paragraphOfLine.set(i + 1, paragraphs.length);
    if (fenced) continue;

    const re = new RegExp("(`+)([^`]+?)\\1", "g");
    let m;
    let residue = line;
    while ((m = re.exec(line)) !== null) {
      spans.push({ doc, line: i + 1, text: m[2], paragraph: paragraphs.length });
      const at = residue.indexOf(m[0]);
      if (at >= 0) residue = residue.slice(0, at) + " " + residue.slice(at + m[0].length);
    }
    if (residue.includes("`")) unpaired.push({ doc, line: i + 1, residue });
  }
  if (current.length) paragraphs.push(current);
  return { spans, unpaired, paragraphs: paragraphs.map((p) => p.join(" ")) };
}

function classify(s) {
  if (/^0x[0-9a-fA-F]+$/.test(s)) return "literal";
  if (/^:[0-9]+$/.test(s)) return "literal";
  if (/^[0-9]/.test(s)) return "literal";
  if (s.includes("^")) return "literal";
  const first = s.trim().split(/\s+/)[0];
  if (s.trim().startsWith("-")) return "shell";
  if (COMMANDS.has(first)) return "shell";
  if (new RegExp("^[A-Za-z0-9_$]+(-[A-Za-z0-9_$]+)+$").test(s)) return "hyphenated";
  if (s.includes("/")) return "path";
  if (/\.(sol|md|json|toml|yml|yaml|lock|txt)$/.test(s)) return "path";
  if (s === "LICENSE") return "path";
  if (s.includes("*")) return "pattern";
  if (/\s/.test(s) && /^[A-Za-z][A-Za-z ]*$/.test(s)) return "prose";
  return "code";
}

function globToRegExp(pattern, segmentSafe) {
  const parts = pattern.split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&"));
  return new RegExp("^" + parts.join(segmentSafe) + "$");
}

function pathResolves(raw) {
  const p = raw.replace(/^\.\//, "");
  if (p.includes("*")) {
    const rx = globToRegExp(p, "[^/]*");
    for (const q of repoPaths) if (rx.test(q)) return true;
    return false;
  }
  if (repoPaths.has(p)) return true;
  if (repoPaths.has(p.replace(/\/$/, ""))) return true;
  if (!p.includes("/") && repoBasenames.has(p)) return true;
  return false;
}

function patternResolves(raw) {
  const rx = globToRegExp(raw, "[A-Za-z0-9_$]*");
  for (const t of sourceTokens) if (rx.test(t)) return true;
  return false;
}

// ---------------------------------------------------------------------------
// The check.
// ---------------------------------------------------------------------------
const failures = [];
const absentSeen = new Map();
let checkedIdentifiers = 0;
let checkedPaths = 0;
let checkedPatterns = 0;
let skipped = 0;

function recordIdentifier(token, span, docParagraphs) {
  if (KEYWORDS.has(token) || GLOBALS.has(token) || isElementaryType(token)) {
    skipped += 1;
    return;
  }
  checkedIdentifiers += 1;
  if (sourceTokens.has(token)) return;
  if (Object.prototype.hasOwnProperty.call(ACKNOWLEDGED_ABSENT, token)) {
    if (!absentSeen.has(token)) absentSeen.set(token, []);
    const paragraph = docParagraphs[span.paragraph] || "";
    absentSeen.get(token).push({ at: span.doc + ":" + span.line, paragraph });
    return;
  }
  failures.push({
    at: span.doc + ":" + span.line,
    what: "identifier `" + token + "` (in `" + span.text + "`) is not in src/, script/ or test/",
  });
}

for (const doc of DOCS) {
  const { spans, unpaired, paragraphs } = readSpans(doc);
  for (const u of unpaired) {
    failures.push({
      at: u.doc + ":" + u.line,
      what: "unpaired backtick, so code spans on this line were not read: " + u.residue.trim(),
    });
  }

  for (const span of spans) {
    const kind = classify(span.text);

    if (kind === "literal" || kind === "shell" || kind === "hyphenated" || kind === "prose") {
      skipped += 1;
      continue;
    }

    if (kind === "path") {
      checkedPaths += 1;
      if (!pathResolves(span.text)) {
        failures.push({ at: span.doc + ":" + span.line, what: "path `" + span.text + "` does not exist" });
      }
      continue;
    }

    if (kind === "pattern") {
      checkedPatterns += 1;
      if (!patternResolves(span.text)) {
        failures.push({
          at: span.doc + ":" + span.line,
          what: "pattern `" + span.text + "` matches no identifier in src/, script/ or test/",
        });
      }
      continue;
    }

    // code
    const consumed = new Set();
    const qualified = new RegExp("\\b(" + IDENT + ")\\.(" + IDENT + ")\\b", "g");
    let q;
    while ((q = qualified.exec(span.text)) !== null) {
      const left = q[1];
      const right = q[2];
      if (GLOBALS.has(left)) {
        consumed.add(left);
        consumed.add(right);
        skipped += 2;
        continue;
      }
      const files = solByBasename.get(left + ".sol");
      if (files && files.length) {
        consumed.add(left);
        consumed.add(right);
        checkedIdentifiers += 1;
        const found = files.some((f) => tokensByFile.get(f).has(right));
        if (!found) {
          failures.push({
            at: span.doc + ":" + span.line,
            what:
              "`" + left + "." + right + "` names a member `" + right + "` that does not appear in " +
              files.join(" or "),
          });
        }
      }
    }

    const tokens = span.text.match(new RegExp(IDENT, "g")) || [];
    for (const token of tokens) {
      if (consumed.has(token)) continue;
      recordIdentifier(token, span, paragraphs);
    }
  }
}

// Rules that keep the absent-name register from rotting in either direction.
for (const [name, reason] of Object.entries(ACKNOWLEDGED_ABSENT)) {
  if (sourceTokens.has(name)) {
    failures.push({
      at: ".github/scripts/check-doc-identifiers.mjs",
      what:
        "`" + name + "` is listed as deliberately absent but resolves in the source again. " +
        "Delete the ACKNOWLEDGED_ABSENT entry; the documentation no longer needs it. (" + reason + ")",
    });
    continue;
  }
  const sightings = absentSeen.get(name);
  if (!sightings || sightings.length === 0) {
    failures.push({
      at: ".github/scripts/check-doc-identifiers.mjs",
      what:
        "`" + name + "` is listed as deliberately absent but no published document names it any " +
        "more. Delete the ACKNOWLEDGED_ABSENT entry.",
    });
    continue;
  }
  for (const s of sightings) {
    if (!REMOVAL_WORDS.test(s.paragraph)) {
      failures.push({
        at: s.at,
        what:
          "`" + name + "` is registered as deliberately absent, but this paragraph does not say " +
          "it is gone, so it reads as a live mechanism. Say what happened to it, or stop naming it.",
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Report.
// ---------------------------------------------------------------------------
if (failures.length) {
  console.error("Published documentation names code that is not in this source.\n");
  for (const f of failures) console.error("  " + f.at + "\n    " + f.what + "\n");
  console.error(
    failures.length +
      " unresolved reference(s) across " +
      DOCS.join(", ") +
      ".\n\nEach one is a reader told to grep for something they will not find. Fix the prose to " +
      "name what the source actually has. If a document is deliberately recording that something " +
      "was removed, add it to ACKNOWLEDGED_ABSENT in this script with the reason, and make sure " +
      "the paragraph says it is gone."
  );
  process.exit(1);
}

console.log(
  "Documentation identifiers resolve: " +
    checkedIdentifiers +
    " identifiers, " +
    checkedPaths +
    " paths and " +
    checkedPatterns +
    " wildcards checked across " +
    DOCS.join(", ") +
    "; " +
    skipped +
    " spans skipped as literals, commands, paths outside the source or prose."
);
for (const [name, sightings] of absentSeen) {
  console.log(
    "  deliberately absent: `" + name + "`, named at " + sightings.map((s) => s.at).join(", ") +
      " in a paragraph that records its removal."
  );
}
