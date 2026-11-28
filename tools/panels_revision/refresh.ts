import * as fs from "node:fs/promises";
import { join, resolve } from "node:path";
import { AppendDiagnosticRow, PersistJson, PersistReportPartition, ReadReportPartition, type Algorithm, type DiagnosticRow, type ReportIndex } from "./revision/report";
import { RevisionService } from "./revision/service";
import type { Diagnostics } from "./revision/model";

export async function RefreshDiagnostic(root: string, algorithm: Algorithm, book: string, port: number): Promise<{ pages: number; differences: number; changed: boolean }> {
	await EnsureReviewerStopped(port);
	const directory = join(root, "tools/panels_revision/revision/data-persistence");
	const indexPath = join(directory, "diagnostics.json");
	const indexText = await fs.readFile(indexPath, "utf8");
	const index = JSON.parse(indexText) as ReportIndex;
	if (index.format !== "panels_revision_index") throw new Error("Open and close the reviewer once to initialize its report index.");
	const safe = await ReadReportPartition(directory, index, "safe");
	const smart = await ReadReportPartition(directory, index, "smart");
	const previous = { description: safe.description, books: { ...safe.books, ...smart.books }, groups: { ...safe.groups, ...smart.groups } };
	const group = `${algorithm}::${book}`;
	const service = new RevisionService(root, previous);
	const { mapping, hash } = await service.ReadMapping(group);
	const expected = new Map(mapping.pages.filter(p => p.frame.length > 0).map(p => [p.page_index, p.frame]));
	const diagnostic = Bun.spawn(["lua", "tools/panels_revision/revision/diagnose.lua", algorithm, book], { cwd: root, stdout: "pipe", stderr: "inherit" });
	const [output, exit] = await Promise.all([new Response(diagnostic.stdout).text(), diagnostic.exited]);
	if (exit !== 0) throw new Error(`Diagnostic exited with code ${exit}.`);
	const scoped: Diagnostics = { description: previous.description, books: {}, groups: {} };
	for (const line of output.trim().split("\n").filter(Boolean)) {
		const row = JSON.parse(line) as DiagnosticRow;
		const frames = expected.get(row.page);
		if (row.algorithm !== algorithm || row.book !== book || !frames || row.expected.length !== frames.length ||
			!frames.every(({ x, y, w, h }, index) => [x, y, w, h].every((value, coordinate) =>
				Math.abs(value - row.expected[index]![coordinate]!) <= 0.00051))) {
			throw new Error(`Diagnostic does not match the current mapping on page ${row.page}.`);
		}
		expected.delete(row.page);
		AppendDiagnosticRow(scoped, previous, row);
	}
	const pages = scoped.books[group];
	if (!pages?.length || expected.size) throw new Error("Incomplete diagnostic. The previous report is still current.");

	await EnsureReviewerStopped(port);
	const lock = join(directory, "refresh.lock");
	await fs.mkdir(lock);
	try {
		const verifyIndex = async (): Promise<void> => {
			await EnsureReviewerStopped(port);
			if (indexText !== await fs.readFile(indexPath, "utf8") || hash !== (await service.ReadMapping(group)).hash) {
				throw new Error("The report or mapping changed during the scan. Run the refresh again.");
			}
		};
		await verifyIndex();
		const partition = algorithm === "safe" ? safe : smart;
		const current: Diagnostics = { ...partition, books: { ...partition.books, [group]: pages }, groups: { ...partition.groups, ...scoped.groups } };
		const differences = pages.filter(p => !p.correct).length;
		if (JSON.stringify(partition.books[group]) === JSON.stringify(pages) &&
			JSON.stringify(partition.groups[group]) === JSON.stringify(scoped.groups[group])) return { pages: pages.length, differences, changed: false };
		const file = await PersistReportPartition(directory, current, algorithm);
		await PersistJson(join(directory, `diagnostics-before-${Date.now()}.json`), previous);
		await PersistJson(indexPath, { ...index, files: { ...index.files, [algorithm]: file } }, verifyIndex);
		return { pages: pages.length, differences, changed: true };
	} finally {
		await fs.rmdir(lock);
	}
}

async function EnsureReviewerStopped(port: number): Promise<void> {
	try {
		const socket = await Bun.connect({ hostname: "127.0.0.1", port, socket: { data() {} } });
		socket.end();
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ECONNREFUSED") return;
		throw error;
	}
	throw new Error(`Stop the reviewer on port ${port} before refreshing its saved report.`);
}

if (import.meta.main) {
	const [, , algorithm, book, ...extra] = process.argv;
	if ((algorithm !== "safe" && algorithm !== "smart") || !book || extra.length) {
		console.error('Usage: bun tools/panels_revision/refresh.ts <safe|smart> "<exact book title>"');
		process.exitCode = 1;
	} else {
		try {
			const result = await RefreshDiagnostic(resolve(import.meta.dir, "../.."), algorithm, book, Number(process.env.REVISION_PORT || 3210));
			console.log(`${algorithm}::${book} · ${result.pages} pages · ${result.differences} differences · ${result.changed ? "report updated" : "report already current"}`);
		} catch (error) {
			console.error(error instanceof Error ? error.message : error);
			process.exitCode = 1;
		}
	}
}
