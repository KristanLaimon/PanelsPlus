import * as fs from "node:fs/promises";
import { join } from "node:path";
import type { Diagnostics } from "./model";
import { AppendDiagnosticRow, type DiagnosticRow } from "./report";
export type Run = {
	id: string; phase: "idle" | "tests" | "diagnostics" | "complete" | "error";
	algorithm?: "safe" | "smart" | "all"; started_at?: string; finished_at?: string; test_exit?: number; diagnostic_exit?: number;
	pages: number; log: string; error?: string;
};
export class Runs {
	public Current: Run = { id: "", phase: "idle", pages: 0, log: "" };
	private active = false;
	public Completion: Promise<void> = Promise.resolve();
	public constructor(private readonly root: string, private readonly directory: string,
		private readonly onComplete: (diagnostics: Diagnostics) => Promise<void>) {}
	public async Initialize(): Promise<void> {
		try { this.Current = JSON.parse(await fs.readFile(join(this.directory, "run.json"), "utf8")); }
		catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
		if (["tests", "diagnostics"].includes(this.Current.phase)) {
			this.Current.phase = "error"; this.Current.error = "El servidor se cerró durante la ejecución; vuelve a iniciarla.";
			await this.persist();
		}
	}
	public Start(previous: Diagnostics, algorithm: "safe" | "smart" | "all" = "all"): Run {
		if (this.active) throw new Error("Ya hay una ejecución en curso");
		this.active = true;
		this.Current = { id: crypto.randomUUID(), phase: "tests", algorithm, pages: 0, started_at: new Date().toISOString(), log: "" };
		this.Completion = this.execute(structuredClone(previous));
		return this.Current;
	}
	private async execute(previous: Diagnostics): Promise<void> {
		const logPath = join(this.directory, `run-${this.Current.id}.log`);
		const outputPath = join(this.directory, `run-${this.Current.id}.jsonl`);
		try {
			await this.persist();
			this.Current.test_exit = await this.process(["bash", "./run-tests.sh", "--panels", "--strict"], logPath);
			this.Current.phase = "diagnostics";
			await this.persist();
			const diagnostics: Diagnostics = { description: "Generated with production detector maps; IoU 0.5 / gap 35px. Before = previous different detector result (or seeded report).", books: {}, groups: {} };
			if (this.Current.algorithm !== "all") {
				for (const [group, info] of Object.entries(previous.groups)) if (info.algorithm !== this.Current.algorithm) {
					diagnostics.groups[group] = info; diagnostics.books[group] = previous.books[group]!;
				}
			}
			const writer = Bun.file(outputPath).writer();
			let pending = "";
			const consume = (line: string) => {
				if (!line.trim()) return;
				AppendDiagnosticRow(diagnostics, previous, JSON.parse(line) as DiagnosticRow);
				this.Current.pages++;
			};
			try {
				this.Current.diagnostic_exit = await this.process(["lua", "tools/panels_revision/revision/diagnose.lua", this.Current.algorithm || "all"], logPath, (chunk) => {
					writer.write(chunk); pending += chunk;
					let end: number;
					while ((end = pending.indexOf("\n")) !== -1) { consume(pending.slice(0, end)); pending = pending.slice(end + 1); }
				});
				if (pending.trim()) consume(pending);
			} finally { await writer.end(); }
			if (this.Current.diagnostic_exit !== 0) throw new Error("El diagnóstico falló; se conserva el informe anterior. Consulta el log.");
			if (!this.Current.pages) throw new Error("El diagnóstico no encontró páginas; se conserva el informe anterior.");
			await this.onComplete(diagnostics);
			this.Current.phase = "complete";
		} catch (error) {
			this.Current.phase = "error";
			this.Current.error = error instanceof Error ? error.message : String(error);
		} finally {
			this.Current.finished_at = new Date().toISOString(); this.active = false; await this.persist();
		}
	}
	private async process(command: string[], logPath: string, output?: (chunk: string) => void): Promise<number> {
		const child = Bun.spawn(command, { cwd: this.root, env: { ...process.env, PANELSPLUS_TEST_ALGORITHM: this.Current.algorithm || "all" }, stdout: "pipe", stderr: "pipe" });
		const append = async (stream: ReadableStream<Uint8Array>, isOutput: boolean) => {
			const decoder = new TextDecoder();
			for await (const bytes of stream) {
				const text = decoder.decode(bytes, { stream: true });
				if (isOutput && output) output(text);
				else { this.Current.log = (this.Current.log + text).slice(-24000); await fs.appendFile(logPath, text); }
			}
		};
		try { await Promise.all([append(child.stdout, true), append(child.stderr, false)]); }
		catch (error) { child.kill(); await child.exited; throw error; }
		return child.exited;
	}
	private async persist(): Promise<void> {
		const path = join(this.directory, "run.json");
		await fs.writeFile(path + ".tmp", JSON.stringify(this.Current, null, 2));
		await fs.rename(path + ".tmp", path);
	}
}
