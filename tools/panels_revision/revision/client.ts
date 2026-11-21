import { CHOICES, EmptyReview, ParseReview, ReviewKey, SelectedBoxes, PageBasis, ParseSession, type Session, type Box, type Choice, type Diagnostics, type Page, type Review, type ReviewEntry } from "./model";
import type { Run } from "./runs";

type Data = { id: string; diagnostics: Diagnostics; hashes: Record<string, string>; reviews: Record<string, Review>; session?: Session | null };
type Item = { group: string; page: Page };
type Drag = {
	item: Item; start: [number, number]; initial: Box[]; preview?: Box[];
	index: number; targetIndex: number; handle: string; pointer: number;
};
function Element<T extends HTMLElement | SVGSVGElement = HTMLElement>(id: string): T {
	const element = document.getElementById(id);
	if (!element) throw new Error(`Missing ${id}`);
	return element as T;
}
function Escape(value: string): string { return value.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!); }
const Basis = PageBasis;
const STORAGE_KEY = "panels_revision.reviews.v1";
let data: Data;
let reviews: Record<string, Review> = {};
let active: Item | undefined;
let items: Item[] = [];
let selected = -1;
let drawMode = true;
let drag: Drag | undefined;
let serverQueue: Promise<unknown> = Promise.resolve();
let notesTimer: ReturnType<typeof setTimeout> | undefined;
const history = new Map<string, Review[]>();
const canvas = Element<SVGSVGElement>("canvas");
const applied = new Map<string, string>();
let polling = false;
let runActive = false;
let handledRun = "";
let sessionQueue: Promise<unknown> = Promise.resolve();
function RememberSession(): void {
	if (!data) return;
	const session: Session = {
		algorithm: Element<HTMLSelectElement>("algorithm").value as Session["algorithm"],
		book: Element<HTMLSelectElement>("book").value,
		filter: Element<HTMLSelectElement>("filter").value as Session["filter"],
		search: Element<HTMLInputElement>("search").value,
		group: active?.group || "", page: active?.page.page || 0,
		zoom: Number(Element<HTMLInputElement>("zoom").value), drawMode, updated_at: new Date().toISOString(),
	};
	try { localStorage.setItem("panels_revision.session.v1", JSON.stringify(session)); } catch { /* Server persistence remains available. */ }
	sessionQueue = sessionQueue.catch(() => {}).then(() => Request("/api/session", session))
		.catch(error => Status(`Session is cached locally; disk save failed: ${error.message}`, true));
}
function Status(message: string, error = false): void { Element("status").textContent = message; Element("status").classList.toggle("error", error); }
async function Request<T>(url: string, body?: unknown): Promise<T> {
	const response = await fetch(url, body === undefined ? {} : { method: "POST", headers: { "content-type": "application/json", "x-revision-id": data.id }, body: JSON.stringify(body) });
	const text = await response.text();
	let value: T & { error?: string };
	try { value = JSON.parse(text); } catch { throw new Error(text || response.statusText); }
	if (!response.ok) throw new Error(value.error || text);
	return value;
}
function CurrentReview(): Review { return active ? reviews[ReviewKey(active.group, active.page.page)] || EmptyReview() : EmptyReview(); }
function Stale(item: Item, review: Review): boolean { return !!review.basis && review.basis !== Basis(item.page); }
function Ready(item: Item, review: Review): boolean { return review.choice !== "pending" && !(review.choice === "custom" && review.boxes.length === 0) && !Stale(item, review); }
function RememberLocal(): void {
	try { localStorage.setItem(STORAGE_KEY, JSON.stringify(reviews)); }
	catch { Status("Local storage is full or unavailable. Keep this tab open and export your feedback.", true); }
}
function Sync(item: Item, review: Review): void {
	const payload = { book: item.group, page: item.page.page, review: structuredClone(review) };
	serverQueue = serverQueue.catch(() => {}).then(async () => {
		await Request("/api/review", payload);
		Status("Review saved to disk and localStorage. Dataset unchanged until Save.");
	}).catch(error => { Status(`Draft saved locally; disk save failed: ${error.message}`, true); });
}
function Commit(review: Review, sync = true): void {
	if (!active) return;
	review.updated_at = new Date().toISOString(); review.basis ??= Basis(active.page);
	reviews[ReviewKey(active.group, active.page.page)] = review;
	RememberLocal();
	if (sync) Sync(active, review);
	RenderList(); RenderDecision();
}
function PushUndo(): void {
	if (!active) return;
	const key = ReviewKey(active.group, active.page.page);
	const stack = history.get(key) || []; stack.push(structuredClone(CurrentReview()));
	if (stack.length > 30) stack.shift(); history.set(key, stack);
}
function EditorBoxes(): Box[] {
	if (!active) return [];
	if (drag?.item === active && drag.preview) return drag.preview;
	const review = CurrentReview();
	return review.choice === "pending" ? active.page.detected : SelectedBoxes(active.page, review);
}
function SetCustom(boxes: Box[], undo = true): void {
	if (undo) PushUndo();
	Commit({ ...CurrentReview(), choice: "custom", boxes: structuredClone(boxes), basis: Basis(active!.page) });
	RenderEditor();
}
function ImageUrl(page: Page): string { return `/image?path=${encodeURIComponent(page.image)}`; }
function Rectangles(boxes: Box[], color: string, interactive = false): string {
	return boxes.map(([x, y, w, h], i) => `<g><rect class="panel ${interactive && i === selected ? "selected" : ""}" data-index="${i}" x="${x}" y="${y}" width="${w}" height="${h}" stroke="${color}" fill="transparent"/><text x="${x + 5}" y="${y + 29}" fill="${color}" pointer-events="none">${i + 1}</text></g>`).join("");
}
function RenderDecision(): void {
	if (!active) return;
	const review = CurrentReview();
	Element("choices").innerHTML = (Object.keys(CHOICES) as Choice[]).map(choice => `<button data-choice="${choice}" aria-pressed="${review.choice === choice}">${Escape(CHOICES[choice])}</button>`).join("");
	const stale = Stale(active, review);
	Element("dirty").textContent = stale ? "Saved decision is from an older report; choose again to confirm." : review.choice === "custom" && !review.boxes.length ? "Draw at least one rectangle" : CHOICES[review.choice];
	Element<HTMLButtonElement>("save-page").disabled = !Ready(active, review) || runActive;
	Element<HTMLButtonElement>("save-book").disabled = runActive;
	Element("saved-info").textContent = applied.get(ReviewKey(active.group, active.page.page)) === JSON.stringify(SelectedBoxes(active.page, review)) ? "Applied to dataset this session" : "";
}
function RenderList(): void {
	const algorithm = Element<HTMLSelectElement>("algorithm").value;
	const book = Element<HTMLSelectElement>("book").value;
	const filter = Element<HTMLSelectElement>("filter").value;
	const search = Number(Element<HTMLInputElement>("search").value);
	items = [];
	for (const [group, pages] of Object.entries(data.diagnostics.books)) {
		const info = data.diagnostics.groups[group]!;
		if (algorithm !== "all" && algorithm !== info.algorithm || book && book !== info.book) continue;
		for (const page of pages) {
			const item = { group, page }; const review = reviews[ReviewKey(group, page.page)] || EmptyReview();
			if (search && page.page !== search) continue;
			if (filter === "different" && page.correct || filter === "pending" && (page.correct || Ready(item, review)) || filter === "new" && (page.correct || !page.previous_correct) || filter === "reviewed" && review.choice === "pending" && !review.notes) continue;
			items.push(item);
		}
	}
	const listScroll = Element("page-list").scrollTop;
	Element("page-list").innerHTML = items.map((item, i) => {
		const review = reviews[ReviewKey(item.group, item.page.page)] || EmptyReview();
		const info = data.diagnostics.groups[item.group]!;
		const isActive = active?.group === item.group && active.page.page === item.page.page;
		return `<button data-item="${i}" class="${isActive ? "active" : ""}">P. ${item.page.page}: ${item.page.expected.length} → ${item.page.detected.length} · ${Escape(CHOICES[review.choice])}${Stale(item, review) ? " ⚠" : ""}<small>${Escape(info.book)} · ${info.algorithm}${review.notes ? " · notes" : ""}</small></button>`;
	}).join("");
	Element("page-list").scrollTop = listScroll;
	const all = Object.entries(data.diagnostics.books).filter(([group]) => {
		const info = data.diagnostics.groups[group]!;
		return (algorithm === "all" || info.algorithm === algorithm) && (!book || book === info.book);
	}).flatMap(([group, pages]) => pages.map(page => ({ group, page })));
	const ready = all.filter(item => Ready(item, reviews[ReviewKey(item.group, item.page.page)] || EmptyReview())).length;
	const scope = algorithm === "all" ? "Safe + Smart" : algorithm === "safe" ? "Safe" : "Smart";
	Element("progress").textContent = `${scope}: ${ready} reviewed · ${all.filter(item => !item.page.correct).length} differences / ${all.length} mapped pages · ${items.length} pages in this filter`;
	Element("empty-list").classList.toggle("hidden", items.length > 0);
	Element("run").textContent = `Run checks + diagnose ${scope}`;
}
function Open(item: Item): void {
	FlushNotes(); active = item; selected = -1;
	Element("main").classList.remove("hidden");
	const info = data.diagnostics.groups[item.group]!;
	Element("page-title").textContent = `${info.book} · ${info.algorithm} · page ${item.page.page}`;
	Element("page-info").textContent = `File: ${item.page.image.split("/").at(-1)} · ${item.page.width} × ${item.page.height} · Expected ${item.page.expected.length}, before ${item.page.previous.length}, after ${item.page.detected.length}. After sequence: ${item.page.sequence.map(n => n || "?").join(", ")}.${item.page.reason ? ` Fallback: ${item.page.reason}` : ""}`;
	Element("comparisons").innerHTML = (["expected", "previous", "detected"] as const).map((key, index) => {
		const colors = ["#08783e", "#7953aa", "#ce4b04"];
		return `<section class="comparison"><strong>${CHOICES[key]} · ${item.page[key].length}</strong><svg viewBox="0 0 ${item.page.width} ${item.page.height}"><image href="${Escape(ImageUrl(item.page))}" width="${item.page.width}" height="${item.page.height}"/>${Rectangles(item.page[key], colors[index]!)}</svg><div class="toolbar"><button data-choice="${key}">Keep this</button><button data-edit="${key}">Edit a copy</button></div></section>`;
	}).join("");
	Element<HTMLTextAreaElement>("notes").value = CurrentReview().notes;
	RenderList(); RenderDecision(); RenderEditor();
	location.hash = encodeURIComponent(item.group) + "/" + item.page.page; RememberSession();
}
function RenderEditor(): void {
	if (!active) return;
	const boxes = EditorBoxes(); if (selected >= boxes.length) selected = -1;
	const { width, height } = active.page;
	canvas.setAttribute("viewBox", `0 0 ${width} ${height}`);
	canvas.innerHTML = `<image href="${Escape(ImageUrl(active.page))}" width="${width}" height="${height}"/>${Rectangles(boxes, "#d04e00", true)}`;
	if (selected >= 0) {
		const [x, y, w, h] = boxes[selected]!;
		const size = Math.max(width / 60, 12);
		canvas.innerHTML += [[x, y, "nw"], [x + w, y, "ne"], [x, y + h, "sw"], [x + w, y + h, "se"]].map(([cx, cy, name]) => `<rect class="handle" data-handle="${name}" data-index="${selected}" x="${Number(cx) - size / 2}" y="${Number(cy) - size / 2}" width="${size}" height="${size}"/>`).join("");
	}
	canvas.style.width = `${Element<HTMLInputElement>("zoom").value}%`;
	canvas.style.cursor = drawMode ? "crosshair" : "move";
	Element("rect-list").innerHTML = boxes.map((box, i) => `<li><button data-rect="${i}" class="${i === selected ? "selected" : ""}">Panel ${i + 1}</button><small> ${box.map(n => Math.round(n)).join(", ")}</small></li>`).join("");
	for (const [i, key] of ["x", "y", "w", "h"].entries()) {
		const input = Element<HTMLInputElement>(key); input.value = selected < 0 ? "" : String(boxes[selected]![i]); input.disabled = selected < 0;
	}
	for (const key of ["delete", "up", "down", "apply-coordinates"]) Element<HTMLButtonElement>(key).disabled = selected < 0;
	Element<HTMLButtonElement>("undo").disabled = !(history.get(ReviewKey(active.group, active.page.page))?.length);
}
function FlushNotes(): void {
	if (!notesTimer || !active) return;
	clearTimeout(notesTimer); notesTimer = undefined;
	Sync(active, CurrentReview());
}
function MovePage(direction: number): void {
	if (!items.length) return;
	const index = items.findIndex(item => item.group === active?.group && item.page.page === active.page.page);
	const next = index < 0 ? (direction > 0 ? 0 : items.length - 1) : Math.max(0, Math.min(items.length - 1, index + direction));
	Open(items[next]!);
}
function Choose(choice: Choice): void {
	if (!active) return; FlushNotes(); PushUndo();
	const current = CurrentReview();
	Commit({ ...current, choice, basis: Basis(active.page), boxes: choice === "custom" && !current.boxes.length ? structuredClone(EditorBoxes()) : current.boxes });
	selected = -1; RenderEditor();
}
async function SaveMapping(all: boolean): Promise<void> {
	if (!active) return; FlushNotes();
	const group = active.group;
	const pages = all ? data.diagnostics.books[group]! : [active.page];
	const entries: ReviewEntry[] = pages.flatMap(page => {
		const review = reviews[ReviewKey(group, page.page)] || EmptyReview();
		return Ready({ group, page }, review) ? [{ book: group, page: page.page, review }] : [];
	});
	if (!entries.length) throw new Error("No completed decisions to save in this book / algorithm.");
	const result = await Request<{ hash: string; backup: string; pages: number[] }>("/api/mapping", { book: group, hash: data.hashes[group], entries });
	data.hashes[group] = result.hash;
	for (const entry of entries) {
		const page = pages.find(p => p.page === entry.page)!;
		applied.set(ReviewKey(group, entry.page), JSON.stringify(SelectedBoxes(page, entry.review)));
	}
	RenderDecision(); Status(`Updated ${result.pages.length} pages in ${group}. Backup: ${result.backup}`);
}
function ExportFeedback(): string {
	FlushNotes();
	const entries = Object.entries(data.diagnostics.books).flatMap(([group, pages]) => pages.flatMap(page => {
		const review = reviews[ReviewKey(group, page.page)];
		if (!review || review.choice === "pending" && !review.notes && !review.boxes.length) return [];
		const info = data.diagnostics.groups[group]!;
		return [{ group, book: info.book, algorithm: info.algorithm, page: page.page, image: page.image, width: page.width, height: page.height,
			review, stale: Stale({ group, page }, review), complete: Ready({ group, page }, review),
			expected: page.expected, before: page.previous, after: page.detected, chosen: SelectedBoxes(page, review),
			applied_this_session: applied.get(ReviewKey(group, page.page)) === JSON.stringify(SelectedBoxes(page, review)) }];
	}));
	return JSON.stringify({ format: "panels_revision_feedback", version: 1, report_id: data.id, exported_at: new Date().toISOString(), entries }, null, 2);
}
async function CopyFeedback(): Promise<void> {
	const text = ExportFeedback();
	try { await navigator.clipboard.writeText(text); Status("All feedback copied. Paste it in the conversation."); }
	catch {
		Element<HTMLTextAreaElement>("export-text").value = text; Element<HTMLDialogElement>("export-dialog").showModal();
		Element<HTMLTextAreaElement>("export-text").select(); Status("Clipboard unavailable. Press Ctrl+C in the export dialog.");
	}
}
function Point(event: PointerEvent, clamp: boolean): [number, number] {
	const point = new DOMPoint(event.clientX, event.clientY).matrixTransform(canvas.getScreenCTM()!.inverse());
	if (!clamp) return [point.x, point.y];
	return [Math.max(0, Math.min(active!.page.width, point.x)), Math.max(0, Math.min(active!.page.height, point.y))];
}
canvas.addEventListener("pointerdown", event => {
	if (!active || drag || event.button !== 0) return;
	FlushNotes(); const target = event.target as SVGElement;
	const targetIndex = Number(target.dataset.index ?? -1);
	const handle = target.dataset.handle || "";
	if (!drawMode && targetIndex < 0) { selected = -1; RenderEditor(); return; }
	const index = drawMode && !handle ? -1 : targetIndex;
	drag = { item: active, start: Point(event, !handle), initial: EditorBoxes(), index, targetIndex, handle, pointer: event.pointerId };
	selected = index;
	canvas.setPointerCapture(event.pointerId); event.preventDefault();
});
function DragBoxes(current: Drag, event: PointerEvent): Box[] {
	const [px, py] = Point(event, !current.handle);
	const [sx, sy] = current.start;
	const dx = px - sx, dy = py - sy;
	if (!dx && !dy) return current.initial;
	const boxes = current.initial.slice();
	const { width, height } = current.item.page;
	if (current.index < 0) {
		if (Math.abs(dx) >= 3 && Math.abs(dy) >= 3) boxes.push([Math.min(sx, px), Math.min(sy, py), Math.abs(dx), Math.abs(dy)]);
	} else {
		const [x, y, w, h] = current.initial[current.index]!;
		if (!current.handle) boxes[current.index] = [Math.max(0, Math.min(width - w, x + dx)), Math.max(0, Math.min(height - h, y + dy)), w, h];
		else {
			let left = x, top = y, right = x + w, bottom = y + h;
			if (current.handle.includes("w")) left = Math.max(0, Math.min(x + dx, right - 1));
			if (current.handle.includes("e")) right = Math.min(width, Math.max(right + dx, left + 1));
			if (current.handle.includes("n")) top = Math.max(0, Math.min(y + dy, bottom - 1));
			if (current.handle.includes("s")) bottom = Math.min(height, Math.max(bottom + dy, top + 1));
			boxes[current.index] = [left, top, right - left, bottom - top];
		}
	}
	return boxes;
}
canvas.addEventListener("pointermove", event => {
	if (!drag || drag.item !== active || drag.pointer !== event.pointerId) return;
	drag.preview = DragBoxes(drag, event);
	selected = drag.preview.length > drag.initial.length ? drag.preview.length - 1 : drag.targetIndex;
	RenderEditor();
});
canvas.addEventListener("pointerup", event => {
	if (!drag || drag.pointer !== event.pointerId) return;
	const current = drag; drag = undefined;
	if (current.item !== active) return;
	const boxes = DragBoxes(current, event);
	selected = boxes.length > current.initial.length ? boxes.length - 1 : current.targetIndex;
	if (JSON.stringify(boxes) !== JSON.stringify(current.initial)) {
		SetCustom(boxes.map((box, index) => box === current.initial[index] ? box : box.map(n => Math.round(n * 1000) / 1000) as Box));
	} else RenderEditor();
});
canvas.addEventListener("lostpointercapture", event => {
	if (drag?.pointer !== event.pointerId) return;
	drag = undefined;
	RenderEditor();
});
function Action(id: string, action: () => void | Promise<void>): void { Element(id).addEventListener("click", () => { Promise.resolve().then(action).catch(error => Status(error.message, true)); }); }
Action("prev", () => MovePage(-1)); Action("next", () => MovePage(1));
Action("copy", CopyFeedback);
Action("download", () => {
	const url = URL.createObjectURL(new Blob([ExportFeedback()], { type: "application/json" }));
	const link = document.createElement("a"); link.href = url; link.download = `panels-feedback-${new Date().toISOString().slice(0, 10)}.json`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
Action("close-export", () => Element<HTMLDialogElement>("export-dialog").close());
Action("save-page", () => SaveMapping(false)); Action("save-book", () => SaveMapping(true));
Action("mode-draw", () => { drawMode = true; RememberSession(); Element("mode-draw").setAttribute("aria-pressed", "true"); Element("mode-move").setAttribute("aria-pressed", "false"); RenderEditor(); });
Action("mode-move", () => { drawMode = false; RememberSession(); Element("mode-draw").setAttribute("aria-pressed", "false"); Element("mode-move").setAttribute("aria-pressed", "true"); RenderEditor(); });
Action("full-page", () => { if (active) { selected = 0; SetCustom([[0, 0, active.page.width, active.page.height]]); } });
Action("clear", () => { selected = -1; SetCustom([]); });
Action("undo", () => {
	if (!active) return; const previous = history.get(ReviewKey(active.group, active.page.page))?.pop();
	if (previous) { Commit(previous); selected = -1; RenderEditor(); }
});
Action("delete", () => { if (selected >= 0) { const boxes = structuredClone(EditorBoxes()); boxes.splice(selected, 1); selected = -1; SetCustom(boxes); } });
for (const [id, delta] of [["up", -1], ["down", 1]] as const) Action(id, () => {
	const boxes = structuredClone(EditorBoxes()); const destination = selected + delta;
	if (selected < 0 || destination < 0 || destination >= boxes.length) return;
	[boxes[selected], boxes[destination]] = [boxes[destination]!, boxes[selected]!]; selected = destination; SetCustom(boxes);
});
Action("apply-coordinates", () => {
	if (!active || selected < 0) return;
	const box = ["x", "y", "w", "h"].map(key => Number(Element<HTMLInputElement>(key).value)) as Box;
	const boxes = structuredClone(EditorBoxes()); boxes[selected] = box;
	ParseReview({ ...CurrentReview(), choice: "custom", boxes }, active.page); SetCustom(boxes);
});
Element<HTMLInputElement>("zoom").addEventListener("input", () => { Element("zoom-label").textContent = Element<HTMLInputElement>("zoom").value + "%"; RenderEditor(); RememberSession(); });
Element("notes").addEventListener("input", () => {
	if (!active) return; Commit({ ...CurrentReview(), notes: Element<HTMLTextAreaElement>("notes").value }, false);
	clearTimeout(notesTimer); notesTimer = setTimeout(() => { notesTimer = undefined; if (active) Sync(active, CurrentReview()); }, 450);
});
Element("page-list").addEventListener("click", event => { const button = (event.target as HTMLElement).closest<HTMLButtonElement>("button[data-item]"); if (button) Open(items[Number(button.dataset.item)]!); });
Element("rect-list").addEventListener("click", event => { const button = (event.target as HTMLElement).closest<HTMLButtonElement>("button[data-rect]"); if (button) { selected = Number(button.dataset.rect); RenderEditor(); } });
for (const id of ["comparisons", "choices"]) Element(id).addEventListener("click", event => {
	const button = (event.target as HTMLElement).closest<HTMLButtonElement>("button"); if (!button || !active) return;
	if (button.dataset.choice) Choose(button.dataset.choice as Choice);
	if (button.dataset.edit) { selected = -1; SetCustom(active.page[button.dataset.edit as "expected" | "previous" | "detected"]); Element("editor").scrollIntoView({ behavior: "smooth" }); }
});
for (const id of ["book", "algorithm", "filter", "search"]) Element(id).addEventListener("change", () => { FlushNotes(); if (id === "algorithm") { SetupBooks(); Element<HTMLInputElement>("search").value = ""; } RenderList(); if (items[0]) Open(items[0]); else { active = undefined; Element("main").classList.add("hidden"); RememberSession(); } });
Element<HTMLInputElement>("import").addEventListener("change", async event => {
	try {
		const file = (event.target as HTMLInputElement).files?.[0]; if (!file) return;
		const input = JSON.parse(await file.text()) as { format: string; entries: { group: string; page: number; review: Review }[] };
		if (input.format !== "panels_revision_feedback" || !Array.isArray(input.entries)) throw new Error("Not a panels_revision feedback export");
		const validated = input.entries.map(entry => {
			const page = data.diagnostics.books[entry.group]?.find(p => p.page === entry.page); if (!page) throw new Error("Import contains an unknown page");
			return { item: { group: entry.group, page }, review: ParseReview(entry.review, page) };
		});
		FlushNotes();
		for (const { item, review } of validated) { reviews[ReviewKey(item.group, item.page.page)] = review; Sync(item, review); }
		RememberLocal(); RenderList(); if (active) Open(active); Status(`Imported ${validated.length} reviews.`);
	} catch (error) { Status((error as Error).message, true); }
});
async function PollRun(): Promise<void> {
	if (polling) return; polling = true;
	try {
		const run = await Request<Run>("/api/run");
		runActive = run.phase === "tests" || run.phase === "diagnostics";
		Element<HTMLButtonElement>("run").disabled = runActive;
		Element("run-summary").textContent = `Test runner (${run.algorithm || "all"}): ${run.phase} · ${run.pages} pages diagnosed${run.test_exit === undefined ? "" : ` · tests exit ${run.test_exit}`}`;
		Element("run-info").textContent = [run.error, run.log].filter(Boolean).join("\n");
		RenderDecision();
		if (run.phase === "complete" && run.id !== handledRun) {
			const latest = await Request<Data>("/api/data");
			handledRun = run.id;
			if (latest.id !== data.id) {
				FlushNotes(); data = latest; SetupBooks(); RenderList(); if (items[0]) Open(items[0]); else { active = undefined; Element("main").classList.add("hidden"); }
				Status(`Diagnosis refreshed. Tests ${run.test_exit === 0 ? "passed" : "reported failures"}; existing reviews are retained. Older decisions need confirmation.`);
			}
		}
	} catch (error) { Status(`Runner: ${(error as Error).message}`, true); }
	finally { polling = false; }
}
Action("run", async () => { FlushNotes(); await serverQueue; await Request("/api/run", { algorithm: Element<HTMLSelectElement>("algorithm").value }); Element<HTMLDetailsElement>("run-details").open = true; await PollRun(); });
function SetupBooks(): void {
	const selectedBook = Element<HTMLSelectElement>("book").value;
	const algorithm = Element<HTMLSelectElement>("algorithm").value;
	const books = [...new Set(Object.values(data.diagnostics.groups).filter(info => algorithm === "all" || info.algorithm === algorithm).map(info => info.book))].sort();
	Element("book").innerHTML = '<option value="">All books</option>' + books.map(book => `<option value="${Escape(book)}">${Escape(book)}</option>`).join("");
	Element<HTMLSelectElement>("book").value = books.includes(selectedBook) ? selectedBook : "";
}
async function Start(): Promise<void> {
	data = await Request<Data>("/api/data"); reviews = data.reviews;
	let local: Record<string, Review> = {};
	try { local = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}"); } catch { Status("Could not restore local drafts; disk reviews are still loaded.", true); }
	for (const [group, pages] of Object.entries(data.diagnostics.books)) for (const page of pages) {
		const key = ReviewKey(group, page.page); const draft = local[key];
		if (draft && draft.updated_at > (reviews[key]?.updated_at || "")) {
			try { reviews[key] = ParseReview(draft, page); Sync({ group, page }, reviews[key]!); } catch { Status(`Could not restore draft for ${key}.`, true); }
		}
	}
	RememberLocal(); SetupBooks();
	let session = data.session;
	try {
		const localSession = JSON.parse(localStorage.getItem("panels_revision.session.v1") || "null");
		if (localSession && (!session || localSession.updated_at > session.updated_at)) session = ParseSession(localSession);
	} catch { /* Invalid browser settings do not replace the disk session. */ }
	if (session) {
		Element<HTMLSelectElement>("algorithm").value = session.algorithm; SetupBooks();
		Element<HTMLSelectElement>("book").value = session.book;
		Element<HTMLSelectElement>("filter").value = session.filter;
		Element<HTMLInputElement>("search").value = session.search;
		Element<HTMLInputElement>("zoom").value = String(session.zoom);
		Element("zoom-label").textContent = `${session.zoom}%`; drawMode = session.drawMode;
		Element("mode-draw").setAttribute("aria-pressed", String(drawMode));
		Element("mode-move").setAttribute("aria-pressed", String(!drawMode));
	}
	RenderList();
	const [hashGroup, hashNumber] = location.hash.slice(1).split("/");
	const group = hashGroup ? decodeURIComponent(hashGroup) : session?.group;
	const number = hashNumber ? Number(hashNumber) : session?.page;
	const savedPage = group && data.diagnostics.books[group]?.find(p => p.page === number);
	if (savedPage) {
		const info = data.diagnostics.groups[group!]!;
		if (Element<HTMLSelectElement>("algorithm").value !== "all" && Element<HTMLSelectElement>("algorithm").value !== info.algorithm) {
			Element<HTMLSelectElement>("algorithm").value = info.algorithm; SetupBooks();
		}
		Open({ group: group!, page: savedPage });
	} else if (items[0]) Open(items[0]);

	Status("Ready. Reviews save automatically. Dataset changes require the Save buttons.");
	await PollRun(); setInterval(() => { void PollRun(); }, 2500);
}
window.addEventListener("beforeunload", () => { FlushNotes(); RememberLocal(); RememberSession(); });
void Start().catch(error => Status(error.message, true));
