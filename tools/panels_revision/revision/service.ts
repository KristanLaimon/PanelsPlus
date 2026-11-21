import * as fs from "node:fs/promises";
import { join, resolve } from "node:path";
import { ApplyReviews, PageBasis, type Diagnostics, type Mapping, type ReviewEntry } from "./model";

export function Digest(text: string): string { return new Bun.CryptoHasher("sha256").update(text).digest("hex"); }
export class RevisionService {
	private queue: Promise<unknown> = Promise.resolve();
	public constructor(private readonly root: string, public readonly Diagnostics: Diagnostics, private readonly storage = fs) {}
	public async ReadMapping(book: string): Promise<{ mapping: Mapping; hash: string }> {
		const text = await this.storage.readFile(this.mappingPath(book), "utf8");
		const mapping = JSON.parse(text) as Mapping;
		if (mapping.book_title !== this.Diagnostics.groups[book]?.book || mapping.algorithm !== this.Diagnostics.groups[book]?.algorithm) throw new Error("Identidad del mapping inválida");
		return { mapping, hash: Digest(text) };
	}
	public Save(book: string, hash: string, entries: ReviewEntry[]): Promise<{ hash: string; backup: string; pages: number[] }> {
		const operation = this.queue.then(async () => {
			if (!Array.isArray(entries) || entries.length === 0 || entries.length > 2000) throw new Error("Selecciona páginas revisadas para guardar");
			const current = await this.ReadMapping(book);
			if (current.hash !== hash) throw new Error("El mapping cambió desde que abriste la revisión. Recarga la página; tu feedback permanece en localStorage.");
			if (entries.some(e => !e || e.book !== book)) throw new Error("Grupo incorrecto");
			for (const entry of entries) {
				const page = this.Diagnostics.books[book]?.find(p => p.page === entry.page);
				if (!page || entry.review?.basis !== PageBasis(page)) throw new Error("This decision belongs to an older report. Choose the correct result again.");
			}
			const updated = ApplyReviews(current.mapping, this.Diagnostics.books[book]!, entries);
			const path = this.mappingPath(book);
			const original = await this.storage.readFile(path, "utf8");
			if (Digest(original) !== hash) throw new Error("El mapping cambió durante el guardado; no se escribió.");
			const backupDir = join(this.root, "tools/panels_revision/revision/data-persistence/backups", book);
			await this.storage.mkdir(backupDir, { recursive: true });
			const id = `${new Date().toISOString().replaceAll(":", "-")}-${crypto.randomUUID()}`;
			const backup = join(backupDir, `${id}.json`);
			await this.storage.writeFile(backup, original, { flag: "wx" });
			const text = JSON.stringify(updated, null, 2) + "\n";
			const temporary = `${path}.${id}.tmp`;
			try {
				await this.storage.writeFile(temporary, text, { flag: "wx" });
				if (Digest(await this.storage.readFile(path, "utf8")) !== hash) throw new Error("El mapping cambió; se canceló el guardado.");
				await this.storage.rename(temporary, path);
			} finally {
				await this.storage.unlink(temporary).catch(() => {});
			}
			return { hash: Digest(text), backup: backup.slice(resolve(this.root).length + 1), pages: entries.map(e => e.page) };
		});
		this.queue = operation.catch(() => {});
		return operation;
	}
	private mappingPath(group: string): string {
		const info = this.Diagnostics.groups[group];
		if (!Object.hasOwn(this.Diagnostics.groups, group) || !info || !/^[\w '\-]+$/.test(info.book) || !["safe", "smart"].includes(info.algorithm)) throw new Error("Manga desconocido");
		const directory = info.directory || (this.Diagnostics.books[group]?.[0]?.image.includes("/dataset-textbasedformats/") ? "dataset-textbasedformats" : "dataset");
		if (!["dataset", "dataset-textbasedformats"].includes(directory)) throw new Error("Unknown dataset directory");
		return join(this.root, "tests/dataset-mangas", directory, info.book, `panels_${info.algorithm}.json`);
	}
}
