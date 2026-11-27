import * as fs from "node:fs/promises";
import { resolve, join } from "node:path";
import html from "./revision.html";
import performanceHtml from "./performance.html";
import { RevisionService, Digest } from "./revision/service";
import {
    ParseReview,
    ParseSession,
    type Session,
    ReviewKey,
    type Diagnostics,
    type Review,
    type ReviewEntry,
    type F1Baseline,
} from "./revision/model";
import { Runs } from "./revision/runs";
import { PersistJson, PersistReportPartition, ReadReportPartition, type ReportIndex } from "./revision/report";

export async function CreateRevisionServer(
    root = resolve(import.meta.dir, "../.."),
    port = 3210,
) {
    const directory = join(
        root,
        "tools/panels_revision/revision/data-persistence",
    );
    await fs.mkdir(directory, { recursive: true });
    async function readJson<T>(path: string, fallback: T): Promise<T> {
        try {
            return JSON.parse(await fs.readFile(path, "utf8")) as T;
        } catch (e) {
            if ((e as NodeJS.ErrnoException).code === "ENOENT") return fallback;
            throw e;
        }
    }
    const persist = (name: string, value: unknown) => PersistJson(join(directory, name), value);
    const stored = await readJson<Diagnostics | ReportIndex | null>(join(directory, "diagnostics.json"), null);
    let diagnostics: Diagnostics | null = null;
    if (stored && "format" in stored && stored.format === "panels_revision_index") {
        const parts = await Promise.all((["safe", "smart"] as const).map(algorithm => ReadReportPartition(directory, stored, algorithm)));
        diagnostics = { description: parts[0]!.description, books: {}, groups: {} };
        for (const part of parts) { Object.assign(diagnostics.books, part.books); Object.assign(diagnostics.groups, part.groups); }
    } else diagnostics = stored as Diagnostics | null;
    async function persistDiagnostics(value: Diagnostics): Promise<void> {
        value.books = Object.fromEntries(Object.entries(value.books).sort(([a], [b]) => a.localeCompare(b)));
        value.groups = Object.fromEntries(Object.entries(value.groups).sort(([a], [b]) => a.localeCompare(b)));
        const files = {} as Record<"safe" | "smart", string>;
        for (const algorithm of ["safe", "smart"] as const) {
            files[algorithm] = await PersistReportPartition(directory, value, algorithm);
        }
        // Commit the index last so a crash cannot publish half a report.
        await persist("diagnostics.json", { format: "panels_revision_index", files });
    }
    if (!diagnostics) {
        const seed = await readJson<Diagnostics | null>(
            join(
                root,
                "tests/dataset-mangas/report/safe-diagnostics-2026-11-21.json",
            ),
            null,
        );
        diagnostics = {
            description:
                seed?.description ||
                "Run the panel tests to generate a report.",
            books: {},
            groups: {},
        };
        for (const [book, pages] of Object.entries(seed?.books || {})) {
            const key = `safe::${book}`;
            diagnostics.books[key] = pages;
            diagnostics.groups[key] = { book, algorithm: "safe" };
        }

    }
    await persistDiagnostics(diagnostics);
    let id = Digest(JSON.stringify(diagnostics));
    let service = new RevisionService(root, diagnostics);
    const legacyReviews = await readJson<Record<string, Review>>(join(directory, "reviews.json"), {});
    let reviews: Record<string, Review> = {};
    for (const algorithm of ["safe", "smart"] as const) {
        const previous = Object.fromEntries(Object.entries(legacyReviews).filter(([key]) => key.startsWith(`${algorithm}::`)));
        const partition = await readJson<Record<string, Review>>(join(directory, algorithm, "reviews.json"), previous);
        Object.assign(reviews, partition); await persist(`${algorithm}/reviews.json`, partition);
    }
    let session = await readJson<Session | null>(join(directory, "session.json"), null);
    let reviewQueue: Promise<unknown> = Promise.resolve();
    const runs = new Runs(root, directory, async (next) => {
        await persist(`diagnostics-before-${Date.now()}.json`, diagnostics);
        await persistDiagnostics(next);
        diagnostics = next;
        id = Digest(JSON.stringify(next));
        service = new RevisionService(root, next);
    });
    await runs.Initialize();
    return Bun.serve({
        hostname: "127.0.0.1",
        port,
        maxRequestBodySize: 4 * 1024 * 1024,
        development: false,
        routes: { "/": html, "/revision.html": html, "/books-performance": performanceHtml, "/books-performance/*": performanceHtml },
        async fetch(request) {
            const url = new URL(request.url);
            if (
                request.headers.get("origin") &&
                request.headers.get("origin") !== url.origin
            )
                return new Response("Origin not allowed", { status: 403 });
            const json = (value: unknown) =>
                Response.json(value, {
                    headers: { "cache-control": "no-store" },
                });
            try {
                if (request.method === "GET" && url.pathname === "/api/data") {
                    const hashes: Record<string, string> = {};
                    const baselines: Record<string, F1Baseline> = {};
                    for (const group of Object.keys(diagnostics!.books)) {
                        const { hash, mapping } = await service.ReadMapping(group);
                        hashes[group] = hash;
                        const info = diagnostics!.groups[group]!;
                        const pages = diagnostics!.books[group]!;
                        const mappedPages = info.algorithm === "smart"
                            ? mapping.pages.filter(page => page.frame.length > 0)
                            : mapping.pages;
                        const current = mappedPages.length === pages.length && pages.every(page => {
                            const mapped = mappedPages.find(p => p.page_index === page.page);
                            return mapped && JSON.stringify(mapped.frame.map(b => [b.x, b.y, b.w, b.h])) === JSON.stringify(page.expected);
                        });
                        if (!current) continue;
                        const dataset = info.directory || (pages[0]?.image.includes("/dataset-textbasedformats/") ? "dataset-textbasedformats" : "dataset");
                        const records = await readJson<Record<string, F1Baseline>>(join(root, "tests/dataset-mangas", dataset, info.book, "bestbenchmark.json"), {});
                        const baseline = records[`${info.algorithm}_full_volume`] || (info.algorithm === "smart" ? records.components_conservative_full_volume : undefined);
                        if (baseline && typeof baseline.f1 === "number") baselines[group] = baseline;
                    }
                    return json({ id, diagnostics, hashes, baselines, reviews, session });
                }
                if (request.method === "GET" && url.pathname === "/api/run")
                    return json(runs.Current);
                if (request.method === "GET" && url.pathname === "/image") {
                    const path = url.searchParams.get("path");
                    const allowed =
                        path &&
                        Object.values(diagnostics!.books).some((pages) =>
                            pages.some((p) => p.image === path),
                        );
                    if (!allowed)
                        return new Response("Unknown image", { status: 404 });
                    const image = Bun.file(resolve(root, path));
                    return (await image.exists())
                        ? new Response(image)
                        : new Response("Missing image", { status: 404 });
                }
                if (
                    request.method !== "POST" ||
                    !["/api/review", "/api/mapping", "/api/run", "/api/session"].includes(
                        url.pathname,
                    )
                )
                    return new Response("Not found", { status: 404 });
                if (
                    request.headers.get("x-revision-id") !== id ||
                    !request.headers
                        .get("content-type")
                        ?.startsWith("application/json")
                )
                    return new Response(
                        "Report changed. Reload; your local drafts remain saved.",
                        { status: 409 },
                    );
                const body: unknown = await request.json();
                if (!body || typeof body !== "object")
                    throw new Error("Invalid request");
                if (url.pathname === "/api/run") {
                    const algorithm = (body as Record<string, unknown>).algorithm ?? "all";
                    if (algorithm !== "safe" && algorithm !== "smart" && algorithm !== "all") throw new Error("Unknown algorithm");
                    return json(runs.Start(diagnostics!, algorithm));
                }
                if (url.pathname === "/api/session") {
                    const next = ParseSession(body); await persist("session.json", next); session = next;
                    return json({ saved: true });
                }
                const { book, hash, entries, page, review } = body as Record<
                    string,
                    unknown
                >;
                if (
                    typeof book !== "string" ||
                    !Object.hasOwn(diagnostics!.books, book)
                )
                    throw new Error("Unknown group");
                if (url.pathname === "/api/review") {
                    const source = diagnostics!.books[book]!.find(
                        (p) => p.page === page,
                    );
                    if (!source) throw new Error("Unknown page");
                    const parsed = ParseReview(review, source);
                    const operation = reviewQueue.then(async () => {
                        const next = {
                            ...reviews,
                            [ReviewKey(book, source.page)]: parsed,
                        };
                        const algorithm = diagnostics!.groups[book]!.algorithm;
                        const partition = Object.fromEntries(Object.entries(next).filter(([key]) => key.startsWith(`${algorithm}::`)));
                        await persist(`${algorithm}/reviews.json`, partition);
                        reviews = next;
                    });
                    reviewQueue = operation.catch(() => {});
                    await operation;
                    return json({ saved: true });
                }
                if (["tests", "diagnostics"].includes(runs.Current.phase))
                    throw new Error(
                        "Wait for the tests to finish before modifying mappings.",
                    );
                if (typeof hash !== "string" || !Array.isArray(entries))
                    throw new Error("Invalid mapping request");
                return json(
                    await service.Save(book, hash, entries as ReviewEntry[]),
                );
            } catch (error) {
                console.error(error);
                return Response.json(
                    {
                        error:
                            error instanceof Error
                                ? error.message
                                : "Request failed",
                    },
                    { status: 400 },
                );
            }
        },
    });
}
if (import.meta.main) {
    const server = await CreateRevisionServer(
        undefined,
        Number(process.env.REVISION_PORT || 3210),
    );
    console.log(
        `Panels revision: ${server.url}\nData: tools/panels_revision/revision/data-persistence/`,
    );
}
