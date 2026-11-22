import { afterEach, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BookF1 } from "./model";
import type { Page } from "./model";

test("book F1 distinguishes baseline regressions, perfect scores and unavailable baselines", () => {
	const pages = [{ expected: [[0, 0, 1, 1], [1, 1, 1, 1]], detected: [[0, 0, 1, 1]], tp: 1 }] as Page[];
	const baseline = { f1: 0.6, pages_evaluated: 1, total_ground_truth: 2, iou_threshold: 0.5, gap_tolerance: 35 };
	expect(BookF1(pages, baseline).state).toBe("pass");
	expect(BookF1(pages, { ...baseline, f1: 0.8 }).state).toBe("regression");
	expect(BookF1(pages, { ...baseline, total_ground_truth: 3 }).state).toBe("unknown");
	expect(BookF1([{ ...pages[0]!, detected: pages[0]!.expected, tp: 2 }], baseline).state).toBe("perfect");
});
import { RevisionService } from "./service";
import { ApplyReviews, BuildFeedback, PageBasis, RestoreFeedbackSession, ReviewKey, type Diagnostics, type Page, type Review } from "./model";
import { CreateRevisionServer } from "../revision";
import { RefreshDiagnostic } from "../refresh";
const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await fs.rm(root, { recursive: true, force: true }); });
const book = "Don't_Bully_Me_Nagatoro_Vol_1";
const group = `safe::${book}`;
const page: Page = { page: 1, image: `tests/dataset-mangas/dataset/${book}/00.png`, width: 100, height: 200,
	expected: [[0, 0, 100, 200]], previous: [[0, 0, 40, 200], [60, 0, 40, 200]], detected: [[0, 0, 100, 200]],
	correct: true, previous_correct: false, sequence: [1], previous_sequence: [1, 0], tp: 1, previous_tp: 1, accepted: true, reason: "" };
const diagnostics: Diagnostics = { description: "fixture", books: { [group]: [page] }, groups: { [group]: { book, algorithm: "safe" } } };
const original = { book_title: book, algorithm: "safe", extra_metadata: "keep", pages: [
	{ page_index: 1, frame: [{ x: 0, y: 0, w: 100, h: 200 }], illustration_type: "single_page", wordless: true },
	{ page_index: 2, frame: [{ x: 10, y: 20, w: 30, h: 40 }], illustration_type: "single_page" },
] };
function Review(choice: Review["choice"] = "previous"): Review { return { choice, boxes: [], notes: "Keep touching frames together", updated_at: new Date().toISOString(), basis: PageBasis(page) }; }
async function Fixture() {
	const root = await fs.mkdtemp(join(tmpdir(), "panels-revision-test-")); roots.push(root);
	const directory = join(root, "tests/dataset-mangas/dataset", book); await fs.mkdir(directory, { recursive: true });
	const path = join(directory, "panels_safe.json"); await fs.writeFile(path, JSON.stringify(original));
	const persistence = join(root, "tools/panels_revision/revision/data-persistence"); await fs.mkdir(persistence, { recursive: true });
	await fs.writeFile(join(persistence, "diagnostics.json"), JSON.stringify(diagnostics));
	return { root, path, persistence, service: new RevisionService(root, diagnostics) };
}
test("writes reviewed panels, preserves other pages and metadata, and creates an exact backup", async () => {
	const { root, path, service } = await Fixture(); const before = await fs.readFile(path, "utf8");
	const { hash } = await service.ReadMapping(group);
	const result = await service.Save(group, hash, [{ book: group, page: 1, review: Review() }]);
	const saved = JSON.parse(await fs.readFile(path, "utf8"));
	expect(saved.pages[0].frame).toEqual([{ x: 0, y: 0, w: 40, h: 200 }, { x: 60, y: 0, w: 40, h: 200 }]);
	expect(saved.pages[0].illustration_type).toBeUndefined(); expect(saved.pages[0].wordless).toBe(true);
	expect(saved.pages[1]).toEqual(original.pages[1]); expect(saved.extra_metadata).toBe("keep");
	expect(await fs.readFile(join(root, result.backup), "utf8")).toBe(before);
	expect(result.hash).not.toBe(hash);
});
test("rejects stale hashes, stale decisions, malformed rectangles and unknown groups without changing files", async () => {
	const { path, service } = await Fixture(); const before = await fs.readFile(path, "utf8"); const { hash } = await service.ReadMapping(group);
	for (const [key, token, review] of [
		[group, "old-hash", Review()], ["../other", hash, Review()],
		[group, hash, { ...Review(), basis: "old-report" }],
		[group, hash, { ...Review("custom"), boxes: [[99, 0, 5, 200]] }],
		[group, hash, { ...Review("custom"), boxes: [] }],
		[group, hash, { ...Review("custom"), boxes: [[0, 0, -1, 3]] }],
	] as const) {
		await expect(service.Save(key, token, [{ book: key, page: 1, review: review as Review }])).rejects.toThrow();
		expect(await fs.readFile(path, "utf8")).toBe(before);
	}
});
test("serializes competing writes so only the first request with the old hash succeeds", async () => {
	const { service } = await Fixture(); const { hash } = await service.ReadMapping(group);
	const entries = [{ book: group, page: 1, review: Review() }];
	const results = await Promise.allSettled([service.Save(group, hash, entries), service.Save(group, hash, entries)]);
	expect(results.map(r => r.status)).toEqual(["fulfilled", "rejected"]);
});
test("custom panels keep reading order, restore single-page metadata, and do not mutate input", () => {
	const review = { ...Review("custom"), boxes: [[20, 30, 50, 60]] as [number, number, number, number][] };
	const result = ApplyReviews(original, [page], [{ book: group, page: 1, review }]);
	expect(result.pages[0]!.frame).toEqual([{ x: 20, y: 30, w: 50, h: 60 }]);
	expect(result.pages[0]!.illustration_type).toBe("single_page"); expect(original.pages[0]!.frame[0]!.x).toBe(0);
});
test("feedback exports tab edits only and starts clean when the report changes", () => {
	const olderGroup = "safe::Older_Book";
	const otherPage = { ...page, page: 2 };
	const report: Diagnostics = {
		...diagnostics,
		books: { [group]: [page, otherPage], [olderGroup]: [page] },
		groups: { ...diagnostics.groups, [olderGroup]: { book: "Older_Book", algorithm: "safe" } },
	};
	const key = ReviewKey(group, page.page);
	const otherKey = ReviewKey(group, otherPage.page);
	const olderKey = ReviewKey(olderGroup, page.page);
	const decision = Review();
	const cleared = { ...Review("pending"), notes: "", basis: PageBasis(otherPage) };
	const reviews = { [key]: decision, [otherKey]: cleared, [olderKey]: Review() };
	const session = RestoreFeedbackSession("current", null);
	expect(BuildFeedback(report, reviews, session).entries).toEqual([]);
	session.edited[key] = decision.updated_at;
	session.edited[otherKey] = cleared.updated_at;
	session.applied[key] = JSON.stringify(page.previous);
	const reloaded = RestoreFeedbackSession("current", JSON.parse(JSON.stringify(session)));
	const exported = BuildFeedback(report, reviews, reloaded);
	expect(exported.report_id).toBe("current");
	expect(exported.entries.map(entry => [entry.group, entry.page, entry.complete, entry.applied_this_session]))
		.toEqual([[group, 1, true, true], [group, 2, false, false]]);
	const refreshed = RestoreFeedbackSession("refreshed", reloaded);
	expect(BuildFeedback(report, reviews, refreshed)).toMatchObject({ report_id: "refreshed", entries: [] });
	expect(reviews[olderKey]).toBeDefined();
	const newerReviews = { ...reviews, [key]: { ...decision, updated_at: "newer edit from a different tab" } };
	expect(BuildFeedback(report, newerReviews, reloaded).entries.map(entry => entry.page)).toEqual([2]);
});
test("HTTP saves reviews across restarts; rejects cross-origin writes, arbitrary images and changed reports", async () => {
	const { root, path } = await Fixture();
	let server = await CreateRevisionServer(root, 0);
	try {
		const initial = await fetch(new URL("api/data", server.url)).then(r => r.json()) as { id: string };
		for (const route of ["books-performance", `books-performance/${encodeURIComponent(book)}`]) {
			const result = await fetch(new URL(route, server.url));
			expect(result.status).toBe(200);
			expect(await result.text()).toContain("Books performance");
		}
		const post = (url: string, body: unknown, headers = {}) => fetch(new URL(url, server.url), { method: "POST", headers: { "content-type": "application/json", "x-revision-id": initial.id, ...headers }, body: JSON.stringify(body) });
		expect((await post("api/review", { book: group, page: 1, review: Review() })).status).toBe(200);
		expect((await post("api/review", {}, { origin: "https://example.com" })).status).toBe(403);
		expect((await post("api/review", {}, { "x-revision-id": "stale" })).status).toBe(409);
		expect((await fetch(new URL("image?path=/etc/passwd", server.url))).status).toBe(404);
		expect((await fetch(new URL("unknown", server.url))).status).toBe(404);
		expect(JSON.parse(await fs.readFile(path, "utf8"))).toEqual(original);
		server.stop(true); server = await CreateRevisionServer(root, 0);
		const resumed = await fetch(new URL("api/data", server.url)).then(r => r.json()) as { reviews: Record<string, Review> };
		expect(Object.values(resumed.reviews)[0]!.notes).toBe("Keep touching frames together");
	} finally { server.stop(true); }
});

test("automation keeps test failures visible, generates page diagnostics, and compares with the last run", async () => {
	const { Runs } = await import("./runs");
	const { root, persistence } = await Fixture();
	await fs.writeFile(join(root, "run-tests.sh"), '#!/bin/sh\n[ "$PANELSPLUS_TEST_ALGORITHM" = safe ] || exit 99\necho "fixture panel tests failed"\nexit 1\n');
	const generated = { ...page, book, algorithm: "safe", detected: page.previous, correct: false, tp: 1, sequence: [1, 0] };
	await fs.writeFile(join(persistence, "../diagnose.lua"), `print([=[${JSON.stringify(generated)}]=])`);
	let output: Diagnostics | undefined;
	const runs = new Runs(root, persistence, async value => { output = value; });
	const otherGroup = `smart::${book}`;
	const prior: Diagnostics = { ...diagnostics, books: { ...diagnostics.books, [otherGroup]: [page] }, groups: { ...diagnostics.groups, [otherGroup]: { book, algorithm: "smart" } } };
	await runs.Initialize(); runs.Start(prior, "safe");
	expect(() => runs.Start(diagnostics)).toThrow("ejecución");
	await runs.Completion;
	expect(runs.Current.phase).toBe("complete"); expect(runs.Current.test_exit).toBe(1);
	expect(runs.Current.pages).toBe(1); expect(runs.Current.log).toContain("fixture panel tests failed");
	expect(output!.books[group]![0]!.previous).toEqual(page.detected);
	expect(output!.books[group]![0]!.detected).toEqual(page.previous);
	expect(output!.books[otherGroup]).toEqual(prior.books[otherGroup]);
	const restart = new Runs(root, persistence, async () => {}); await restart.Initialize();
	expect(restart.Current.phase).toBe("complete");
	// Repeating the same output must not erase a useful before/after comparison.
	runs.Start(output!, "safe");
	await runs.Completion;
	expect(runs.Current.phase).toBe("complete");
	expect(output!.books[group]![0]!.previous).toEqual(page.detected);
});

test("Safe and Smart keep different pages and reviews; startup resumes the session without rescanning", async () => {
	const { root, persistence, path } = await Fixture();
	const smartGroup = `smart::${book}`;
	const smartPage = { ...page, page: 2, expected: [[10, 20, 30, 40]] as Page["expected"] };
	const report: Diagnostics = {
		description: "two algorithms", books: { [group]: [page], [smartGroup]: [smartPage] },
		groups: { [group]: { book, algorithm: "safe" }, [smartGroup]: { book, algorithm: "smart" } },
	};
	await fs.writeFile(join(persistence, "diagnostics.json"), JSON.stringify(report));
	const smartPath = path.replace("panels_safe.json", "panels_smart.json");
	await fs.writeFile(smartPath, JSON.stringify({ ...original, algorithm: "smart" }));
	let server = await CreateRevisionServer(root, 0);
	try {
		const get = () => fetch(new URL("api/data", server.url)).then(r => r.json()) as Promise<{ id: string; diagnostics: Diagnostics; hashes: Record<string, string>; reviews: Record<string, Review>; session: { algorithm: string; page: number; zoom: number } }>;
		const loaded = await get();
		expect(loaded.diagnostics.books[group]!.map(p => p.page)).toEqual([1]);
		expect(loaded.diagnostics.books[smartGroup]!.map(p => p.page)).toEqual([2]);
		const post = (route: string, body: unknown) => fetch(new URL(route, server.url), { method: "POST", headers: { "content-type": "application/json", "x-revision-id": loaded.id }, body: JSON.stringify(body) });
		expect((await post("api/review", { book: group, page: 1, review: Review() })).status).toBe(200);
		const smartReview = { ...Review(), notes: "Smart-specific observation", basis: PageBasis(smartPage) };
		expect((await post("api/review", { book: smartGroup, page: 2, review: smartReview })).status).toBe(200);
		const safeReviews = JSON.parse(await fs.readFile(join(persistence, "safe/reviews.json"), "utf8"));
		const smartReviews = JSON.parse(await fs.readFile(join(persistence, "smart/reviews.json"), "utf8"));
		expect(Object.keys(safeReviews)).toEqual([`${group}:1`]); expect(Object.keys(smartReviews)).toEqual([`${smartGroup}:2`]);
		const beforeSafe = await fs.readFile(path, "utf8");
		expect((await post("api/mapping", { book: smartGroup, hash: loaded.hashes[smartGroup], entries: [{ book: smartGroup, page: 2, review: smartReview }] })).status).toBe(200);
		expect(await fs.readFile(path, "utf8")).toBe(beforeSafe);
		const session = { algorithm: "smart", book, filter: "all", search: "", group: smartGroup, page: 2, zoom: 175, drawMode: false, updated_at: new Date().toISOString() };
		expect((await post("api/session", session)).status).toBe(200);
		server.stop(true); server = await CreateRevisionServer(root, 0);
		const resumed = await get();
		expect(resumed.id).toBe(loaded.id); expect(resumed.session).toEqual(session);
		expect(resumed.reviews[`${smartGroup}:2`]!.notes).toBe("Smart-specific observation");
		expect(resumed.reviews[`${group}:1`]!.notes).toBe("Keep touching frames together");
		expect(await Bun.file(join(persistence, "run.json")).exists()).toBe(false);
		const index = JSON.parse(await fs.readFile(join(persistence, "diagnostics.json"), "utf8"));
		expect(index.files.safe).toStartWith("safe/"); expect(index.files.smart).toStartWith("smart/");
	} finally { server.stop(true); }
});

test("scoped refresh persists one complete diagnostic and retains the previous comparison", async () => {
	const { root, persistence } = await Fixture();
	const indexPath = join(persistence, "diagnostics.json");
	const server = await CreateRevisionServer(root, 0);
	const port = server.port!;
	try {
		await expect(RefreshDiagnostic(root, "safe", book, port)).rejects.toThrow("Stop the reviewer");
	} finally { server.stop(true); }
	const oldIndex = await fs.readFile(indexPath, "utf8");
	const smartFile = JSON.parse(oldIndex).files.smart;
	const smartBytes = await fs.readFile(join(persistence, smartFile), "utf8");
	const reviewsPath = join(persistence, "safe/reviews.json");
	const reviews = await fs.readFile(reviewsPath, "utf8");
	const diagnosePath = join(persistence, "../diagnose.lua");
	const first = { ...page, book, algorithm: "safe", directory: "dataset", detected: page.previous, correct: false, sequence: [1, 0] };
	const second = { ...first, page: 2, image: first.image.replace("00.png", "01.png"), expected: [[10, 20, 30, 40]], detected: [[10, 20, 30, 40]], correct: true, sequence: [1] };
	await fs.writeFile(diagnosePath, `print([=[${JSON.stringify(first)}]=])`);
	await expect(RefreshDiagnostic(root, "safe", book, port)).rejects.toThrow("Incomplete diagnostic");
	expect(await fs.readFile(indexPath, "utf8")).toBe(oldIndex);
	await fs.writeFile(diagnosePath, `print([=[${JSON.stringify(first)}]=])\nprint([=[${JSON.stringify(second)}]=])`);
	expect(await RefreshDiagnostic(root, "safe", book, port)).toEqual({ pages: 2, differences: 1, changed: true });
	const index = JSON.parse(await fs.readFile(indexPath, "utf8"));
	const saved = JSON.parse(await fs.readFile(join(persistence, index.files.safe), "utf8")) as Diagnostics;
	expect(saved.books[group]![0]!.previous).toEqual(page.detected);
	expect(saved.books[group]![0]!.detected).toEqual(page.previous);
	expect(index.files.smart).toBe(smartFile);
	expect(await fs.readFile(join(persistence, smartFile), "utf8")).toBe(smartBytes);
	expect(await fs.readFile(reviewsPath, "utf8")).toBe(reviews);
	expect(await RefreshDiagnostic(root, "safe", book, port)).toEqual({ pages: 2, differences: 1, changed: false });
	expect((await fs.readdir(persistence)).filter(name => name.startsWith("diagnostics-before-"))).toHaveLength(1);
});
