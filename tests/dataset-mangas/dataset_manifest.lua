--[[
Panels+
File: tests/dataset-mangas/dataset_manifest.lua
Name: DatasetManifest
Description: Loads dataset metadata, page paths, annotations, and reading direction.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Dataset manifest loader for manga and comic panel evaluation.
---
--- Parses and normalizes dataset metadata and ground-truth frames.

local JSON = require("tests.helpers.json")

local Manifest = {
    _manga_cache = nil,
}

local DEFAULT_MANGA_DIR = "tests/dataset-mangas/dataset"
local FALLBACK_MANGA_DIR = "tests/dataset-mangas/dataset-private"

--- Resolve image path checking dataset root, book folder, and basename fallback.
local function resolveImagePath(dataset_dir, book_dir, rel_img)
    if not rel_img then
        return nil
    end
    -- 1. Try dataset_dir .. "/" .. rel_img
    local p1 = dataset_dir .. "/" .. rel_img
    local f1 = io.open(p1, "r")
    if f1 then
        f1:close()
        return p1
    end
    -- 2. Try book_dir .. "/" .. rel_img
    local p2 = book_dir .. "/" .. rel_img
    local f2 = io.open(p2, "r")
    if f2 then
        f2:close()
        return p2
    end
    -- 3. Try book_dir .. "/" .. filename
    local fname = rel_img:match("[^/\\]+$") or rel_img
    local p3 = book_dir .. "/" .. fname
    local f3 = io.open(p3, "r")
    if f3 then
        f3:close()
        return p3
    end
    return p1
end

--- Parse decoded books JSON structure into normalized book and page tables.
local function loadDatasetMetadata(book_dir)
    local metadata_path = book_dir .. "/metadata.json"
    local f = io.open(metadata_path, "r")
    if not f then
        return "manga"
    end

    local raw = f:read("*a")
    f:close()
    local metadata = JSON.decode(raw)
    local dataset_type = metadata and metadata.type or nil
    if dataset_type ~= "manga" and dataset_type ~= "comic" then
        error(string.format('%s must contain type "manga" or "comic"', metadata_path))
    end
    local color_mode = metadata.color_mode
    if color_mode ~= nil then
        if dataset_type ~= "comic" then
            error(metadata_path .. ": color_mode is only valid for comic datasets")
        end
        if color_mode ~= "true_b/w" and color_mode ~= "colorless_b/w" and color_mode ~= "color" then
            error(metadata_path .. ': color_mode must be "true_b/w", "colorless_b/w", or "color"')
        end
    end
    return dataset_type, color_mode
end

local function parseBooksFromRaw(raw_books, dataset_dir, book_dir)
    local books = {}
    for _, raw_book in ipairs(raw_books) do
        local effective_book_dir = book_dir or (dataset_dir .. "/" .. (raw_book.book_title or ""))
        -- A root annotation file can contain books with different metadata.
        if effective_book_dir == dataset_dir then
            local nested_dir = dataset_dir .. "/" .. (raw_book.book_title or "")
            local nested_meta = io.open(nested_dir .. "/metadata.json", "r")
            if nested_meta then
                nested_meta:close()
                effective_book_dir = nested_dir
            end
        end
        local dataset_type, color_mode = loadDatasetMetadata(effective_book_dir)
        local book = {
            book_title = raw_book.book_title,
            directory = effective_book_dir,
            type = dataset_type,
            color_mode = color_mode,
            pages = {},
        }
        for _, raw_page in ipairs(raw_book.pages or {}) do
            local rel_img = nil
            if raw_page.image_paths and type(raw_page.image_paths) == "table" then
                rel_img = raw_page.image_paths.en or raw_page.image_paths.ja
                if not rel_img then
                    for _, path in pairs(raw_page.image_paths) do
                        if type(path) == "string" then
                            rel_img = path
                            break
                        end
                    end
                end
            end
            local img_path = resolveImagePath(dataset_dir, effective_book_dir, rel_img)
            local frames = {}
            for _, rf in ipairs(raw_page.frame or {}) do
                table.insert(frames, {
                    x = rf.x,
                    y = rf.y,
                    w = rf.w,
                    h = rf.h,
                })
            end
            local phrases = {}
            for _, rp in ipairs(raw_page.phrase or {}) do
                table.insert(phrases, {
                    x = rp.x,
                    y = rp.y,
                    w = rp.w,
                    h = rp.h,
                    phrase_id = rp.phrase_id,
                })
            end
            local words = {}
            for _, rw in ipairs(raw_page.word or {}) do
                table.insert(words, {
                    x = rw.x,
                    y = rw.y,
                    w = rw.w,
                    h = rw.h,
                    phrase_id = rw.phrase_id,
                })
            end
            local illustration_type = raw_page.illustration_type
            if illustration_type ~= "single_page" and illustration_type ~= "double_page" then
                illustration_type = #frames == 1 and "single_page" or nil
            end

            table.insert(book.pages, {
                dataset = dataset_type,
                type = dataset_type,
                color_mode = color_mode,
                book_title = raw_book.book_title,
                page_index = raw_page.page_index,
                image_path = img_path,
                reading_order = dataset_type,
                frames = frames,
                phrases = phrases,
                words = words,
                text_direction = raw_page.text_direction or "ltr",
                illustration_type = illustration_type,
                text = raw_page.text or {},
            })
        end
        table.insert(books, book)
    end
    return books
end

--- Load and cache manga/comic datasets.
---
--- Supports both per-book `dataset/<manganame>/annotation.json` and optional root `dataset/annotation.json`.
---
--- @param dataset_dir string|nil Path to dataset directory (defaults to "tests/dataset-mangas/dataset")
--- @return table List of books with pages and annotations
function Manifest.loadManga(dataset_dir)
    if not dataset_dir then
        -- Check if DEFAULT_MANGA_DIR exists or contains books
        local test_pipe = io.popen(string.format('ls -d "%s"/*/annotation.json 2>/dev/null', DEFAULT_MANGA_DIR), "r")
        local has_books = false
        if test_pipe then
            local line = test_pipe:read("*l")
            test_pipe:close()
            has_books = (line ~= nil and #line > 0)
        end
        if not has_books then
            local f_test = io.open(DEFAULT_MANGA_DIR .. "/annotation.json", "r")
            if f_test then
                f_test:close()
                has_books = true
            end
        end

        if has_books then
            dataset_dir = DEFAULT_MANGA_DIR
        else
            dataset_dir = FALLBACK_MANGA_DIR
        end
    end

    if Manifest._manga_cache and Manifest._manga_cache[dataset_dir] then
        return Manifest._manga_cache[dataset_dir]
    end

    local ann_files = {}

    -- 1. Scan for individual book annotations: dataset/<manganame>/annotation.json
    local pipe = io.popen(string.format('ls -d "%s"/*/annotation.json 2>/dev/null', dataset_dir), "r")
    if pipe then
        for line in pipe:lines() do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed and #trimmed > 0 then
                table.insert(ann_files, trimmed)
            end
        end
        pipe:close()
    end

    -- 2. Also check if dataset_dir directly contains annotation.json (direct book dir or master)
    local direct_path = dataset_dir .. "/annotation.json"
    local direct_file = io.open(direct_path, "r")
    if direct_file then
        direct_file:close()
        local found = false
        for _, af in ipairs(ann_files) do
            if af == direct_path then
                found = true
                break
            end
        end
        if not found then
            table.insert(ann_files, direct_path)
        end
    end

    Manifest._manga_cache = Manifest._manga_cache or {}

    if #ann_files == 0 then
        Manifest._manga_cache[dataset_dir] = {}
        return {}
    end

    local books = {}
    local seen_titles = {}

    for _, ann_path in ipairs(ann_files) do
        local f = io.open(ann_path, "r")
        if f then
            local raw_json = f:read("*a")
            f:close()

            local raw_books = JSON.decode(raw_json)
            if raw_books and type(raw_books) == "table" then
                local book_dir = ann_path:match("^(.*)[/\\][^/\\]+$")
                local parsed_books = parseBooksFromRaw(raw_books, dataset_dir, book_dir)
                for _, b in ipairs(parsed_books) do
                    if not seen_titles[b.book_title] then
                        seen_titles[b.book_title] = true
                        table.insert(books, b)
                    end
                end
            end
        end
    end

    Manifest._manga_cache[dataset_dir] = books
    return books
end

--- Get all pages across all books as a flat list.
---
--- @param dataset_dir string|nil
--- @return table Array of page records
function Manifest.getAllPages(dataset_dir)
    local books = Manifest.loadManga(dataset_dir)
    local all_pages = {}
    for _, book in ipairs(books) do
        for _, page in ipairs(book.pages) do
            table.insert(all_pages, page)
        end
    end
    return all_pages
end

--- Find a specific page by book title and page index.
---
--- @param book_title string
--- @param page_index integer
--- @param dataset_dir string|nil
--- @return table|nil
function Manifest.getPage(book_title, page_index, dataset_dir)
    local books = Manifest.loadManga(dataset_dir)
    for _, book in ipairs(books) do
        if book.book_title == book_title then
            for _, page in ipairs(book.pages) do
                if page.page_index == page_index then
                    return page
                end
            end
        end
    end
    return nil
end

--- Curated golden set of representative manga pages across all books.
---
--- Covers varied panel layouts, gutter widths, and frame structures.
---
--- @param dataset_dir string|nil
--- @return table Array of representative page records
function Manifest.getGoldenPages(dataset_dir)
    local golden_specs = {
        { book = "Bloom_Into_You_Vol_8", page = 1 },
        { book = "Bloom_Into_You_Vol_8", page = 8 },
        { book = "tojime_no_siora", page = 2 },
        { book = "balloon_dream", page = 4 },
        { book = "tencho_isoro", page = 2 },
        { book = "boureisougi", page = 3 },
        { book = "rasetugari", page = 1 },
    }

    local pages = {}
    for _, spec in ipairs(golden_specs) do
        local page = Manifest.getPage(spec.book, spec.page, dataset_dir)
        if page then
            table.insert(pages, page)
        end
    end

    if #pages == 0 then
        local all_pages = Manifest.getAllPages(dataset_dir)
        for i = 1, math.min(5, #all_pages) do
            table.insert(pages, all_pages[i])
        end
    end
    return pages
end

return Manifest
