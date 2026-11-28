import * as fs from "node:fs/promises";
import { dirname, join } from "node:path";
import type { Diagnostics, Page } from "./model";
import { Digest } from "./service";

export type Algorithm = "safe" | "smart";
export type ReportIndex = { format: "panels_revision_index"; files: Record<Algorithm, string> };
export type DiagnosticRow = Omit<Page, "previous" | "previous_correct" | "previous_tp" | "previous_sequence"> &
	Diagnostics["groups"][string];

export async function PersistJson(path: string, value: unknown, beforeRename?: () => Promise<void>): Promise<void> {
	await fs.mkdir(dirname(path), { recursive: true });
	const temporary = `${path}.${crypto.randomUUID()}.tmp`;
	try {
		await fs.writeFile(temporary, JSON.stringify(value, null, 2) + "\n");
		await beforeRename?.();
		await fs.rename(temporary, path);
	} finally { await fs.unlink(temporary).catch(() => {}); }
}

export async function ReadReportPartition(directory: string, index: ReportIndex, algorithm: Algorithm): Promise<Diagnostics> {
	const file = index.files[algorithm];
	if (typeof file !== "string" || !/^(safe|smart)\/diagnostics-[a-f0-9]+\.json$/.test(file) || !file.startsWith(algorithm + "/")) {
		throw new Error("Invalid stored report path");
	}
	return JSON.parse(await fs.readFile(join(directory, file), "utf8")) as Diagnostics;
}

export async function PersistReportPartition(directory: string, value: Diagnostics, algorithm: Algorithm): Promise<string> {
	const groups = Object.fromEntries(Object.entries(value.groups).filter(([, info]) => info.algorithm === algorithm)
		.sort(([a], [b]) => a.localeCompare(b)));
	const partition: Diagnostics = { description: value.description, groups, books: Object.fromEntries(Object.keys(groups).map(key => [key, value.books[key]!])) };
	const file = `${algorithm}/diagnostics-${Digest(JSON.stringify(partition)).slice(0, 20)}.json`;
	await PersistJson(join(directory, file), partition);
	return file;
}

export function AppendDiagnosticRow(diagnostics: Diagnostics, previous: Diagnostics, row: DiagnosticRow): void {
	const group = `${row.algorithm}::${row.book}`;
	const old = previous.books[group]?.find(p => p.page === row.page && p.image === row.image && p.width === row.width && p.height === row.height);
	const unchanged = old && JSON.stringify(old.detected) === JSON.stringify(row.detected);
	(diagnostics.books[group] ??= []).push({
		...row,
		previous: unchanged ? old.previous : old?.detected ?? row.detected,
		previous_correct: unchanged ? old.previous_correct : old?.correct ?? row.correct,
		previous_tp: unchanged ? old.previous_tp : old?.tp ?? row.tp,
		previous_sequence: unchanged ? old.previous_sequence : old?.sequence ?? row.sequence,
	});
	diagnostics.groups[group] = { book: row.book, algorithm: row.algorithm, directory: row.directory };
}
