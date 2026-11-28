import { BookF1, type Diagnostics, type F1Baseline, type Page } from "./model";

type Data = { diagnostics: Diagnostics; baselines: Record<string, F1Baseline> };
function Element<T extends HTMLElement = HTMLElement>(id: string): T {
	const element = document.getElementById(id);
	if (!element) throw new Error(`Missing ${id}`);
	return element as T;
}
function Escape(value: string): string { return value.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!); }
function Image(page: Page): string { return `/image?path=${encodeURIComponent(page.image)}`; }
function Score(data: Data, book: string, algorithm: "safe" | "smart"): string {
	const group = Object.keys(data.diagnostics.groups).find(key => data.diagnostics.groups[key]?.book === book && data.diagnostics.groups[key]?.algorithm === algorithm);
	if (!group) return `<p class="score unknown">${algorithm}: unavailable</p>`;
	const result = BookF1(data.diagnostics.books[group]!, data.baselines[group]);
	const value = `${(result.score * 100).toFixed(2)}%`;
	const label = result.score === 1 ? '100% Perfect (or biased?)' : value;
	const suffix = result.minimum === undefined ? " · baseline unavailable or stale" : ` · baseline ${(result.minimum * 100).toFixed(2)}%`;
	return `<p class="score ${result.score === 1 ? "perfect" : result.state}">${algorithm}: ${label}${suffix}</p>`;
}
async function Start(): Promise<void> {
	const response = await fetch("/api/data");
	if (!response.ok) throw new Error(`Could not load diagnostics (${response.status})`);
	const data = await response.json() as Data;
	const grid = Element("grid"), status = Element("status");
	const segment = location.pathname.slice("/books-performance".length).replace(/^\/+|\/+$/g, "");
	if (!segment) {
		const books = [...new Set(Object.values(data.diagnostics.groups).map(info => info.book))].sort();
		grid.innerHTML = books.map(book => {
			const group = Object.keys(data.diagnostics.groups).find(key => data.diagnostics.groups[key]?.book === book && data.diagnostics.books[key]?.length);
			const page = group && data.diagnostics.books[group]?.[0];
			return `<a class="card" href="/books-performance/${encodeURIComponent(book)}">${page ? `<img class="cover" src="${Escape(Image(page))}" alt="" loading="lazy">` : ""}<div class="body"><h2>${Escape(book)}</h2>${Score(data, book, "smart")}${Score(data, book, "safe")}</div></a>`;
		}).join("");
		status.textContent = books.length ? `${books.length} books` : "No diagnostic books yet. Run a diagnosis in the reviewer.";
		return;
	}
	let book: string;
	try { book = decodeURIComponent(segment); } catch { throw new Error("Invalid book name."); }
	const groups = Object.entries(data.diagnostics.groups).filter(([, info]) => info.book === book);
	if (!groups.length) throw new Error("Book not found in the saved diagnostics.");
	Element("title").textContent = book;
	Element<HTMLAnchorElement>("back").href = "/books-performance";
	Element("back").textContent = "← All books";
	Element("description").textContent = "Green pages match the mapping; red pages differ, just like the reviewer sidebar. Select a page to review it. A difference is a finding, not necessarily an error.";
	Element("controls").hidden = false;
	const algorithm = Element<HTMLSelectElement>("algorithm"), filter = Element<HTMLSelectElement>("filter"), columns = Element<HTMLInputElement>("columns");
	if (!groups.some(([, info]) => info.algorithm === "safe")) algorithm.value = "smart";
	for (const option of algorithm.options) option.disabled = !groups.some(([, info]) => info.algorithm === option.value);
	try { columns.value = localStorage.getItem("panels_revision.performance_columns") || "5"; } catch { /* Use the default. */ }
	function Render(): void {
		const group = groups.find(([, info]) => info.algorithm === algorithm.value)?.[0];
		const pages = group ? data.diagnostics.books[group] || [] : [];
		const visible = pages.filter(page => filter.value === "all" || !page.correct);
		grid.classList.add("pages"); grid.style.setProperty("--columns", columns.value); Element("columns-value").textContent = columns.value;
		grid.innerHTML = visible.map(page => `<a class="card page ${page.correct ? "" : "different"}" href="/#${encodeURIComponent(group!)}/${page.page}"><img src="${Escape(Image(page))}" alt="" loading="lazy"><div class="body"><h2>Page ${page.page}</h2><small>${page.correct ? "Matches mapping" : "Differs from mapping"} · ${page.expected.length} → ${page.detected.length} panels</small></div></a>`).join("");
		status.textContent = `${visible.length} shown · ${pages.filter(page => !page.correct).length} differences / ${pages.length} mapped pages`;
	}
	algorithm.addEventListener("change", Render); filter.addEventListener("change", Render);
	columns.addEventListener("input", () => { try { localStorage.setItem("panels_revision.performance_columns", columns.value); } catch { /* The control still works. */ } Render(); });
	Render();
}
Start().catch(error => { Element("status").textContent = error instanceof Error ? error.message : String(error); });
