export type Box = [number, number, number, number];
export type Choice = "pending" | "expected" | "previous" | "detected" | "custom";
export type Page = {
	page: number; image: string; width: number; height: number;
	expected: Box[]; previous: Box[]; detected: Box[];
	correct: boolean; previous_correct: boolean; sequence: number[]; previous_sequence: number[];
	tp: number; previous_tp: number; accepted: boolean; reason: string;
};
export type Diagnostics = { description: string; books: Record<string, Page[]>; groups: Record<string, { book: string; algorithm: "safe" | "smart"; directory?: "dataset" | "dataset-textbasedformats" }> };
export type Review = { choice: Choice; notes: string; boxes: Box[]; updated_at: string; basis?: string };
export type ReviewEntry = { book: string; page: number; review: Review };
export type MappingPage = {
	page_index: number; frame: { x: number; y: number; w: number; h: number }[];
	illustration_type?: string; [key: string]: unknown;
};
export type Mapping = { book_title: string; algorithm: string; pages: MappingPage[]; [key: string]: unknown };
export const CHOICES: Record<Choice, string> = {
	pending: "Pendiente", expected: "Mapping original", previous: "Antes", detected: "Después", custom: "Mis paneles",
};
export function ReviewKey(book: string, page: number): string { return `${book}:${page}`; }
export function EmptyReview(): Review { return { choice: "pending", notes: "", boxes: [], updated_at: "" }; }
export function SelectedBoxes(page: Page, review: Review): Box[] {
	if (review.choice === "custom") return review.boxes;
	if (review.choice === "pending") return [];
	return page[review.choice];
}
export function ParseReview(input: unknown, page: Page): Review {
	if (!input || typeof input !== "object") throw new Error("Revisión inválida");
	const value = input as Record<string, unknown>;
	if (typeof value.choice !== "string" || !Object.hasOwn(CHOICES, value.choice)) throw new Error("Elección inválida");
	if (typeof value.notes !== "string" || value.notes.length > 10000) throw new Error("Observación inválida (máximo 10000 caracteres)");
	if (typeof value.updated_at !== "string") throw new Error("Fecha inválida");
	if (!Array.isArray(value.boxes) || value.boxes.length > 100) throw new Error("Lista de paneles inválida");
	const boxes: Box[] = value.boxes.map((box: unknown) => {
		if (!Array.isArray(box) || box.length !== 4 || !box.every(n => typeof n === "number" && Number.isFinite(n))) throw new Error("Coordenadas inválidas");
		const [x, y, w, h] = box as Box;
		if (x < 0 || y < 0 || w < 1 || h < 1 || x + w > page.width + 0.01 || y + h > page.height + 0.01) throw new Error("Panel fuera de los límites de la imagen");
		return [x, y, w, h];
	});
	
	return { choice: value.choice as Choice, notes: value.notes, boxes, updated_at: value.updated_at, basis: typeof value.basis === "string" ? value.basis : undefined };
}
export function ApplyReviews(mapping: Mapping, pages: Page[], entries: ReviewEntry[]): Mapping {
	const result = structuredClone(mapping);
	const seen = new Set<number>();
	for (const entry of entries) {
		if (seen.has(entry.page)) throw new Error("Manga incorrecto o página duplicada");
		seen.add(entry.page);
		const page = pages.find(p => p.page === entry.page);
		if (!page) throw new Error("Página fuera de este diagnóstico");
		const review = ParseReview(entry.review, page);
		if (review.choice === "custom" && review.boxes.length === 0) throw new Error("Dibuja al menos un panel");
		if (review.choice === "pending") throw new Error("La página sigue pendiente");
		const target = result.pages.find(p => p.page_index === entry.page);
		if (!target) throw new Error("Página ausente del mapping Safe");
		target.frame = SelectedBoxes(page, review).map(([x, y, w, h]) => ({ x, y, w, h }));
		if (target.frame.length === 1) target.illustration_type = "single_page";
		else delete target.illustration_type;
	}
	return result;
}

export function PageBasis(page: Page): string { return JSON.stringify([page.image, page.expected, page.previous, page.detected]); }

export type Session = {
	algorithm: "safe" | "smart" | "all"; book: string;
	filter: "different" | "pending" | "new" | "reviewed" | "all";
	search: string; group: string; page: number; zoom: number; drawMode: boolean; updated_at: string;
};
export function ParseSession(input: unknown): Session {
	if (!input || typeof input !== "object") throw new Error("Invalid session");
	const value = input as Record<string, unknown>;
	if (!["safe", "smart", "all"].includes(String(value.algorithm)) || !["different", "pending", "new", "reviewed", "all"].includes(String(value.filter))
		|| typeof value.book !== "string" || typeof value.group !== "string" || typeof value.search !== "string" || !/^\d*$/.test(value.search)
		|| typeof value.page !== "number" || !Number.isInteger(value.page) || value.page < 0
		|| typeof value.zoom !== "number" || !Number.isFinite(value.zoom) || value.zoom < 50 || value.zoom > 250
		|| typeof value.drawMode !== "boolean" || typeof value.updated_at !== "string") throw new Error("Invalid session settings");
	return value as Session;
}
