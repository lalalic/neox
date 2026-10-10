// Edit behavior adapted from @mariozechner/pi-coding-agent 0.73.1 edit/edit-diff tools.
import path from "node:path";
import { withPiFileMutationQueue } from "./pi-filesystem-utils.mjs";

function normalizeToLF(text) { return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n"); }
function detectLineEnding(text) { return text.includes("\r\n") ? "\r\n" : "\n"; }
function restoreLineEndings(text, ending) { return ending === "\r\n" ? text.replace(/\n/g, "\r\n") : text; }
function stripBom(text) { return text.startsWith("\uFEFF") ? { bom: "\uFEFF", text: text.slice(1) } : { bom: "", text }; }
function normalizeFuzzy(text) {
  return text.normalize("NFKC").split("\n").map((line) => line.trimEnd()).join("\n")
    .replace(/[\u2018\u2019\u201A\u201B]/g, "'").replace(/[\u201C\u201D\u201E\u201F]/g, '"')
    .replace(/[\u2010-\u2015\u2212]/g, "-").replace(/[\u00A0\u2002-\u200A\u202F\u205F\u3000]/g, " ");
}
function findMatch(content, needle) {
  const exact = content.indexOf(needle);
  if (exact >= 0) return { index: exact, length: needle.length, fuzzy: false };
  const fuzzyContent = normalizeFuzzy(content);
  const fuzzyNeedle = normalizeFuzzy(needle);
  const index = fuzzyContent.indexOf(fuzzyNeedle);
  return index < 0 ? null : { index, length: fuzzyNeedle.length, fuzzy: true };
}
function occurrenceCount(content, needle) {
  const haystack = normalizeFuzzy(content);
  const normalized = normalizeFuzzy(needle);
  if (!normalized) return 0;
  return haystack.split(normalized).length - 1;
}

function applyEdits(content, edits, displayPath) {
  const normalizedEdits = edits.map((edit) => ({ oldText: normalizeToLF(edit.old_text), newText: normalizeToLF(edit.new_text) }));
  normalizedEdits.forEach((edit, index) => { if (!edit.oldText) throw new Error(`edits[${index}].old_text must not be empty`); });
  const initial = normalizedEdits.map((edit) => findMatch(content, edit.oldText));
  const base = initial.some((match) => match?.fuzzy) ? normalizeFuzzy(content) : content;
  const matched = normalizedEdits.map((edit, index) => {
    const match = findMatch(base, edit.oldText);
    if (!match) throw new Error(`Could not find edits[${index}] in ${displayPath}; old_text must match the file`);
    const occurrences = occurrenceCount(base, edit.oldText);
    if (occurrences !== 1) throw new Error(`Found ${occurrences} occurrences of edits[${index}] in ${displayPath}; old_text must be unique`);
    return { index, start: match.index, length: match.length, newText: edit.newText };
  }).sort((a, b) => a.start - b.start);
  for (let i = 1; i < matched.length; i++) {
    if (matched[i - 1].start + matched[i - 1].length > matched[i].start) throw new Error(`edits[${matched[i - 1].index}] and edits[${matched[i].index}] overlap in ${displayPath}`);
  }
  let output = base;
  for (let i = matched.length - 1; i >= 0; i--) {
    const edit = matched[i];
    output = output.slice(0, edit.start) + edit.newText + output.slice(edit.start + edit.length);
  }
  if (output === base) throw new Error(`No changes made to ${displayPath}`);
  return output;
}

export async function piEdit(args, context) {
  const { resolvePath, fsp, crypto, process } = context;
  const filePath = resolvePath(args.path);
  return withPiFileMutationQueue(filePath, async () => {
    const stat = await fsp.stat(filePath);
    if (!stat.isFile()) throw new Error(`Not a regular file: ${filePath}`);
    const raw = await fsp.readFile(filePath, "utf8");
    const { bom, text } = stripBom(raw);
    const ending = detectLineEnding(text);
    const edited = applyEdits(normalizeToLF(text), args.edits, args.path);
    const finalContent = bom + restoreLineEndings(edited, ending);
    const tempPath = path.join(path.dirname(filePath), `.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`);
    try {
      await fsp.writeFile(tempPath, finalContent, { mode: stat.mode & 0o7777 });
      await fsp.rename(tempPath, filePath);
    } catch (error) {
      await fsp.rm(tempPath, { force: true }).catch(() => {});
      throw error;
    }
    return { path: filePath, replacements: args.edits.length, bytesWritten: Buffer.byteLength(finalContent, "utf8"), atomic: true };
  });
}
